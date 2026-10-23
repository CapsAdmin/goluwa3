local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local network = import("goluwa/network/network.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local damage = import("lua/damage.lua")
local physics = import("goluwa/physics.lua")
local GridNav = import("goluwa/navigation/grid_nav.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local CharacterMovement = import("lua/components/character_movement.lua")
local PlayerController = import("lua/components/player_controller.lua")
local simulation_lod = import("lua/simulation_lod.lua")
local BUTTON = usercmd.BUTTON
local META = objects.CreateTemplate("ai_controller")
META:StartStorable()
META:GetSet("WalkSpeed", 80 * UNIT)
META:GetSet("RunSpeed", 210 * UNIT)
META:GetSet("TurnSpeed", 8)
META:GetSet("Radius", 16 * UNIT)
META:GetSet("Height", 72 * UNIT)
META:GetSet("StepHeight", 18 * UNIT)
META:GetSet("MaxDrop", 1.2)
META:IsSet("Running", false)
META:IsSet("Wander", true)
META:GetSet("WanderRadius", 30)
META:GetSet("WanderMinDelay", 1)
META:GetSet("WanderMaxDelay", 6)
META:GetSet("PhysicsDistance", 15)
META:GetSet("AttackRange", 12)
META:GetSet("FireInterval", 0.8)
META:GetSet("AimError", 0.035)
META:GetSet("MeleeDamage", 0)
META:GetSet("MeleeRange", 1.5)
META:GetSet("MeleeInterval", 1.2)
META:GetSet("MeleeDelay", 0.3)
META:GetSet("MagicElement", "")
META:GetSet("MagicDamage", 20)
META:GetSet("MagicInterval", 2.5)
META:EndStorable()
local WAYPOINT_RADIUS = 0.5
local GOAL_RADIUS = 0.3
local TURN_FIRST = math.rad(100)
local TURN_RESUME = math.rad(50)
local STUCK_INTERVAL = 1
local STUCK_DISTANCE = 0.2
local STUCK_LIMIT = 3
local STUCK_PROBE = 0.6
local BLOCK_TIME = 10
local SEARCH_SLICE = 0.001
local SEARCH_STEP_BUDGET = 0.004
local PARTIAL_LIMIT = 4
-- friction takes a fixed share of the stop speed every tick, a slow walker has to be able to out accelerate it
local STOP_SPEED_SHARE = 0.5
local WANDER_MIN_DISTANCE = 4
local WANDER_TRIES = 6
local TARGET_INTERVAL = 0.25
local TARGET_CHEST = 0.6
local AIM_TOLERANCE = 0.04

function GridNav.IsObstacle(body)
	local owner = body.Owner
	return not owner.ragdoll_part and not owner.character_movement
end

function META:Initialize()
	-- an npc in a prefab is added while its entity is being built and initialized once more when the build ends
	if self.initialized then return end

	self.initialized = true
	local owner = self.Owner
	local transform = owner:EnsureComponent("transform")
	local forward = transform:GetRotation():GetForward()
	self.yaw = math.atan2(-forward.x, -forward.z)
	self.time = 0
	self.wander_time = 0
	self.blocked = {}
	self.stuck_failures = 0
	self.stuck_time = 0
	self.turning = false
	self.next_target = 0
	self.next_fire = 0
	self.aim_direction = Vec3()
	self.cmd = usercmd.New()
	self.cmd.mode = "walk"
	self.cmd.buttons = BUTTON.ACTIVE

	if network.HasAuthority() then
		owner:AddComponent(
			"character_movement",
			{
				Mode = "walk",
				Radius = self.Radius,
				Height = self.Height,
				EyeHeight = self.Height * 0.9,
				StepHeight = self.StepHeight,
				GroundSpeed = self.WalkSpeed,
			}
		)
	end
end

function META:HasAuthority()
	return self.Owner.character_movement ~= nil
end

function META:Teleport(position, yaw)
	self.Owner.character_movement:TeleportTo(position)
	self.yaw = yaw or self.yaw
	self:Stop()
end

function META:GetGoal()
	return self.goal
end

function META:GetPath()
	return self.path
end

function META:IsMoving()
	return self.goal ~= nil
end

function META:MoveTo(position, running)
	self.goal = position:Copy()
	self.path = nil
	self.search = nil
	self.partial_count = 0
	self.stuck_failures = 0

	if running ~= nil then self:SetRunning(running) end
end

function META:Stop()
	self.goal = nil
	self.path = nil
	self.search = nil
end

function META:Finish(event_name)
	self.goal = nil
	self.path = nil
	self.search = nil
	self.wander_time = self.time + math.randomf(self.WanderMinDelay, self.WanderMaxDelay)
	self.Owner:CallLocalEvent(event_name)
end

function META:GetNav()
	return GridNav.Get(self.Radius, self.Height, self.StepHeight, self.MaxDrop)
end

do
	local budget_step, budget_left = -1, 0

	function META:StepSearch()
		local step = physics.instance.StepIndex

		if step ~= budget_step then
			budget_step, budget_left = step, SEARCH_STEP_BUDGET
		end

		if budget_left <= 0 then return false end

		local started = os.clock()
		local done = self:GetNav():Step(self.search, math.min(SEARCH_SLICE, budget_left))
		budget_left = budget_left - (os.clock() - started)
		return done
	end
end

function META:BeginSearch(position)
	local blocked = self.blocked

	for key, expires in pairs(blocked) do
		if expires <= self.time then blocked[key] = nil end
	end

	self.search = self:GetNav():BeginSearch(position, self.goal, self.Owner, blocked)
end

function META:FinishSearch()
	local path = self.search.path
	self.search = nil

	if #path.points < 2 and not path.complete then
		return self:Finish("OnNPCPathFailed")
	end

	if path.exhausted and not path.complete then
		return self:Finish("OnNPCPathFailed")
	end

	self.path = path
	self.path_index = 2
	self.stuck_position = nil
	self.stuck_time = 0
end

function META:OnStuck(position)
	self.stuck_failures = self.stuck_failures + 1

	if self.stuck_failures > STUCK_LIMIT then
		return self:Finish("OnNPCPathFailed")
	end

	local ix, iz = self:GetNav():GetColumn(position.x + self.dir_x * STUCK_PROBE, position.z + self.dir_z * STUCK_PROBE)
	self.blocked[GridNav.ColumnKey(ix, iz)] = self.time + BLOCK_TIME
	self.path = nil
end

function META:Steer(position)
	local points = self.path.points
	local count = #points

	while self.path_index <= count do
		local point = points[self.path_index]
		local dx, dz = point.x - position.x, point.z - position.z
		local distance = math.sqrt(dx * dx + dz * dz)

		if distance > (self.path_index == count and GOAL_RADIUS or WAYPOINT_RADIUS) then
			return dx / distance, dz / distance
		end

		self.path_index = self.path_index + 1
	end
end

function META:Think(dt, position)
	self.time = self.time + dt
	if not self.goal then
		if self.Wander and self.time >= self.wander_time then
			self.wander_time = self.time + 1
			local point = self:GetNav():GetRandomPoint(position, self.WanderRadius, WANDER_TRIES)

			if point and point:Distance(position) >= WANDER_MIN_DISTANCE then
				self:MoveTo(point)
			end
		end

		return
	end

	if not self.path then
		if not self.search then self:BeginSearch(position) end

		if not self:StepSearch() then return end

		self:FinishSearch()
	end

	if not self.path then return end

	self.dir_x, self.dir_z = self:Steer(position)

	if not self.dir_x then
		if self.path.complete then return self:Finish("OnNPCArrived") end

		self.partial_count = self.partial_count + 1

		if self.partial_count > PARTIAL_LIMIT then
			return self:Finish("OnNPCPathFailed")
		end

		self.path = nil
		return
	end

	local stuck_position = self.stuck_position

	if not stuck_position then
		self.stuck_position = position:Copy()
		self.stuck_time = 0
	else
		self.stuck_time = self.stuck_time + dt

		if self.stuck_time >= STUCK_INTERVAL then
			local dx, dz = position.x - stuck_position.x, position.z - stuck_position.z

			if dx * dx + dz * dz < STUCK_DISTANCE * STUCK_DISTANCE then
				self:OnStuck(position)
			else
				self.stuck_failures = 0
			end

			self.stuck_position = nil
		end
	end
end

function META:Advance(position, dir_x, dir_z, distance)
	local x, z = position.x + dir_x * distance, position.z + dir_z * distance
	local nav = self:GetNav()
	local ix, iz = nav:GetColumn(x, z)
	local y = nav:GetGround(ix, iz, position.y) or position.y
	self.Owner.character_movement:MoveBodyBy(self.Owner.rigid_body, Vec3(x - position.x, y - position.y, z - position.z))
end

function META:IsSimulated()
	return not self.far
end

function META:IsArmed()
	local holder = self.Owner.weapon_holder
	return holder ~= nil and holder:GetActiveWeapon() ~= nil
end

function META:CanFight()
	return self:IsArmed() or self.MeleeDamage > 0 or self.MagicElement ~= ""
end

function META:CastAt(target)
	local owner = self.Owner
	local eye = owner.rigid_body:GetOriginPosition() + owner.character_movement:GetViewOffset()
	local aim = target.transform:GetPosition() + Vec3(0, target.character_movement:GetHeight() * TARGET_CHEST, 0)
	local direction = (aim - eye):GetNormalized()
	local projectile = Entity.New{
		Name = "magic_projectile",
		transform = {Position = eye + direction * 0.6},
		magic_projectile = {Types = self.MagicElement, Damage = self.MagicDamage},
		network = SERVER and {} or nil,
	}
	projectile.magic_projectile:Launch(owner, direction, target)
end

function META:Fight(target, position)
	local owner = self.Owner
	local pose = owner.character_pose
	local offset = target.transform:GetPosition() - position
	offset.y = 0
	local distance = offset:GetLength()

	if self.MagicElement ~= "" then
		if self.time >= self.next_fire then
			self.next_fire = self.time + self.MagicInterval * math.randomf(0.8, 1.2)
			pose:PlayAction("attack", 0.9)
			self.attack_at = self.time + 0.45
		end

		if self.attack_at and self.time >= self.attack_at then
			self.attack_at = nil
			self:CastAt(target)
		end

		return
	end

	if distance > self.MeleeRange then
		self.dir_x, self.dir_z = offset.x / distance, offset.z / distance
		self.chasing = true
	elseif self.time >= self.next_fire then
		self.next_fire = self.time + self.MeleeInterval
		pose:PlayAction("attack", self.MeleeInterval * 0.7)
		self.attack_at = self.time + self.MeleeDelay
	end

	if self.attack_at and self.time >= self.attack_at then
		self.attack_at = nil

		if distance <= self.MeleeRange * 1.4 then
			local direction = distance > 1e-3 and offset / distance or Vec3(0, 0, -1)
			damage.Deal(
				target,
				{
					Attacker = owner,
					Inflictor = owner,
					Damage = self.MeleeDamage,
					Position = target.transform:GetPosition() + Vec3(0, target.character_movement:GetHeight() * TARGET_CHEST, 0),
					Normal = direction * -1,
					Force = direction * 3,
				}
			)
		end
	end
end

function META:UpdateTarget(position)
	local owner = self.Owner
	local target = self.target

	if target and (not target:IsValid() or target.health:IsDead()) then
		target = nil
	end

	if self.time >= self.next_target then
		self.next_target = self.time + TARGET_INTERVAL
		target = nil

		if self:CanFight() then
			local eye = position + owner.character_movement:GetViewOffset()
			local nearest = self.AttackRange

			for _, controller in ipairs(PlayerController.Instances or {}) do
				local candidate = controller.Owner

				if not candidate.health:IsDead() then
					local offset = candidate.transform:GetPosition() + Vec3(
							0,
							candidate.character_movement:GetHeight() * TARGET_CHEST,
							0
						) - eye
					local distance = offset:GetLength()

					if distance < nearest then
						local hit = damage.Sweep(eye, offset, owner)

						if not hit or (hit.entity and damage.GetVictim(hit.entity) == candidate) then
							nearest = distance
							target = candidate
						end
					end
				end
			end
		end
	end

	self.target = target
	return target
end

function META:NextCommand(dt)
	local owner = self.Owner
	local position = owner.rigid_body:GetOriginPosition()
	local cmd = self.cmd
	local previous_buttons = cmd.buttons
	simulation_lod.Update(META.Instances)
	local far = self.far
	self.dir_x, self.dir_z = nil, nil
	self.chasing = false
	local target = not far and self:UpdateTarget(position)

	if target then
		self.time = self.time + dt
		self.stuck_position = nil

		if not self:IsArmed() then self:Fight(target, position) end
	else
		self.target = nil
		self:Think(dt, position)
	end

	local dir_x, dir_z = self.dir_x, self.dir_z
	local yaw = self.yaw
	cmd.mode = far and "fly" or "walk"
	cmd.buttons = far and 0 or BUTTON.ACTIVE
	cmd.forward, cmd.side = 0, 0
	local speed = (self.Running or self.chasing) and self.RunSpeed or self.WalkSpeed

	if dir_x then
		local delta = math.normalizeangle(math.atan2(-dir_x, -dir_z) - yaw)
		local step = self.TurnSpeed * dt
		yaw = yaw + math.clamp(delta, -step, step)
		self.yaw = yaw
		local remaining = math.abs(delta) - step
		self.turning = remaining > (self.turning and TURN_RESUME or TURN_FIRST)

		if not self.turning then
			if far then
				self:Advance(position, dir_x, dir_z, speed * dt)
			else
				local sin, cos = math.sin(yaw), math.cos(yaw)
				cmd.forward = -dir_x * sin - dir_z * cos
				cmd.side = dir_x * cos - dir_z * sin
			end
		end
	end

	local movement = owner.character_movement
	local view = cmd.view

	if target then
		local eye = position + movement:GetViewOffset()
		local aim = target.transform:GetPosition() + Vec3(0, target.character_movement:GetHeight() * TARGET_CHEST, 0)
		local dx, dy, dz = aim.x - eye.x, aim.y - eye.y, aim.z - eye.z
		local delta = math.normalizeangle(math.atan2(-dx, -dz) - yaw)
		local step = self.TurnSpeed * dt
		yaw = yaw + math.clamp(delta, -step, step)
		self.yaw = yaw
		local aim_yaw = yaw
		local pitch = math.atan2(dy, math.sqrt(dx * dx + dz * dz))

		if math.abs(delta) < AIM_TOLERANCE and self.time >= self.next_fire then
			self.next_fire = self.time + self.FireInterval * math.randomf(0.7, 1.3)
			cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1)
			aim_yaw = aim_yaw + math.randomf(-self.AimError, self.AimError)
			pitch = pitch + math.randomf(-self.AimError, self.AimError)
		end

		local flat = math.cos(pitch)
		self.aim_direction:Set(-math.sin(aim_yaw) * flat, math.sin(pitch), -math.cos(aim_yaw) * flat)
		view:SetLookDirection(self.aim_direction)
	else
		local half = yaw / 2
		view.x, view.y, view.z, view.w = 0, math.sin(half), 0, math.cos(half)
	end

	cmd.pressed = bit.band(cmd.buttons, bit.bnot(previous_buttons))
	movement:SetGroundSpeed(speed)
	movement:SetStopSpeed(self.WalkSpeed * STOP_SPEED_SHARE)
	return cmd
end

CharacterMovement.RegisterController("ai_controller")
return META:Register()
