local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local acoustics = import("goluwa/audio/acoustics.lua")
local acoustics_cpu = {}
local OPTIONS = {IncludeRigidBodies = true}
local absorption = {0, 0, 0}

local function is_static(entity)
	local body = entity.rigid_body
	return not body or body:IsStatic()
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
		is_static,
		OPTIONS
	)

	if not hit then return nil end

	local n = hit.normal
	local nx, ny, nz = n.x, n.y, n.z

	if nx * dx + ny * dy + nz * dz > 0 then nx, ny, nz = -nx, -ny, -nz end

	local material = physics.GetHitMaterial(hit)

	if material then
		local a = material:GetAcousticAbsorption()
		absorption[1], absorption[2], absorption[3] = a.x, a.y, a.z
	else
		local a = acoustics.DEFAULT_ABSORPTION
		absorption[1], absorption[2], absorption[3] = a[1], a[2], a[3]
	end

	return hit.distance + tmin, nx, ny, nz, absorption
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
	return acoustics.FresnelProbe(self, listener, source, speed, 4)
end

function acoustics_cpu.New(budget)
	return setmetatable(
		{
			done = {},
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
