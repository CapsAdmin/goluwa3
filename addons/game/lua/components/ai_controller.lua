local objects = import("goluwa/objects/objects.lua")
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
local movesets = import("lua/movesets.lua")
local BUTTON = usercmd.BUTTON
local NO_ATTACKS = {}
local IDLE_MIN = 5
local IDLE_MAX = 14
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
META:IsSet("Retaliate", false)
META:GetSet("WanderRadius", 30)
META:GetSet("WanderMinDelay", 1)
META:GetSet("WanderMaxDelay", 6)
META:GetSet("PhysicsDistance", 15)
META:GetSet("AttackRange", 12)
META:GetSet("FireInterval", 0.8)
META:GetSet("AimError", 0.035)
META:GetSet("Faction", "enemy")
META:GetSet("Moveset", "")
META:GetSet("Alert", "")
META:EndStorable()
META:GetSet("Attacks", NO_ATTACKS)
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
local PLAYER_FACTION = "friend"
local FOLLOW_START_DISTANCE = 4
local PURSUE_START_DISTANCE = 2.5
local FOLLOW_STAND_DISTANCE = 2
local FOLLOW_RUN_DISTANCE = 9
local FOLLOW_REPATH_DISTANCE = 3.5
local FOLLOW_PATH_INTERVAL = 0.5
local NO_CONTROLLERS = {}
local target_sources = {}

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
	self.attack_ready = {}
	self.idle_time = math.randomf(IDLE_MIN, IDLE_MAX)
	self.next_follow_path = 0
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

function META:GetLeader()
	return self.leader
end

function META:SetLeader(leader)
	self.leader = leader
	self.next_follow_path = 0
	self:Stop()

	if not leader then self:SetRunning(false) end

	local usable = self.Owner.usable

	if usable then usable:SetPrompt(leader and "stay" or "follow") end
end

function META:OnTakeDamage(info)
	local attacker = info.Attacker

	if
		not self.Retaliate or
		not self:HasAuthority()
		or
		not attacker or
		attacker == self.Owner or
		not attacker.health or
		not attacker.character_movement
	then
		return
	end

	self.provoker = attacker
end

function META:GetProvoker()
	local provoker = self.provoker

	if provoker and (not provoker:IsValid() or provoker.health:IsDead()) then
		self.provoker = nil
		provoker = nil
	end

	return provoker
end

function META:OnUsed(user)
	if self.Faction ~= PLAYER_FACTION or not self:HasAuthority() then return end

	self:SetLeader(self.leader ~= user and user or nil)
	return true
end

function META:FollowLeader(position, leader, start_distance)
	local leader_position = leader.transform:GetPosition()
	local dx, dz = position.x - leader_position.x, position.z - leader_position.z
	local distance = math.sqrt(dx * dx + dz * dz)
	local goal = self.goal

	if not goal then
		if distance < start_distance then return false end
	else
		local gx, gz = goal.x - leader_position.x, goal.z - leader_position.z

		if
			self.time < self.next_follow_path or
			gx * gx + gz * gz < FOLLOW_REPATH_DISTANCE * FOLLOW_REPATH_DISTANCE
		then
			return true
		end
	end

	self.next_follow_path = self.time + FOLLOW_PATH_INTERVAL
	local scale = distance > 1e-3 and FOLLOW_STAND_DISTANCE / distance or 0
	self:MoveTo(
		Vec3(leader_position.x + dx * scale, leader_position.y, leader_position.z + dz * scale),
		distance > FOLLOW_RUN_DISTANCE
	)
	return true
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
	local provoker = self:GetProvoker()
	local leader = provoker or self.leader

	if leader then
		if leader:IsValid() and not leader.health:IsDead() then
			if
				not self:FollowLeader(position, leader, provoker and PURSUE_START_DISTANCE or FOLLOW_START_DISTANCE)
			then
				return
			end
		else
			self:SetLeader(nil)
		end
	end

	if not self.goal then
		if self.Wander and not self.leader and self.time >= self.wander_time then
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
	return holder ~= nil and holder:GetWeapon("right") ~= nil
end

function META:CanFight()
	return self:IsArmed() or #self.Attacks > 0
end

function META:CastAt(target, element, damage)
	local owner = self.Owner
	local eye = owner.rigid_body:GetOriginPosition() + owner.character_movement:GetViewOffset()
	local aim = target.transform:GetPosition() + Vec3(0, target.character_movement:GetHeight() * TARGET_CHEST, 0)
	local direction = (aim - eye):GetNormalized()
	import("lua/components/magic_projectile.lua").Cast(
		eye + direction * 0.6,
		owner,
		direction,
		target,
		nil,
		element,
		damage
	)
end

function META:GetReach(position, target, flat_distance)
	local rise = target.transform:GetPosition().y + target.character_movement:GetHeight() * TARGET_CHEST - position.y - self.Owner.character_movement:GetHeight() * TARGET_CHEST
	return math.sqrt(flat_distance * flat_distance + rise * rise)
end

function META:Fight(target, position)
	local runner = self.Owner:EnsureComponent("move_runner")

	if runner:IsPlaying() then return end

	if self.alerted ~= target then
		self.alerted = target
		self.Owner:CallLocalEvent("OnNPCAlert", target)

		if self.Alert ~= "" then
			self:BeginMove(movesets.Get(self.Moveset).Moves[self.Alert], target)
			return
		end
	end

	local offset = target.transform:GetPosition() - position
	offset.y = 0
	local distance = offset:GetLength()
	local reach = self:GetReach(position, target, distance)
	local attacks = self.Attacks
	local ready = self.attack_ready

	for i = 1, #attacks do
		local attack = attacks[i]

		if
			self.time >= (ready[i] or 0) and
			reach <= attack.Range and
			reach >= (attack.MinRange or 0)
		then
			ready[i] = self.time + attack.Interval * math.randomf(0.8, 1.2)
			self:BeginMove(movesets.Get(self.Moveset).Moves[attack.Move], target)
			return
		end
	end

	if distance > attacks[1].Range then
		self.dir_x, self.dir_z = offset.x / distance, offset.z / distance
		self.chasing = true
	end
end

function META:BeginMove(move, target)
	self.Owner.move_runner:Begin(move, move.Duration, self, true, target)
end

function META:OnMoveEvent(move, event)
	local owner = self.Owner
	local target = owner.move_runner.frame.target

	if not target or not target:IsValid() or target.health:IsDead() then return end

	local offset = target.transform:GetPosition() - owner.transform:GetPosition()
	offset.y = 0
	local distance = offset:GetLength()

	if event.Type == "cast" then
		self:CastAt(target, event.Element, event.Damage)
	elseif self:GetReach(owner.transform:GetPosition(), target, distance) <= event.Range then
		local direction = distance > 1e-3 and offset / distance or Vec3(0, 0, -1)
		damage.Deal(
			target,
			{
				Attacker = owner,
				Inflictor = owner,
				Damage = event.Damage,
				Position = target.transform:GetPosition() + Vec3(0, target.character_movement:GetHeight() * TARGET_CHEST, 0),
				Normal = direction * -1,
				Force = direction * (event.Force or 3),
			}
		)

		owner:CallLocalEvent("OnNPCStrike", target)

		if event.Until then return "end" end
	end
end

function META:OnMoveInterrupted() end

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
			target_sources[1] = PlayerController.Instances or NO_CONTROLLERS
			target_sources[2] = META.Instances

			for source_index = 1, 2 do
				for _, controller in ipairs(target_sources[source_index]) do
					local candidate = controller.Owner

					if
						controller ~= self and
						(
							source_index == 1 and
							PLAYER_FACTION or
							controller.Faction
						) ~= self.Faction and
						candidate.health and
						candidate.character_movement and
						not controller.far and
						not candidate.health:IsDead()
					then
						local offset = candidate.transform:GetPosition() + Vec3(0, candidate.character_movement:GetHeight() * TARGET_CHEST, 0) - eye
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
	end

	target = target or self:GetProvoker()
	self.target = target
	return target
end

function META:NextCommand(dt)
	local owner = self.Owner
	local position = owner.rigid_body:GetOriginPosition()
	local cmd = self.cmd
	cmd.number = cmd.number + 1
	local health = owner.health

	if health and health:IsDead() then
		local runner = owner.move_runner

		if runner and runner:IsPlaying() then runner:Cancel() end

		self.target = nil
		self.alerted = nil
		cmd.forward, cmd.side = 0, 0
		cmd.buttons = 0
		cmd.pressed = 0
		return cmd
	end

	self.idle_time = self.idle_time - dt

	if self.idle_time <= 0 then
		self.idle_time = math.randomf(IDLE_MIN, IDLE_MAX)

		if not self.far and not self.target then owner:CallLocalEvent("OnNPCIdle") end
	end

	local previous_buttons = cmd.buttons
	simulation_lod.Update(META.Instances)
	local far = self.far
	self.dir_x, self.dir_z = nil, nil
	self.chasing = false
	local target = not far and self:UpdateTarget(position)
	local pose = owner.character_pose
	local stunned = pose ~= nil and (pose:IsStunned() or pose:IsFrozen())

	local runner = owner.move_runner

	if runner and runner:IsPlaying() then
		local state, ended = runner:Step(dt, true)

		if state == "blocked" then
			self:BeginMove(ended.Crash, self.target)
		elseif state == "finished" and ended.Next then
			self:BeginMove(ended.Next, self.target)
		end
	end

	if target and self:CanFight() then
		self.time = self.time + dt
		self.stuck_position = nil

		if not self:IsArmed() and not stunned then self:Fight(target, position) end
	else
		if not target then
			self.target = nil
			self.alerted = nil
		end

		self:Think(dt, position)
	end

	if stunned then self.dir_x, self.dir_z = nil, nil end

	local dir_x, dir_z = self.dir_x, self.dir_z
	self.yaw = self.yaw + owner.character_movement:GetGroundYawVelocity() * dt
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
		local target_movement = target.character_movement
		local aim = target.transform:GetPosition() + Vec3(
				0,
				self:CanFight() and
					target_movement:GetHeight() * TARGET_CHEST or
					target_movement:GetEyeOffset().y,
				0
			)

		if runner and runner.move and runner.move.Speed then aim = runner.frame.point end

		local dx, dy, dz = aim.x - eye.x, aim.y - eye.y, aim.z - eye.z
		local delta = math.normalizeangle(math.atan2(-dx, -dz) - yaw)
		local step = self.TurnSpeed * dt
		yaw = yaw + math.clamp(delta, -step, step)
		self.yaw = yaw
		local aim_yaw = yaw
		local pitch = math.atan2(dy, math.sqrt(dx * dx + dz * dz))

		if
			self:CanFight() and
			not stunned and
			math.abs(delta) < AIM_TOLERANCE and
			self.time >= self.next_fire
		then
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

	cmd.aim:CopyFrom(view)
	cmd.pressed = bit.band(cmd.buttons, bit.bnot(previous_buttons))
	movement:SetGroundSpeed(speed)
	movement:SetStopSpeed(self.WalkSpeed * STOP_SPEED_SHARE)
	return cmd
end

CharacterMovement.RegisterController("ai_controller")
return META:Register()
