local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local fluid = import("goluwa/physics/fluid.lua")
local Entity = import("goluwa/entities/entity.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local Health = import("lua/components/health.lua")
local sounds = import("lua/sounds.lua")
local fmod_events = import("lua/crysis_loader/fmod_events.lua")
local boids = import("lua/boids.lua")
local behaviors = {
	ground = import("lua/boid_behaviors/ground.lua"),
	bird = import("lua/boid_behaviors/bird.lua"),
	fish = import("lua/boid_behaviors/fish.lua"),
	frog = import("lua/boid_behaviors/frog.lua"),
}
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
META:GetSet("Settings", {}, {callback = "Respawn"})
META:EndStorable()
local SMOOTH_RATE = 10
local SCARE_DECAY = 0.95 ^ 30
local SCARE_RADIUS = 10
local SPAWN_RETRY = 1
local SPAWN_PER_FRAME = 8
local DESPAWN_MARGIN = 1.2
local WATER_INTERVAL = 1
local DOWN = Vec3(0, -1, 0)
local GROUND_OPTIONS = {IgnoreRigidBodies = false}
META.MinGroundNormalY = 0.6

local function is_ground(entity)
	local body = entity.rigid_body
	return body ~= nil and (body.WorldGeometry or body:IsStatic())
end

function META:Initialize()
	self.boids = self.boids or {}
	self.threats, self.threat_count = {}, 0
	self.scare_ratio = 0
	self.scare_x, self.scare_y, self.scare_z, self.scare_radius = 0, 0, 0, 0
	self.spawned = 0
	self.next_spawn = 0
	self.next_water = 0
	self.dirty = true

	if RENDER_3D then self:AddGlobalEvent("Update") end
end

function META:Respawn()
	self.dirty = true
	self.definition = nil
end

function META:GetDefinition()
	if not self.definition then
		self.definition = setmetatable(table.copy(self.Settings), {__index = boids.Definitions[self.Kind]})
	end

	return self.definition
end

function META:GetBehavior()
	return behaviors[self:GetDefinition().Behavior]
end

function META:Scare(position, radius)
	self.scare_x, self.scare_y, self.scare_z, self.scare_radius = position.x, position.y, position.z, radius
	self.scare_ratio = 1
end

function META.ScareAll(position, radius)
	for _, flock in ipairs(META.Instances) do
		flock:Scare(position, radius)
	end
end

-- world only traces skip props and are much cheaper on levels with many rigid bodies
function META:TraceDown(x, y, z, drop, world_only)
	if world_only then return physics.RayCast(Vec3(x, y, z), DOWN, drop) end

	return physics.RayCast(Vec3(x, y, z), DOWN, drop, nil, is_ground, GROUND_OPTIONS)
end

function META:FindGround(x, y, z, drop)
	local hit = self:TraceDown(x, y, z, drop)

	if not hit or hit.normal.y < META.MinGroundNormalY then return end

	return hit.position.y
end

function META:TraceAhead(x, y, z, dx, dy, dz, length, world_only)
	if world_only then
		return physics.RayCast(Vec3(x, y, z), Vec3(dx, dy, dz), length)
	end

	return physics.RayCast(Vec3(x, y, z), Vec3(dx, dy, dz), length, nil, is_ground, GROUND_OPTIONS)
end

function META:GetWaterLevel()
	local now = system.GetElapsedTime()

	if now >= self.next_water then
		self.next_water = now + WATER_INTERVAL
		local origin = self.Owner.transform:GetPosition()
		local depth = fluid.HasRegions() and fluid.GetDepth(origin.x, origin.y, origin.z)
		self.water_level = depth and origin.y + depth or nil
	end

	return self.water_level
end

function META:Play(boid, clip, rate, loop)
	local animator = boid.Owner.animator

	if not animator then return end

	if boid.clip ~= clip then
		boid.clip = clip
		animator:SetLoop(loop ~= false)
		animator:SetSequence(clip)
	end

	animator:SetSpeed(rate)
end

function META:PlaySound(boid, role)
	local definition = self:GetDefinition()
	local event = definition.Sounds and fmod_events.Get(definition.Sounds[role])

	if event then
		sounds.PlayRandom(
			event.Paths,
			Vec3(boid.x, boid.y + definition.Center.y, boid.z),
			sounds.SPLToVolume(definition.SoundLevel) * event.Volume,
			fmod_events.GetPitch(event)
		)
	end
end

function META:SetPose(boid, roll)
	local transform = boid.Owner.transform
	transform:SetPosition(Vec3(boid.x, boid.y, boid.z))
	local direction = Vec3(boid.hx, boid.hy, boid.hz)
	local rotation = Quat():SetLookDirection(direction)

	if roll ~= 0 then rotation = QuatFromAxis(roll, direction) * rotation end

	transform:SetRotation(rotation)
end

function META:Flocking(boid, definition)
	local min2, max2 = definition.AttractMin ^ 2, definition.AttractMax ^ 2
	local cos_fov = math.cos(math.rad(definition.FieldOfView / 2))
	local separation = definition.Separation
	local sx, sy, sz, ax, ay, az, cx, cy, cz = 0, 0, 0, 0, 0, 0, 0, 0, 0
	local mates = 0

	for _, other in ipairs(self.boids) do
		if other ~= boid and not other.dead then
			local dx, dy, dz = other.x - boid.x, other.y - boid.y, other.z - boid.z
			local distance2 = dx * dx + dy * dy + dz * dz

			if distance2 < max2 and distance2 > 0 then
				local distance = math.sqrt(distance2)
				dx, dy, dz = dx / distance, dy / distance, dz / distance

				if boid.hx * dx + boid.hy * dy + boid.hz * dz > cos_fov then
					if distance2 < min2 then
						local w = (1 - distance2 / min2) * separation
						sx, sy, sz = sx - dx * w, sy - dy * w, sz - dz * w
					end

					mates = mates + 1
					ax, ay, az = ax + other.hx * other.speed,
					ay + other.hy * other.speed,
					az + other.hz * other.speed
					cx, cy, cz = cx + other.x, cy + other.y, cz + other.z
				end
			end
		end
	end

	if mates == 0 then return sx, sy, sz, 0, 0, 0, 0, 0, 0 end

	ax, ay, az = ax / mates, ay / mates, az / mates
	cx, cy, cz = cx / mates - boid.x, cy / mates - boid.y, cz / mates - boid.z
	local length = math.sqrt(cx * cx + cy * cy + cz * cz)

	if length > 0 then cx, cy, cz = cx / length, cy / length, cz / length end

	local w = max2 ~= min2 and (length - min2) / (max2 - min2) or 0
	return sx, sy, sz, ax, ay, az, cx * w, cy * w, cz * w
end

function META:Move(boid, definition, ax, ay, az, dt, smooth, max_turn)
	boid.ax = boid.ax * smooth + ax * (1 - smooth)
	boid.ay = boid.ay * smooth + ay * (1 - smooth)
	boid.az = boid.az * smooth + az * (1 - smooth)
	boid.x = boid.x + boid.hx * boid.speed * dt
	boid.y = boid.y + boid.hy * boid.speed * dt
	boid.z = boid.z + boid.hz * boid.speed * dt
	local vx = boid.hx * boid.speed + boid.ax * dt
	local vy = boid.hy * boid.speed + boid.ay * dt
	local vz = boid.hz * boid.speed + boid.az * dt
	local speed = math.sqrt(vx * vx + vy * vy + vz * vz)

	if speed > 0.0001 then
		local nx, ny, nz = vx / speed, vy / speed, vz / speed

		if max_turn then
			local t = math.min(max_turn * dt, 1)
			nx, ny, nz = boid.hx + (nx - boid.hx) * t,
			boid.hy + (ny - boid.hy) * t,
			boid.hz + (nz - boid.hz) * t
			local length = math.sqrt(nx * nx + ny * ny + nz * nz)
			nx, ny, nz = nx / length, ny / length, nz / length
		end

		boid.hx, boid.hy, boid.hz = nx, ny, nz
	end

	boid.speed = math.clamp(speed, definition.MinSpeed, definition.MaxSpeed)
end

function META:RemoveBoids()
	for _, boid in ipairs(self.boids) do
		if boid:IsValid() and not boid.dead then boid.Owner:Remove() end
	end

	self.boids = {}
	self.spawned = 0
end

function META:OnRemove()
	self:RemoveBoids()
end

function META:SpawnBoid(definition, x, y, z, hx, hy, hz)
	local scale = definition.Scale + math.random() * definition.ScaleRandom
	local entity = Entity.New{
		Name = definition.Name,
		transform = {Position = Vec3(x, y, z), Scale = Vec3(scale, scale, scale)},
		visual = {ModelPath = definition.Model},
		animator = not definition.Model:lower():ends_with(".cgf") and {} or nil,
		rigid_body = {
			Shape = BoxShape.New(definition.Size * scale),
			CenterOffset = definition.Center * scale,
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
	boid.hx, boid.hy, boid.hz = hx, hy, hz
	boid.speed = definition.MinSpeed
	boid.ax, boid.ay, boid.az = 0, 0, 0
	self.boids[#self.boids + 1] = boid
	self.spawned = self.spawned + 1
	return boid
end

-- streamed terrain has no collision right after a load, so boids that found no place are retried
function META:SpawnMissing(definition, behavior, origin)
	for _ = 1, math.min(SPAWN_PER_FRAME, self.Count - self.spawned) do
		if not behavior.Spawn(self, definition, origin) then
			self.next_spawn = system.GetElapsedTime() + SPAWN_RETRY
			return
		end
	end
end

do
	local threats = {}
	local count = 0
	local stamp

	-- living health owners that are not boids, collected once per physics step for every flock
	function META.CollectThreats()
		if stamp == physics.instance.StepIndex then return threats, count end

		stamp = physics.instance.StepIndex
		count = 0

		for _, health in ipairs(Health.Instances) do
			local entity = health.Owner

			if not entity.boid and not health:IsDead() and entity.transform then
				local position = entity.transform:GetPosition()
				threats[count + 1] = position.x
				threats[count + 2] = position.y
				threats[count + 3] = position.z
				count = count + 3
			end
		end

		return threats, count
	end
end

function META:OnUpdate(dt)
	local definition = self:GetDefinition()
	local behavior = behaviors[definition.Behavior]
	local origin = self.Owner.transform:GetPosition()

	if self.dirty then
		self.dirty = false
		self:RemoveBoids()
		self.next_spawn = 0

		for _, name in pairs(definition.Sounds or {}) do
			fmod_events.Get(name)
		end
	end

	local visible = definition.VisibilityDistance + self.Radius
	local distance = render3d and render3d.GetCamera():GetPosition():Distance(origin) or 0

	if distance > visible * DESPAWN_MARGIN then
		if self.spawned > 0 then self:RemoveBoids() end

		return
	end

	if
		distance < visible and
		self.spawned < self.Count and
		system.GetElapsedTime() >= self.next_spawn
	then
		self:SpawnMissing(definition, behavior, origin)
	end

	if dt <= 0 then return end

	self.threats, self.threat_count = META.CollectThreats()
	self.scare_ratio = self.scare_ratio * SCARE_DECAY ^ dt

	if self.scare_ratio < 0.01 then self.scare_ratio = 0 end

	local smooth = math.exp(-dt * SMOOTH_RATE)
	local boid_list = self.boids
	local i = 1

	while boid_list[i] do
		local boid = boid_list[i]

		if not boid:IsValid() or boid.dead then
			table.remove(boid_list, i)
		else
			behavior.Update(self, boid, definition, origin, dt, smooth)
			i = i + 1
		end
	end
end

event.AddListener("HealthDamaged", "boid_flock", function(entity)
	META.ScareAll(entity.transform:GetPosition(), SCARE_RADIUS)
end)

event.AddListener("EntityKilled", "boid_flock", function(entity)
	META.ScareAll(entity.transform:GetPosition(), SCARE_RADIUS)
end)

return META:Register()
