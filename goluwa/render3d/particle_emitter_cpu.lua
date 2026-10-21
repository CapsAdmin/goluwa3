local ffi = require("ffi")
local bit = require("bit")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
local Color = import("goluwa/structs/color.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local cpu = {}
cpu.MAX_PARTICLES = particle_emitter.CPU_MAX_PARTICLES
cpu.RAY_BUDGET = 256
local Particle = ffi.typeof([[struct {
	float x, y, z;
	float vx, vy, vz;
	float px, py, pz;
	float age, life, angle;
	uint32_t stuck;
}]])
local ParticleArray = ffi.typeof("$[?]", Particle)
local polygons = {}
local rays_left = 0

local function get_polygon(kind)
	local polygon = polygons[kind]

	if polygon then return polygon end

	polygon = Polygon3D.New()

	if kind == "quad" then
		shapes.BuildPlane(polygon, Vec3(0, 0, 0), Vec3(0, 0, 1), 0.5, 0.5)
	elseif kind == "cube" then
		shapes.BuildCube(polygon, 1)
	else
		shapes.BuildSphere(polygon, 0.5, 12, 8)
	end

	polygon:BuildBoundingBox()
	polygon:Upload()
	polygons[kind] = polygon
	return polygon
end

local function random(state)
	local x = state.rng
	x = bit.bxor(x, bit.lshift(x, 13))
	x = bit.bxor(x, bit.rshift(x, 17))
	x = bit.bxor(x, bit.lshift(x, 5))
	state.rng = x
	return (x + 2147483648) / 4294967296
end

local function get_runtime(emitter)
	local state = emitter.particle_state
	local runtime = state.cpu

	if not runtime then
		runtime = {
			particles = ParticleArray(cpu.MAX_PARTICLES),
			count = 0,
			matrices = {},
			prev_matrices = {},
		}
		state.cpu = runtime
		state.rng = bit.bor(emitter.Seed * 2654435761 % 4294967296, 1)
	end

	return runtime
end

local default_material

local function get_material(emitter)
	if emitter.Material then return emitter.Material end

	default_material = default_material or Material.New{Color = Color(1, 1, 1, 1), Roughness = 0.8, Metallic = 0, DoubleSided = true}
	return default_material
end

local function spawn(emitter, state, runtime)
	if runtime.count >= math.min(emitter.MaxParticles, cpu.MAX_PARTICLES) then return end

	local p = runtime.particles[runtime.count]
	runtime.count = runtime.count + 1
	local axis = state.axis
	local ax, ay, az = axis.x, axis.y, axis.z
	local tx, ty, tz

	if math.abs(ay) < 0.99 then tx, ty, tz = -az, 0, ax else tx, ty, tz = 0, az, -ay end

	local length = math.sqrt(tx * tx + ty * ty + tz * tz)
	tx, ty, tz = tx / length, ty / length, tz / length
	local bx, by, bz = ay * tz - az * ty, az * tx - ax * tz, ax * ty - ay * tx
	local size = emitter.ShapeSize
	local radius = size.x * 0.5
	local ox, oy, oz = 0, 0, 0
	local radial_x, radial_y, radial_z
	local shape = emitter.Shape

	if shape == "sphere" then
		local z = random(state) * 2 - 1
		local phi = random(state) * 6.2831853
		local ring = math.sqrt(1 - z * z)
		radial_x, radial_y, radial_z = ring * math.cos(phi), ring * math.sin(phi), z
		local distance = radius * random(state) ^ (1 / 3)
		ox, oy, oz = radial_x * distance, radial_y * distance, radial_z * distance
	elseif shape == "cone" or shape == "disc" then
		local angle = random(state) * 6.2831853
		local distance = radius * math.sqrt(random(state))
		local c, s = math.cos(angle) * distance, math.sin(angle) * distance
		ox, oy, oz = tx * c + bx * s, ty * c + by * s, tz * c + bz * s
	elseif shape == "box" then
		local u, v, w = (random(state) - 0.5) * size.x, (random(state) - 0.5) * size.y, (random(state) - 0.5) * size.z
		ox, oy, oz = tx * u + ax * v + bx * w, ty * u + ay * v + by * w, tz * u + az * v + bz * w
	end

	local cos_theta = 1 + (math.cos(math.rad(emitter.Spread)) - 1) * random(state)
	local phi = random(state) * 6.2831853
	local sin_theta = math.sqrt(1 - cos_theta * cos_theta)
	local c, s = math.cos(phi) * sin_theta, math.sin(phi) * sin_theta
	local dx, dy, dz = ax * cos_theta + tx * c + bx * s, ay * cos_theta + ty * c + by * s, az * cos_theta + tz * c + bz * s

	if radial_x then dx, dy, dz = radial_x, radial_y, radial_z end

	local speed = emitter.SpeedMin + (math.max(emitter.SpeedMax, emitter.SpeedMin) - emitter.SpeedMin) * random(state)
	local inherit = emitter.InheritVelocity
	local velocity = state.velocity
	p.x, p.y, p.z = state.position.x + ox, state.position.y + oy, state.position.z + oz
	p.px, p.py, p.pz = p.x, p.y, p.z
	p.vx, p.vy, p.vz = dx * speed + velocity.x * inherit, dy * speed + velocity.y * inherit, dz * speed + velocity.z * inherit
	p.age = 0
	p.life = emitter.LifetimeMin + (math.max(emitter.LifetimeMax, emitter.LifetimeMin) - emitter.LifetimeMin) * random(state)
	p.angle = random(state) * 6.2831853
	p.stuck = 0
end

local ray_origin = Vec3()
local ray_direction = Vec3()

local function step(emitter, runtime, dt)
	local particles = runtime.particles
	local gravity = 9.81 * emitter.GravityScale
	local drag = math.exp(-emitter.Drag * dt)
	local collides = emitter.Collision == "rays"
	local on_hit = emitter.OnHit
	local i = 0

	while i < runtime.count do
		local p = particles[i]
		p.age = p.age + dt

		if p.age >= p.life then
			runtime.count = runtime.count - 1
			particles[i] = particles[runtime.count]
		else
			p.px, p.py, p.pz = p.x, p.y, p.z

			if p.stuck == 0 then
				p.vy = p.vy - gravity * dt
				p.vx, p.vy, p.vz = p.vx * drag, p.vy * drag, p.vz * drag
				p.x, p.y, p.z = p.x + p.vx * dt, p.y + p.vy * dt, p.z + p.vz * dt
				p.angle = p.angle + math.rad(emitter.Spin) * dt

				if collides and rays_left > 0 then
					local dx, dy, dz = p.x - p.px, p.y - p.py, p.z - p.pz
					local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

					if distance > 1e-5 then
						rays_left = rays_left - 1
						local t = p.age / p.life
						local radius = (emitter.SizeStart + (emitter.SizeEnd - emitter.SizeStart) * t) * 0.5
						ray_origin.x, ray_origin.y, ray_origin.z = p.px, p.py, p.pz
						ray_direction.x, ray_direction.y, ray_direction.z = dx, dy, dz
						local hit = raycast.CastClosest(ray_origin, ray_direction, distance + radius)

						if hit then
							if on_hit == "kill" then
								p.age = p.life
							else
								local normal = hit.normal
								local position = hit.position
								local along = p.vx * normal.x + p.vy * normal.y + p.vz * normal.z

								if along > 0 then normal = normal * -1 along = -along end

								p.x, p.y, p.z = position.x + normal.x * radius, position.y + normal.y * radius, position.z + normal.z * radius

								if on_hit == "stick" then
									p.stuck = 1
									p.vx, p.vy, p.vz = 0, 0, 0
								else
									local keep = 1 - emitter.Friction
									local bounce = -along * (1 + emitter.Restitution)
									p.vx, p.vy, p.vz = (p.vx + normal.x * bounce) * keep, (p.vy + normal.y * bounce) * keep, (p.vz + normal.z * bounce) * keep
								end
							end
						end
					end
				end
			end

			i = i + 1
		end
	end
end

event.AddListener("Update", "particle_emitter_cpu", function(dt)
	dt = math.clamp(dt, 0, 0.1)
	rays_left = cpu.RAY_BUDGET

	for _, emitter in ipairs(particle_emitter.instances) do
		if emitter.particle_backend == "cpu" and particle_emitter.IsShown(emitter) then
			local state = particle_emitter.Sample(emitter, dt)
			local runtime = get_runtime(emitter)

			for _ = 1, particle_emitter.Step(emitter, dt) do
				spawn(emitter, state, runtime)
			end

			step(emitter, runtime, dt)
		end
	end
end)

do
	local function write_matrix(m, x, y, z, size, ax, ay, az, bx, by, bz, cx, cy, cz)
		m.m00, m.m01, m.m02 = ax * size, ay * size, az * size
		m.m10, m.m11, m.m12 = bx * size, by * size, bz * size
		m.m20, m.m21, m.m22 = cx * size, cy * size, cz * size
		m.m30, m.m31, m.m32 = x, y, z
	end

	event.AddListener("Draw3DGeometry", "particle_emitter_cpu", function()
		local view = render3d.GetCamera():BuildViewMatrix()
		local rx, ry, rz = view.m00, view.m10, view.m20
		local ux, uy, uz = view.m01, view.m11, view.m21
		local bx, by, bz = view.m02, view.m12, view.m22

		for _, emitter in ipairs(particle_emitter.instances) do
			local runtime = emitter.particle_state.cpu

			if emitter.particle_backend == "cpu" and runtime and particle_emitter.IsShown(emitter) then
				local polygon = get_polygon(emitter.Mesh)
				local material = get_material(emitter)
				local particles = runtime.particles
				local matrices = runtime.matrices
				local prev_matrices = runtime.prev_matrices
				local quad = emitter.Mesh == "quad"

				for i = 0, runtime.count - 1 do
					local p = particles[i]
					local matrix = matrices[i + 1]

					if not matrix then
						matrix = Matrix44()
						matrices[i + 1] = matrix
						prev_matrices[i + 1] = Matrix44()
					end

					local t = p.age / p.life
					local size = emitter.SizeStart + (emitter.SizeEnd - emitter.SizeStart) * t
					local prev_matrix = prev_matrices[i + 1]

					if quad then
						write_matrix(matrix, p.x, p.y, p.z, size, rx, ry, rz, ux, uy, uz, bx, by, bz)
						write_matrix(prev_matrix, p.px, p.py, p.pz, size, rx, ry, rz, ux, uy, uz, bx, by, bz)
					else
						local c, s = math.cos(p.angle), math.sin(p.angle)
						write_matrix(matrix, p.x, p.y, p.z, size, c, 0, -s, 0, 1, 0, s, 0, c)
						write_matrix(prev_matrix, p.px, p.py, p.pz, size, c, 0, -s, 0, 1, 0, s, 0, c)
					end

					gbuffer_instancing.Queue(polygon, material, matrix, prev_matrix)
				end
			end
		end
	end)
end

function cpu.GetParticleCount(emitter)
	local runtime = emitter.particle_state.cpu
	return runtime and runtime.count or 0
end

return cpu
