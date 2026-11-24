local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local fluid = import("goluwa/physics/fluid.lua")
local Entity = import("goluwa/entities/entity.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Health = import("lua/components/health.lua")
local boids = import("lua/boids.lua")
local META = objects.CreateTemplate("boid_flock")
META:StartStorable()
META:GetSet(
	"Kind",
	"chicken",
	{
		callback = "Respawn",
		get_enums = function()
			return boids.GetNames()
		end,
	}
)
META:GetSet("Count", 10, {callback = "Respawn"})
META:GetSet("Radius", 10)
META:EndStorable()
local ORIGIN_FACTOR = 0.1
local AVOID_FACTOR = 10
local SCARE_FACTOR = 10
local OBSTACLE_WEIGHT = 10
local SMOOTH_RATE = 10
local SCARE_DECAY = 0.95 ^ 30
local SCARE_RADIUS = 10
local MIN_REST_TIME = 2
local MAX_REST_TIME = 4
local MAX_WALK_TIME = 5
local PROBE_INTERVAL = 0.1
local STEP_HEIGHT = 0.4
local DROP_HEIGHT = 1.5
local MIN_GROUND_NORMAL_Y = 0.6
local SPAWN_HEIGHT = 5
local SPAWN_RETRY = 1
local UP = Vec3(0, 1, 0)
local DOWN = Vec3(0, -1, 0)
local GROUND_OPTIONS = {IgnoreRigidBodies = false}

local function is_ground(entity)
	local body = entity.rigid_body
	return body ~= nil and (body.WorldGeometry or body:IsStatic())
end

local function trace_down(x, y, z, drop)
	return physics.RayCast(Vec3(x, y, z), DOWN, drop, nil, is_ground, GROUND_OPTIONS)
end

local function find_ground(x, y, z, drop)
	local hit = trace_down(x, y, z, drop)

	if not hit or hit.normal.y < MIN_GROUND_NORMAL_Y then return end

	return hit.position.y
end

function META:Initialize()
	self.boids = self.boids or {}
	self.threats = {}
	self.scare_ratio = 0
	self.scare_x, self.scare_z, self.scare_radius = 0, 0, 0
	self.dirty = true

	if RENDER_3D then self:AddGlobalEvent("Update") end
end

function META:Respawn()
	self.dirty = true
end

function META:GetDefinition()
	return boids.Definitions[self.Kind]
end

function META:Scare(position, radius)
	self.scare_x, self.scare_z, self.scare_radius = position.x, position.z, radius
	self.scare_ratio = 1
end

function META.ScareAll(position, radius)
	for _, flock in ipairs(META.Instances) do
		flock:Scare(position, radius)
	end
end

function META:RemoveBoids()
	for _, boid in ipairs(self.boids) do
		if boid:IsValid() and not boid.dead then boid.Owner:Remove() end
	end

	self.boids = {}
end

function META:OnRemove()
	self:RemoveBoids()
end

local function play(boid, clip, rate)
	local animator = boid.Owner.animator

	if boid.clip ~= clip then
		boid.clip = clip
		animator:SetSequence(clip)
	end

	animator:SetSpeed(rate)
end

local function start_walking(boid, definition)
	boid.idle = false
	boid.action_time = 0
	boid.max_walk = math.randomf(0, MAX_WALK_TIME)
	boid.speed = definition.MinSpeed
end

local function start_idling(boid, definition)
	boid.idle = true
	boid.action_time = 0
	boid.max_idle = math.randomf(MIN_REST_TIME, MAX_REST_TIME)
	boid.speed = 0
	boid.ax, boid.az = 0, 0
	play(boid, definition.IdleClips[math.random(#definition.IdleClips)], 1)
end

-- streamed terrain has no collision right after a load, so boids that found no ground are retried
function META:SpawnMissing()
	self.next_spawn = system.GetElapsedTime() + SPAWN_RETRY
	local definition = self:GetDefinition()
	local origin = self.Owner.transform:GetPosition()
	local radius = self.Radius

	for i = self.spawned + 1, self.Count do
		local angle = math.randomf(0, math.pi * 2)
		local distance = math.sqrt(math.random()) * radius
		local x, z = origin.x + math.cos(angle) * distance, origin.z + math.sin(angle) * distance
		local bottom = origin.y - SPAWN_HEIGHT
		local hit = trace_down(x, origin.y + SPAWN_HEIGHT, z, SPAWN_HEIGHT * 2)

		while hit and hit.position.y > origin.y + STEP_HEIGHT do
			local top = hit.position.y - 0.05
			hit = trace_down(x, top, z, top - bottom)
		end

		local y = hit and hit.normal.y >= MIN_GROUND_NORMAL_Y and hit.position.y

		if y then
			local yaw = math.randomf(0, math.pi * 2)
			local entity = Entity.New{
				Name = definition.Name .. " " .. i,
				transform = {Position = Vec3(x, y, z), Rotation = QuatFromAxis(yaw, UP)},
				visual = {ModelPath = definition.Model},
				animator = {},
				rigid_body = {
					Shape = BoxShape.New(definition.Size:Copy()),
					CenterOffset = definition.Center:Copy(),
					MotionType = "kinematic",
					CollisionMask = 0,
					Mass = definition.Mass,
					AutomaticMass = false,
				},
				health = {Health = definition.Health, MaxHealth = definition.Health},
				boid = {},
			}
			local boid = entity.boid
			boid.flock = self
			boid.x, boid.y, boid.z = x, y, z
			boid.hx, boid.hz = -math.sin(yaw), -math.cos(yaw)
			boid.tx, boid.tz = x, z
			boid.ax, boid.az = 0, 0
			boid.avoid_x, boid.avoid_z = 0, 0
			boid.probe_time = math.randomf(0, PROBE_INTERVAL)
			start_idling(boid, definition)
			boid.action_time = math.randomf(0, boid.max_idle)
			self.boids[#self.boids + 1] = boid
			self.spawned = self.spawned + 1
		end
	end
end

function META:CollectThreats()
	local threats = self.threats
	local count = 0
	local origin = self.Owner.transform:GetPosition()
	local range = self.Radius * 2 + self:GetDefinition().ScareDistance

	for _, health in ipairs(Health.Instances) do
		local entity = health.Owner

		if not entity.boid and not health:IsDead() and entity.transform then
			local position = entity.transform:GetPosition()

			if
				math.abs(position.x - origin.x) < range and
				math.abs(position.z - origin.z) < range
			then
				threats[count + 1] = position.x
				threats[count + 2] = position.z
				count = count + 2
			end
		end
	end

	self.threat_count = count
end

function META:OnUpdate(dt)
	if self.dirty then
		self.dirty = false
		self:RemoveBoids()
		self.spawned = 0
		self.next_spawn = 0
	end

	if self.spawned < self.Count and system.GetElapsedTime() >= self.next_spawn then
		self:SpawnMissing()
	end

	if dt <= 0 then return end

	local definition = self:GetDefinition()
	self:CollectThreats()
	self.scare_ratio = self.scare_ratio * SCARE_DECAY ^ dt

	if self.scare_ratio < 0.01 then self.scare_ratio = 0 end

	local origin = self.Owner.transform:GetPosition()
	local smooth = math.exp(-dt * SMOOTH_RATE)
	local boid_list = self.boids
	local i = 1

	while boid_list[i] do
		local boid = boid_list[i]

		if not boid:IsValid() or boid.dead then
			table.remove(boid_list, i)
		else
			self:UpdateBoid(boid, definition, origin, dt, smooth)
			i = i + 1
		end
	end
end

function META:UpdateBoid(boid, definition, origin, dt, smooth)
	local min_speed, max_speed = definition.MinSpeed, definition.MaxSpeed
	local x, z = boid.x, boid.z
	local ax = -boid.hx * (boid.speed - min_speed) * 0.4
	local az = -boid.hz * (boid.speed - min_speed) * 0.4
	local scared = false

	if math.random() < dt then
		local radius = self.Radius
		boid.tx = origin.x + math.randomf(-radius, radius)
		boid.tz = origin.z + math.randomf(-radius, radius)
	end

	ax = ax + (boid.tx - x) * ORIGIN_FACTOR
	az = az + (boid.tz - z) * ORIGIN_FACTOR
	local scare_distance = definition.ScareDistance
	local threats = self.threats

	for t = 1, self.threat_count, 2 do
		local dx, dz = x - threats[t], z - threats[t + 1]
		local distance2 = dx * dx + dz * dz

		if distance2 < scare_distance * scare_distance then
			dx, dz = dx + math.randomf(-2, 2), dz + math.randomf(-2, 2)
			local length = math.sqrt(dx * dx + dz * dz) + 0.0001
			local factor = (1 - distance2 / (scare_distance * scare_distance)) * AVOID_FACTOR / length
			ax, az = ax + dx * factor, az + dz * factor
			scared = true
		end
	end

	if self.scare_ratio > 0 then
		local dx, dz = x - self.scare_x, z - self.scare_z
		local distance2 = dx * dx + dz * dz
		local radius2 = self.scare_radius * self.scare_radius

		if distance2 < radius2 then
			local length = math.sqrt(distance2) + 0.0001
			local factor = (1 - distance2 / radius2) * SCARE_FACTOR / length
			ax, az = ax + dx * factor, az + dz * factor
			scared = true
		end
	end

	if not boid.idle then
		boid.probe_time = boid.probe_time - dt

		if boid.probe_time <= 0 then
			boid.probe_time = PROBE_INTERVAL
			local reach = definition.Size.z
			local dx, dz = boid.hx * reach + math.randomf(-0.25, 0.25),
			boid.hz * reach + math.randomf(-0.25, 0.25)
			local length = math.sqrt(dx * dx + dz * dz)
			local hit = physics.RayCast(
				Vec3(
					x + boid.hx * reach * 0.5,
					boid.y + definition.Center.y,
					z + boid.hz * reach * 0.5
				),
				Vec3(dx, 0, dz),
				length,
				nil,
				is_ground,
				GROUND_OPTIONS
			)

			if hit and hit.distance > 0 then
				local nx, nz = hit.normal.x, hit.normal.z
				local dot = boid.hx * nx + boid.hz * nz
				local weight = (1 - hit.distance / length) * AVOID_FACTOR * OBSTACLE_WEIGHT
				local rx, rz = boid.hx - 2 * dot * nx + nx, boid.hz - 2 * dot * nz + nz
				boid.avoid_x = boid.avoid_x * smooth + rx * weight * (1 - smooth)
				boid.avoid_z = boid.avoid_z * smooth + rz * weight * (1 - smooth)
			end
		end
	end

	ax, az = ax + boid.avoid_x, az + boid.avoid_z
	boid.avoid_x, boid.avoid_z = boid.avoid_x * smooth, boid.avoid_z * smooth

	if definition.FreezeWhenScared then
		if scared then
			if not boid.idle then start_idling(boid, definition) end

			boid.action_time = 0
		elseif boid.scared then
			start_walking(boid, definition)
		end
	elseif scared and boid.idle then
		start_walking(boid, definition)
	end

	boid.scared = scared
	boid.action_time = boid.action_time + dt

	if boid.idle then
		if boid.action_time > boid.max_idle then start_walking(boid, definition) end
	elseif boid.action_time > boid.max_walk and not scared then
		start_idling(boid, definition)
	end

	if boid.idle then return end

	boid.ax = boid.ax * smooth + ax * (1 - smooth)
	boid.az = boid.az * smooth + az * (1 - smooth)
	local next_x, next_z = x + boid.hx * boid.speed * dt, z + boid.hz * boid.speed * dt
	local vx, vz = boid.hx * boid.speed + boid.ax * dt, boid.hz * boid.speed + boid.az * dt
	local speed = math.sqrt(vx * vx + vz * vz)

	if speed > 0.0001 then
		local turn = math.atan2(boid.hx * vz - boid.hz * vx, boid.hx * vx + boid.hz * vz)
		local max_turn = definition.TurnRate * dt
		turn = math.clamp(turn, -max_turn, max_turn)
		local c, s = math.cos(turn), math.sin(turn)
		boid.hx, boid.hz = boid.hx * c - boid.hz * s, boid.hx * s + boid.hz * c
	end

	boid.speed = math.clamp(speed, min_speed, max_speed)
	local blocked = physics.RayCast(
		Vec3(x, boid.y + definition.Center.y, z),
		Vec3(boid.hx, 0, boid.hz),
		boid.speed * dt + definition.Size.z * 0.5,
		nil,
		is_ground,
		GROUND_OPTIONS
	)
	local y = not blocked and
		find_ground(next_x, boid.y + STEP_HEIGHT, next_z, STEP_HEIGHT + DROP_HEIGHT)

	if
		y and
		(
			not definition.AvoidWater or
			not fluid.HasRegions()
			or
			(
				fluid.GetDepth(next_x, y + 0.05, next_z) or
				0
			) <= 0
		)
	then
		boid.x, boid.y, boid.z = next_x, y, next_z
	else
		boid.hx, boid.hz = -boid.hx, -boid.hz
		boid.ax, boid.az = 0, 0
		boid.tx, boid.tz = origin.x, origin.z
	end

	play(
		boid,
		definition.WalkClip,
		math.min(boid.speed / definition.ClipSpeed, definition.MaxClipRate)
	)
	local transform = boid.Owner.transform
	transform:SetPosition(Vec3(boid.x, boid.y, boid.z))
	transform:SetRotation(QuatFromAxis(math.atan2(-boid.hx, -boid.hz), UP))
end

event.AddListener("HealthDamaged", "boid_flock", function(entity)
	META.ScareAll(entity.transform:GetPosition(), SCARE_RADIUS)
end)

event.AddListener("EntityKilled", "boid_flock", function(entity)
	META.ScareAll(entity.transform:GetPosition(), SCARE_RADIUS)
end)

return META:Register()
