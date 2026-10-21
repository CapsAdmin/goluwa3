local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local physics = import("goluwa/physics.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local nav_mesh = import("goluwa/entities/components/nav_mesh.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local PlayerController = import("lua/components/player_controller.lua")
local BUTTON = usercmd.BUTTON
local META = objects.CreateTemplate("npc")
META:StartStorable()
META:GetSet("WalkSpeed", 80 * UNIT)
META:GetSet("RunSpeed", 210 * UNIT)
META:GetSet("TurnSpeed", 8)
META:GetSet("Radius", 16 * UNIT)
META:GetSet("Height", 72 * UNIT)
META:GetSet("StepHeight", 18 * UNIT)
META:GetSet("MaxClimb", 0.45)
META:GetSet("MaxDrop", 3)
META:IsSet("Running", false)
META:IsSet("Wander", true)
META:GetSet("WanderRadius", 30)
META:GetSet("WanderMinDelay", 1)
META:GetSet("WanderMaxDelay", 6)
META:GetSet("PhysicsDistance", 15)
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
local LOST_INTERVAL = 0.5
local LOST_TIME = 5
local LOST_HEIGHT = 2
local LOST_DISTANCE = 60
META.MaxSimulated = 12
local PHYSICS_HYSTERESIS = 8
local RANK_INTERVAL = 4
-- friction takes a fixed share of the stop speed every tick, a slow walker has to be able to out accelerate it
local STOP_SPEED_SHARE = 0.5
local WANDER_MIN_DISTANCE = 4
local WANDER_TRIES = 4
local observers, observer_count, observer_step = {}, 0, nil
local ranked = {}

local function refresh_observers()
	observer_count = 0

	if render3d then
		local position = render3d.GetCamera():GetPosition()
		observers[1], observers[2], observers[3] = position.x, position.y, position.z
		observer_count = 3
	end

	for _, controller in ipairs(PlayerController.Instances or {}) do
		local position = controller.Owner.transform:GetPosition()
		observers[observer_count + 1], observers[observer_count + 2], observers[observer_count + 3] = position.x, position.y, position.z
		observer_count = observer_count + 3
	end
end

local function sort_by_distance(a, b)
	return a.observer_distance < b.observer_distance
end

local function update_simulation()
	local step = physics.StepIndex

	if observer_step and step >= observer_step and step - observer_step < RANK_INTERVAL then
		return
	end

	observer_step = step
	refresh_observers()
	local count = 0

	for _, npc in ipairs(META.Instances) do
		if npc.Owner.player_movement then
			local position = npc.Owner.transform:GetPosition()
			local nearest = math.huge

			for i = 1, observer_count, 3 do
				local dx, dy, dz = observers[i] - position.x, observers[i + 1] - position.y, observers[i + 2] - position.z
				nearest = math.min(nearest, dx * dx + dy * dy + dz * dz)
			end

			npc.observer_distance = math.sqrt(nearest)
			count = count + 1
			ranked[count] = npc
		end
	end

	for i = #ranked, count + 1, -1 do
		ranked[i] = nil
	end

	table.sort(ranked, sort_by_distance)

	for rank, npc in ipairs(ranked) do
		npc.far = observer_count > 0 and
			(
				rank > META.MaxSimulated or
				npc.observer_distance > npc.PhysicsDistance + (
					npc.far and
					0 or
					PHYSICS_HYSTERESIS
				)
			)
	end
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
	self.lost_check = 0
	self.blocked = {}
	self.stuck_failures = 0
	self.stuck_time = 0
	self.turning = false
	self.cmd = usercmd.New()
	self.cmd.mode = "walk"
	self.cmd.buttons = BUTTON.ACTIVE

	if network.HasAuthority() then
		owner:AddComponent(
			"player_movement",
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
	return self.Owner.player_movement ~= nil
end

function META:Teleport(position, yaw)
	local owner = self.Owner
	local body = owner.rigid_body
	owner.player_movement:MoveBodyBy(body, position - body:GetOriginPosition())
	body:SetVelocity(Vec3())
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
	self.stuck_failures = 0

	if running ~= nil then self:SetRunning(running) end
end

function META:Stop()
	self.goal = nil
	self.path = nil
end

function META:Finish(event_name)
	self.goal = nil
	self.path = nil
	self.wander_time = self.time + math.randomf(self.WanderMinDelay, self.WanderMaxDelay)
	self.Owner:CallLocalEvent(event_name)
end

function META:GetPathOptions()
	local blocked = {}

	for area, expires in pairs(self.blocked) do
		if expires > self.time then
			blocked[area] = true
		else
			self.blocked[area] = nil
		end
	end

	return {
		Radius = self.Radius,
		MaxClimb = self.MaxClimb,
		MaxDrop = self.MaxDrop,
		Blocked = blocked,
	}
end

function META:FindPath(position, mesh)
	if not mesh then return self:Finish("OnNPCPathFailed") end

	local path = mesh:FindPath(position, self.goal, self:GetPathOptions())

	if not path then return self:Finish("OnNPCPathFailed") end

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

	local mesh = nav_mesh.GetMesh()
	local path = self.path
	local current = mesh:GetAreaAt(position)
	local expires = self.time + BLOCK_TIME

	for i, link in ipairs(path.links) do
		if path.areas[i] == current then
			self.blocked[link] = expires

			break
		end
	end

	local ahead = mesh:GetAreaAt(
		Vec3(position.x + self.dir_x * STUCK_PROBE, position.y, position.z + self.dir_z * STUCK_PROBE)
	)

	if ahead and ahead ~= current then self.blocked[ahead] = expires end

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

function META:ReturnToMesh(mesh, position)
	local area, x, y, z = mesh:GetNearestArea(position, LOST_DISTANCE)
	self.lost_since = nil

	if area then self:Teleport(Vec3(x, y + 0.1, z)) end
end

function META:Think(dt, position)
	self.time = self.time + dt
	local mesh = nav_mesh.GetMesh()

	if mesh and self.time >= self.lost_check then
		self.lost_check = self.time + LOST_INTERVAL

		if mesh:GetAreaAt(position, LOST_HEIGHT) then
			self.lost_since = nil
		else
			self.lost_since = self.lost_since or self.time

			if self.time - self.lost_since >= LOST_TIME then
				return self:ReturnToMesh(mesh, position)
			end
		end
	end

	if not self.goal then
		if self.Wander and self.time >= self.wander_time then
			self.wander_time = self.time + 1
			local reachable = mesh and mesh:GetReachableAreas(position, self:GetPathOptions())

			if reachable then
				for _ = 1, WANDER_TRIES do
					local point = mesh:GetRandomPoint(position, self.WanderRadius, reachable)

					if point and point:Distance(position) >= WANDER_MIN_DISTANCE then
						self:MoveTo(point)

						break
					end
				end
			end
		end

		return
	end

	if not self.path then self:FindPath(position, mesh) end

	if not self.path then return end

	self.dir_x, self.dir_z = self:Steer(position)

	if not self.dir_x then return self:Finish("OnNPCArrived") end

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
	local mesh = nav_mesh.GetMesh()
	local x, z = position.x + dir_x * distance, position.z + dir_z * distance
	local y = position.y
	local area = mesh:GetAreaAt(Vec3(x, y, z), self.MaxDrop)

	if area then y = mesh:GetHeight(area, x, z) end

	self.Owner.player_movement:MoveBodyBy(self.Owner.rigid_body, Vec3(x - position.x, y - position.y, z - position.z))
end

function META:IsSimulated()
	return not self.far
end

function META:NextCommand(dt)
	local owner = self.Owner
	local position = owner.rigid_body:GetOriginPosition()
	local cmd = self.cmd
	update_simulation()
	local far = self.far
	self.dir_x, self.dir_z = nil, nil
	self:Think(dt, position)
	local dir_x, dir_z = self.dir_x, self.dir_z
	local yaw = self.yaw
	cmd.mode = far and "fly" or "walk"
	cmd.buttons = far and 0 or BUTTON.ACTIVE
	cmd.forward, cmd.side = 0, 0
	local speed = self.Running and self.RunSpeed or self.WalkSpeed

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

	local half = yaw / 2
	local view = cmd.view
	view.x, view.y, view.z, view.w = 0, math.sin(half), 0, math.cos(half)
	local movement = owner.player_movement
	movement:SetGroundSpeed(speed)
	movement:SetStopSpeed(self.WalkSpeed * STOP_SPEED_SHARE)
	return cmd
end

return META:Register()
