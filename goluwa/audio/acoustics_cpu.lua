local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local acoustics = import("goluwa/audio/acoustics.lua")
local acoustics_cpu = {}
acoustics_cpu.DYNAMIC_OCCLUDER_SIZE = 1.5
local OPTIONS = {IncludeRigidBodies = true, IgnoreKinematicBodies = false}

local function is_occluder(entity)
	local body = entity.rigid_body

	if not body then return true end

	if body.CollisionMask == 0 then return false end

	if body:IsStatic() or body:IsKinematic() then return true end

	if body:GetShapeType() == "capsule" then return false end

	local half = body:GetHalfExtents()
	return math.max(half.x, half.y, half.z) * 2 >= acoustics_cpu.DYNAMIC_OCCLUDER_SIZE
end

local META = {}
META.__index = META

function META:Trace(ox, oy, oz, dx, dy, dz, tmin, tmax)
	if tmax <= tmin then return nil end

	local hit = physics.RayCast(
		Vec3(ox + dx * tmin, oy + dy * tmin, oz + dz * tmin),
		Vec3(dx, dy, dz),
		tmax - tmin,
		nil,
		is_occluder,
		OPTIONS
	)

	if not hit then return nil end

	local n = hit.normal
	local nx, ny, nz = n.x, n.y, n.z

	if nx * dx + ny * dy + nz * dz > 0 then nx, ny, nz = -nx, -ny, -nz end

	local material = physics.GetHitMaterial(hit)
	local record = self.material

	if material then
		acoustics.ReadMaterial(material, record)
	else
		local default = acoustics.DEFAULT_MATERIAL

		for b = 1, 3 do
			record.absorption[b] = default.absorption[b]
			record.scattering[b] = default.scattering[b]
			record.rain[b] = default.rain[b]
			record.wind[b] = default.wind[b]
		end

		record.density = default.density
		record.surface_mass = default.surface_mass
	end

	return hit.distance + tmin,
	nx,
	ny,
	nz,
	record,
	hit.front_face,
	hit.exit_distance and hit.exit_distance + tmin
end

function META:IsReady()
	return true
end

function META:Submit(job)
	local result = acoustics.NewResult(job)
	acoustics.PathTrace(self, job, result)
	acoustics.RunQueries(self, job, result)
	self.done[#self.done + 1] = {job = job, result = result}
end

function META:Collect()
	local done = self.done

	if #done == 0 then return done end

	self.done = {}
	return done
end

function META:Probe(listener, source, speed)
	return acoustics.FresnelProbe(self, listener, source, speed, 4),
	acoustics.ProbeTransmission(self, listener, source, speed),
	acoustics.DetourProbe(self, listener, source, 24)
end

function acoustics_cpu.New(budget)
	local default = acoustics.DEFAULT_MATERIAL
	return setmetatable(
		{
			done = {},
			material = acoustics.NewMaterial(
				default.absorption,
				default.scattering,
				default.density,
				default.surface_mass,
				default.rain,
				default.wind
			),
			budget = budget or
				{
					rays = 16,
					bounces = 4,
					samples = 16,
					sources = 3,
					fresnel = 1,
					reflection_sources = 1,
				},
		},
		META
	)
end

return acoustics_cpu
