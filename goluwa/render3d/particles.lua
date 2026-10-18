local ffi = require("ffi")
local vk = import("goluwa/bindings/vk.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local medium_lighting = import("goluwa/render3d/medium_lighting.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local translucent_moments = import("goluwa/render3d/translucent_moments.lua")
local particles = {}
-- a particle system is a pool of particles that live on the gpu. every frame one compute pass spawns, moves and
-- lights every live particle of every active system, and the translucent passes draw them as capsules (a streak
-- with a round end each) that the order independent transparency blends with the models.
--
-- a system is registered with particles.Register{...}:
--   name: its glsl functions are <name>_spawn, <name>_update and <name>_visibility, its uniforms <name>_data
--   max_count: the size of its pool
--   IsActive(): whether it simulates and draws this frame
--   GetCount(): how many of its pool are alive, and how many particles each one stands for (the coverage
--     scale, a thinned out crowd of 1000 particles shown as 100 makes each ten times as opaque)
--   block, WriteBlock(self, block): its own uniforms, a list of fields like any block and the function that fills it
--   declarations: glsl in front of its functions
--   spawn: the body of void <name>_spawn(uint index, uint generation, inout Particle p). p is zero but for
--     p.user.x (the generation, 1 the first time), it sets what it needs of position, velocity, width (meters, the
--     diameter of the capsule), life (seconds, a particle past it is spawned again) and the user fields
--   update: the body of void <name>_update(uint index, float dt, inout Particle p). p.age is already advanced
--   visibility: the body of float <name>_visibility(Particle p), 0 hides the particle, 1 shows it
--   scatter_g: the Henyey-Greenstein asymmetry of how it scatters light
--   streak_time: seconds of its motion drawn as a streak, the exposure time
--   fade_time: seconds it fades in after its spawn and out before its life ends
--   fade_near, fade_far: meters, it fades out closer than the first and from 70% of the second away
--   depth_near, depth_far: the range of distances to the camera the translucent passes have to cover
--   lit: false for a system that sets p.radiance itself (a glowing spark), it is not lit then. Default true
--   shade: the body of void <name>_shade(inout Particle p), every frame a particle is visible, after its light (p.light,
--     the light that scatters towards the viewer, refreshed every few frames) is known. It sets p.radiance, what is drawn.
--     Default p.radiance = p.light (nothing if lit is false)
--   should_spawn: the body of bool <name>_should_spawn(uint index). A system that has it spawns a slot only when it says
--     so (a dead slot stays dead otherwise, and an alive one is spawned again, its generation up), which is how an
--     emitter spawns a number of particles a frame: the cpu picks slots in a ring and the shader tests it. The slots
--     do not start at a random age either
--   UsesRays(): for a system with per particle collision, whether any particle may use "rays" (the scene bvh is only
--     built and bound while something does)
--   collision_mode: with collision = "per_particle", the body of int <name>_collision_mode(Particle p), 0 for nothing and
--     1 shelter_map, 2 scene_depth, 3 rays
--   collision: what the particle's step from where it was to where it is is tested against, read every frame so it
--     can change while the game runs. nil is nothing, "shelter_map" the depth map of the world from above that keeps
--     the weather off what is under a roof (one texture read, it only sees the top of things, and it is what rain and
--     snow use), "scene_depth" the depth buffer of the view (cheap and sees walls, but only what is on screen and in
--     front of something thin enough), "rays" a ray along the step through the scene bvh (sees everything solid, one
--     ray per particle). A hit calls collide
--   collide: the body of void <name>_collide(uint index, inout Particle p, vec3 previous, vec3 hit, vec3 normal),
--     with the point the step hit and the surface's normal, facing the particle. particle_stick, particle_bounce and
--     p.life = 0.0 (it dies) are what it usually does. A system that moves a particle by other means than its step
--     (the box around the camera wrapping it) sets particle_previous = p.position after
--
-- the light of a particle is the primary light's shadowed beam, the local lights and the light around it: the
-- ddgi probes where there are some, the sky's environment where there are none, like the translucent pass
particles.MAX_SYSTEMS = 8
particles.LOCAL_SIZE = 64
-- a particle is lit every this many frames, and when it appears
particles.RELIGHT_INTERVAL = 4
local LOCAL_LIGHT_LIMIT = 8
local BINDING_DDGI = 1
local BINDING_DATA = 2
local BINDING_OCCLUSION = 3
local BINDING_LIGHT_GRID = 4
local BINDING_FIRST_SYSTEM = 5
local BINDING_BVH_NODES = 20
local BINDING_BVH_TRIANGLES = 21
local COLLISION_MODES = {shelter_map = 1, scene_depth = 2, rays = 3, per_particle = 4}
local PARTICLE_BYTES = 80
particles.systems = {}
local system_layout = {
	{"count", "int"},
	{"first", "int"},
	{"coverage_scale", "float"},
	{"streak_time", "float"},
	{"scatter_g", "float"},
	{"forward_fraction", "float"},
	{"fade_time", "float"},
	{"fade_near", "float"},
	{"fade_far", "float"},
	{"collision", "int"},
	{"lit", "int"},
	{"scheduled", "int"},
}
local pools_and_systems = {
	{"pools", "uint64_t", particles.MAX_SYSTEMS},
	{"systems", system_layout, particles.MAX_SYSTEMS},
	{"system_count", "int"},
}

-- the share of what a particle scatters that comes from the light behind it (the hemisphere around the direction
-- the viewer looks in), the integral of the Henyey-Greenstein phase over that half of the sphere
local function get_forward_fraction(g)
	if math.abs(g) < 1e-4 then return 0.5 end

	return (1 - g * g) / (2 * g) * (1 / (1 - g) - 1 / math.sqrt(1 + g * g))
end

function particles.Register(def)
	local index = #particles.systems + 1

	-- a module that loads again takes over the place and the pool of what it registered before
	for i, other in ipairs(particles.systems) do
		if other.name == def.name then
			index = i
			def.pool = other.pool

			break
		end
	end

	assert(index <= particles.MAX_SYSTEMS, "too many particle systems")
	def.forward_fraction = get_forward_fraction(def.scatter_g)
	def.block = def.block or {}
	def.declarations = def.declarations or ""
	def.visibility = def.visibility or "return 1.0;"
	def.fade_time = def.fade_time or 0
	def.fade_near = def.fade_near or 0
	def.fade_far = def.fade_far or 0
	def.depth_near = def.depth_near or 0.1
	def.depth_far = def.depth_far or 100
	def.collide = def.collide or ""
	def.collision_mode = def.collision_mode or "return 0;"
	def.shade = def.shade or (def.lit ~= false and "p.radiance = p.light;" or "")
	particles.systems[index] = def
	return def
end

function particles.GetPool(def, cmd)
	if def.pool then return def.pool end

	def.pool = render.CreateBuffer{
		byte_size = def.max_count * PARTICLE_BYTES,
		buffer_usage = {"storage_buffer", "transfer_src", "transfer_dst", "shader_device_address"},
		memory_property = {"device_local"},
		label = "particles " .. def.name,
	}
	cmd:FillBuffer(def.pool, 0, def.pool:GetSize(), 0)
	cmd:PipelineBarrier{
		srcStage = "transfer",
		dstStage = "compute",
		bufferBarriers = {
			{
				buffer = def.pool,
				srcAccessMask = "transfer_write",
				dstAccessMask = "shader_write",
			},
		},
	}
	return def.pool
end

do
	local Record = ffi.typeof([[struct {
		float position[3];
		float age;
		float velocity[3];
		float life;
		float radiance[3];
		float visibility;
		float light[3];
		float width;
		uint32_t user[3];
		uint32_t spare;
	}]])
	assert(ffi.sizeof(Record) == PARTICLE_BYTES)
	local RecordArray = ffi.typeof("$[?]", Record)
	local BufferCopy = ffi.typeof("$[1]", vk.VkBufferCopy)

	-- the live particles of a system as an array of records with the fields of Particle, for tests and debugging
	function particles.Download(def)
		local size = def.pool:GetSize()
		local readback = render.CreateBuffer{
			byte_size = size,
			buffer_usage = {"transfer_dst"},
			memory_property = {"host_visible", "host_coherent", "host_cached"},
			label = "particles readback",
		}
		local copy = BufferCopy()
		copy[0].size = size
		local cmd = render.GetCommandPool():AllocateCommandBuffer()
		cmd.gpu_timing_disabled = true
		cmd:Begin()
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = "transfer",
			bufferBarriers = {{buffer = def.pool, srcAccessMask = "shader_write", dstAccessMask = "transfer_read"}},
		}
		cmd:CopyBuffer(def.pool, readback, copy, 1)
		cmd:End()
		render.SubmitAndWait(cmd)
		cmd:Remove()
		local out = RecordArray(def.max_count)
		ffi.copy(out, readback:Map(), size)
		readback:Remove()
		return out
	end
end

-- the pools and what is alive of every system, in the order the draw's instances run
function particles.WriteSystems(block)
	local first = 0

	for i, def in ipairs(particles.systems) do
		local entry = block.systems[i - 1]
		local count, coverage_scale = 0, 1

		if def.IsActive() then count, coverage_scale = def.GetCount() end

		block.pools[i - 1] = def.pool and def.pool:GetDeviceAddress() or 0
		entry.count = count
		entry.first = first
		entry.coverage_scale = coverage_scale
		entry.streak_time = def.streak_time
		entry.scatter_g = def.scatter_g
		entry.forward_fraction = def.forward_fraction
		entry.fade_time = def.fade_time
		entry.fade_near = def.fade_near
		entry.fade_far = def.fade_far
		entry.collision = def.collision and assert(COLLISION_MODES[def.collision], "unknown collision " .. def.collision) or 0
		entry.lit = def.lit == false and 0 or 1
		entry.scheduled = def.should_spawn and 1 or 0
		first = first + count
	end

	block.system_count = #particles.systems
	return first
end

function particles.GetParticleGLSL()
	return [[
		struct Particle {
			vec3 position;
			// seconds since it spawned
			float age;
			vec3 velocity;
			// seconds it lives, a particle that is out of life or has none spawns
			float life;
			// what is drawn, a system sets it in shade or in update
			vec3 radiance;
			// 0 hidden, 1 shown, written by the simulation
			float visibility;
			// the light that scatters towards the camera, written by the simulation for lit systems
			vec3 light;
			float width;
			// x is the generation, how often the slot spawned
			uvec3 user;
			uint spare;
		};

		layout(buffer_reference, scalar) buffer ParticleBuffer { Particle p[]; };
		layout(buffer_reference, scalar) readonly buffer ParticleBufferRead { Particle p[]; };
	]]
end

-- what a step from a to b of a particle of this radius hits, for the collision modes of a system. hit is where, normal is
-- the surface's and faces the particle
function particles.GetCollisionGLSL()
	return [[
		// where the particle was before its update, a system that moves it by other means sets this after
		vec3 particle_previous;

		// whether pos is under what the shelter map sees from above, and the surface there and its normal
		bool particle_probe_shelter_map(vec3 pos, out vec3 surface, out vec3 normal) {
			surface = pos;
			normal = vec3(0.0, 1.0, 0.0);

			if (particle_data.shelter_texture == -1) return false;

			mat4 m = particle_data.shelter_matrix;
			vec4 light_space_pos = m * vec4(pos, 1.0);
			vec3 coords = light_space_pos.xyz / light_space_pos.w;
			coords.xy = coords.xy * 0.5 + 0.5;

			if (any(lessThan(coords, vec3(0.0))) || any(greaterThan(coords, vec3(1.0)))) return false;

			// the depth grows along the gradient, away from where the precipitation comes from
			vec3 gradient = vec3(m[0].z, m[1].z, m[2].z);
			float stored = textureLod(TEXTURE(particle_data.shelter_texture), coords.xy, 0.0).r;

			if (stored >= coords.z - 0.05 * length(gradient)) return false;

			surface = pos - gradient * ((coords.z - stored) / dot(gradient, gradient));
			normal = -normalize(gradient);
			return true;
		}

		vec3 particle_world_from_depth(vec2 uv, float depth) {
			vec4 view_pos = particle_data.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
			return (particle_data.inv_view * vec4(view_pos.xyz / view_pos.w, 1.0)).xyz;
		}

		// the particle is behind what the view sees at b, by less than a thickness, and was in front of it at a
		bool particle_trace_scene_depth(vec3 a, vec3 b, out vec3 hit, out vec3 normal) {
			vec4 clip = particle_data.projection * particle_data.view * vec4(b, 1.0);

			if (clip.w <= 0.0) return false;

			vec2 uv = clip.xy / clip.w * 0.5 + 0.5;

			if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return false;

			ivec2 pixel = clamp(ivec2(uv * vec2(textureSize(TEXTURE(particle_data.depth_tex), 0))), ivec2(0), textureSize(TEXTURE(particle_data.depth_tex), 0) - 1);
			float depth = gbuffer_depth(pixel);

			if (depth <= 0.0) return false;

			float surface_depth = get_view_depth(uv, depth);
			float before_depth = -(particle_data.view * vec4(a, 1.0)).z;

			if (clip.w <= surface_depth || before_depth > surface_depth || clip.w - surface_depth > max(max(0.3, surface_depth * 0.05), distance(a, b) * 1.5)) return false;

			hit = particle_world_from_depth(uv, depth);
			normal = gbuffer_normal(pixel);

			if (dot(normal, a - hit) < 0.0) normal = -normal;

			return true;
		}

		bool particle_trace_rays(vec3 a, vec3 b, float radius, out vec3 hit, out vec3 normal) {
			vec3 step = b - a;
			float length_of_step = length(step);

			if (particle_data.bvh_ready == 0 || length_of_step < 1e-5) return false;

			scene_bvh_hit result;

			if (!scene_bvh_trace(a, step / length_of_step, 0.0, length_of_step + radius, result)) return false;

			hit = result.position;
			normal = result.normal;
			return true;
		}

		bool particle_trace(int mode, vec3 a, vec3 b, float radius, out vec3 hit, out vec3 normal) {
			if (mode == 1) {
				vec3 surface;
				vec3 surface_normal;

				return !particle_probe_shelter_map(a, surface, surface_normal) && particle_probe_shelter_map(b, hit, normal);
			}

			if (mode == 2) return particle_trace_scene_depth(a, b, hit, normal);

			return particle_trace_rays(a, b, radius, hit, normal);
		}

		// what a hit usually does: the particle lies on the surface, or comes off it with its speed along the normal
		// reversed and scaled by restitution and across it by friction
		void particle_stick(inout Particle p, vec3 hit, vec3 normal) {
			p.position = hit + normal * p.width * 0.5;
			p.velocity = vec3(0.0);
		}

		void particle_bounce(inout Particle p, vec3 hit, vec3 normal, float restitution, float friction) {
			float along = dot(p.velocity, normal);
			p.velocity = (p.velocity - along * normal) * (1.0 - friction) - along * restitution * normal;
			p.position = hit + normal * (p.width * 0.5 + 0.002);
		}
	]]
end

function particles.GetSimulationGLSL()
	local functions = {}
	local spawns = {}
	local updates = {}
	local visibilities = {}
	local collides = {}
	local shades = {}
	local should_spawns = {}
	local collision_modes = {}

	for i, def in ipairs(particles.systems) do
		functions[#functions + 1] = def.declarations .. string.format(
				[[
			void %s_spawn(uint index, uint generation, inout Particle p) {
				%s
			}

			void %s_update(uint index, float dt, inout Particle p) {
				%s
			}

			float %s_visibility(Particle p) {
				%s
			}

			void %s_collide(uint index, inout Particle p, vec3 previous, vec3 hit, vec3 normal) {
				%s
			}

			void %s_shade(inout Particle p) {
				%s
			}

			bool %s_should_spawn(uint index) {
				%s
			}

			int %s_collision_mode(Particle p) {
				%s
			}
		]],
				def.name,
				def.spawn,
				def.name,
				def.update,
				def.name,
				def.visibility,
				def.name,
				def.collide,
				def.name,
				def.shade,
				def.name,
				def.should_spawn or "return false;",
				def.name,
				def.collision_mode
			)
		spawns[#spawns + 1] = string.format("case %du: %s_spawn(index, generation, p); break;", i - 1, def.name)
		updates[#updates + 1] = string.format("case %du: %s_update(index, dt, p); break;", i - 1, def.name)
		shades[#shades + 1] = string.format("case %du: %s_shade(p); break;", i - 1, def.name)
		should_spawns[#should_spawns + 1] = string.format("case %du: forced = %s_should_spawn(index); break;", i - 1, def.name)
		collision_modes[#collision_modes + 1] = string.format("case %du: mode = %s_collision_mode(p); break;", i - 1, def.name)
		collides[#collides + 1] = string.format("case %du: %s_collide(index, p, particle_previous, hit, normal); break;", i - 1, def.name)
		visibilities[#visibilities + 1] = string.format("case %du: visibility *= %s_visibility(p); break;", i - 1, def.name)
	end

	return particles.GetCollisionGLSL() .. table.concat(functions, "\n") .. [[
		// the irradiance divided by pi at P from the side N faces: the probes' where there are probes that can see P, the
		// sky's environment where there are none
		vec3 get_particle_irradiance(vec3 P, vec3 N) {
			vec3 environment = sample_environment_irradiance(particle_data.env_irradiance_tex, N);

			if (ddgi_data.ddgi_cascade_count == 0 || !ddgi_in_volume(P)) return environment;

			float weight;
			vec4 probes = ddgi_sample_irradiance(P, N, N, vec3(0.0), ddgi_data.ddgi_smooth_blend != 0, DDGI_VISIBILITY_MIN_WEIGHT, weight);
			// where the probes are all but hidden the sample fades to nothing, which gives way to the sky as smoothly
			return mix(environment, probes.rgb, saturate(weight / ]] .. ddgi.MIN_WEIGHT .. [[));
		}

		// the light a particle scatters towards the viewer. view_dir points from the viewer to it
		vec3 get_particle_radiance(vec3 P, vec3 view_dir, float g, float forward_fraction) {
			vec3 sun_dir = get_current_primary_sun_direction();
			vec3 point = get_atmosphere_camera_origin(P);
			vec3 sun = ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * sample_transmittance_lut(point, sun_dir) * get_ground_fog_sun_transmittance(point, sun_dir) * get_particle_sun_visibility(P, sun_dir);
			vec3 radiance = sun * phase_henyey_greenstein(dot(view_dir, sun_dir), g);
			// the light around it, from the side the particle is seen against (forward scattered) and from the side
			// facing the viewer (scattered back), as much of each as the phase function scatters from that half
			radiance += get_particle_irradiance(P, view_dir) * forward_fraction + get_particle_irradiance(P, -view_dir) * (1.0 - forward_fraction);
			return radiance + get_local_light_scattering(view_dir, P, g);
		}

		void main() {
			uint index = gl_GlobalInvocationID.x;
			uint system_index = gl_GlobalInvocationID.y;

			if (system_index >= uint(particle_data.system_count)) return;

			systems_t system = particle_data.systems[system_index];

			if (index >= uint(system.count)) return;

			ParticleBuffer pool = ParticleBuffer(particle_data.pools[system_index]);
			Particle p = pool.p[index];
			bool was_hidden = p.visibility <= 0.0;
			bool alive = p.life > 0.0 && p.age < p.life;
			bool forced = false;

			if (system.scheduled != 0) {
				switch (system_index) {
					]] .. table.concat(should_spawns, "\n") .. [[
				}

				// a slot that is not asked for stays dead
				if (!alive && !forced) {
					if (p.visibility > 0.0) {
						p.visibility = 0.0;
						pool.p[index] = p;
					}

					return;
				}
			}

			bool fresh = !alive || forced;
			float dt = particle_data.dt;

			if (fresh) {
				uint generation = p.user.x + 1u;
				p = Particle(vec3(0.0), 0.0, vec3(0.0), 0.0, vec3(0.0), 0.0, vec3(0.0), 0.0, uvec3(generation, 0u, 0u), 0u);

				switch (system_index) {
					]] .. table.concat(spawns, "\n") .. [[
				}

				// the first spawn of a slot starts it somewhere in its life, or they all end at the same time
				if (generation == 1u && system.scheduled == 0) p.age = pcg3d_unorm(uvec3(index, system_index, 977u)).x * p.life;
			} else {
				p.age += dt;
				particle_previous = p.position;

				switch (system_index) {
					]] .. table.concat(updates, "\n") .. [[
				}

				vec3 hit;
				vec3 normal;

				int mode = system.collision;

				if (mode == 4) {
					switch (system_index) {
						]] .. table.concat(collision_modes, "\n") .. [[
					}
				}

				if (mode != 0 && particle_trace(mode, particle_previous, p.position, p.width * 0.5, hit, normal)) {
					switch (system_index) {
						]] .. table.concat(collides, "\n") .. [[
					}
				}
			}

			float distance_to_camera = distance(p.position, particle_data.camera_position);
			float visibility = 1.0;

			if (system.fade_far > 0.0) visibility = (1.0 - smoothstep(0.7 * system.fade_far, system.fade_far, distance_to_camera)) * smoothstep(0.3 * system.fade_near, system.fade_near, distance_to_camera);

			if (system.fade_time > 0.0) visibility *= smoothstep(0.0, system.fade_time, p.age) * smoothstep(0.0, system.fade_time, p.life - p.age);

			if (visibility > 0.0) {
				switch (system_index) {
					]] .. table.concat(visibilities, "\n") .. [[
				}
			}

			p.visibility = visibility;

			if (visibility > 0.0 && system.lit != 0 && (fresh || was_hidden || (index + uint(particle_data.frame)) % ]] .. particles.RELIGHT_INTERVAL .. [[u == 0u)) {
				vec3 view_dir = (p.position - particle_data.camera_position) / max(distance_to_camera, 1e-4);
				p.light = get_particle_radiance(p.position, view_dir, system.scatter_g, system.forward_fraction);
			}

			if (visibility > 0.0) {
				switch (system_index) {
					]] .. table.concat(shades, "\n") .. [[
				}
			}

			pool.p[index] = p;
		}
	]]
end

function particles.BuildSimulationPasses()
	-- whether the scene bvh is bound this frame, or a placeholder is
	local bvh_ready = false
	local placeholder
	local uniform_buffers = {
		{
			name = "ddgi_data",
			binding_index = BINDING_DDGI,
			block = ddgi.GetProbeBlockLayout(),
			write = function(self, block)
				if render3d.IsPassEnabled("ddgi") then
					return ddgi.WriteProbeBlock(self, block)
				end

				block.ddgi_cascade_count = 0
				return block
			end,
		},
		{
			name = "particle_data",
			binding_index = BINDING_DATA,
			block = {
				render3d.camera_block,
				{"frame", "int"},
				{"dt", "float"},
				{"env_irradiance_tex", "int"},
				{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
				{"light_count", "int"},
				{"shadows", scene_lights.BuildShadowsBlockLayout()},
				atmosphere.GetBlockLayout(),
				light_occlusion.GetBlockLayout(),
				surface_weather.block,
				gbuffer_layout.block,
				{"bvh_ready", "int"},
				pools_and_systems,
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				block.frame = system.GetFrameNumber()
				block.dt = particles.GetStepTime()
				block.env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
				surface_weather.WriteBlock(self, block)
				gbuffer_layout.WriteBlock(self, block)
				block.bvh_ready = bvh_ready and 1 or 0
				light_occlusion.WriteOcclusionBlock(block, medium_lighting.WriteLightsBlock(self, block))
				particles.WriteSystems(block)
				return block
			end,
		},
	}
	-- the barriers around the dispatch, the one before makes the last frame's draw and the other passes that read the pools done
	-- with them, the one after hands what the dispatch wrote to the draw and the next frame
	local before, after = {}, {}
	local pooled_before, pooled_after = {}, {}

	for i = 1, #particles.systems do
		before[i] = {srcAccessMask = "shader_read", dstAccessMask = "shader_write"}
		after[i] = {srcAccessMask = "shader_write", dstAccessMask = "shader_read"}
	end

	for i, def in ipairs(particles.systems) do
		assert(BINDING_FIRST_SYSTEM + i - 1 < 16)
		uniform_buffers[#uniform_buffers + 1] = {
			name = def.name .. "_data",
			binding_index = BINDING_FIRST_SYSTEM + i - 1,
			block = def.block,
			write = def.WriteBlock,
		}
	end

	return {
		{
			name = "particles_simulate",
			ComputePass = true,
			ColorFormat = {{"r8_unorm", {"particles_dummy", "r"}}},
			FramebufferSize = {x = 1, y = 1},
			framebuffer_count = 1,
			LocalSize = {x = particles.LOCAL_SIZE, y = 1, z = 1},
			sampled_images = {
				{
					binding_index = BINDING_OCCLUSION,
					get_descriptor = light_occlusion.GetOcclusionDescriptor,
				},
			},
			uniform_buffers = uniform_buffers,
			storage_buffers = {
				{binding_index = BINDING_LIGHT_GRID},
				{binding_index = BINDING_BVH_NODES},
				{binding_index = BINDING_BVH_TRIANGLES, count = scene_bvh.SOUP_CHUNKS},
			},
			on_pre_draw = function(self, cmd, frame, desc)
				light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)
				local wants_rays = false

				for _, def in ipairs(particles.systems) do
					if def.IsActive() and (def.collision == "rays" or def.UsesRays and def.UsesRays()) then wants_rays = true end
				end

				if wants_rays then scene_bvh.EnsureBuilt() end

				bvh_ready = wants_rays and scene_bvh.IsReady() and scene_bvh.node_buffer ~= nil

				if bvh_ready then
					scene_bvh.BindBuffers(self, desc, BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)
				else
					placeholder = placeholder or render.CreateBuffer{
						byte_size = 256,
						buffer_usage = {"storage_buffer"},
						memory_property = {"device_local"},
						label = "particles bvh placeholder",
					}
					self:UpdateDescriptorSet("storage_buffer", desc, BINDING_BVH_NODES, 0, placeholder, placeholder:GetSize())
					scene_bvh.BindTriangleBuffer(self, desc, BINDING_BVH_TRIANGLES, placeholder)
				end

				for _, def in ipairs(particles.systems) do
					if def.IsActive() then particles.GetPool(def, cmd) end
				end
			end,
			on_draw = function(self, cmd, fb, frame, desc)
				if not particles.IsActive() then return end

				local widest = 0
				table.clear(pooled_before)
				table.clear(pooled_after)

				for i, def in ipairs(particles.systems) do
					if def.pool then
						before[i].buffer = def.pool
						after[i].buffer = def.pool
						pooled_before[#pooled_before + 1] = before[i]
						pooled_after[#pooled_after + 1] = after[i]
					end

					if def.IsActive() then widest = math.max(widest, (def.GetCount())) end
				end

				cmd:PipelineBarrier{srcStage = {"vertex", "compute"}, dstStage = "compute", bufferBarriers = pooled_before}
				self:UploadConstants()
				self.pipeline:DispatchForSize(cmd, widest, #particles.systems, 1, desc, self.dynamic_offsets)
				cmd:PipelineBarrier{srcStage = "compute", dstStage = {"vertex", "compute"}, bufferBarriers = pooled_after}
			end,
			custom_declarations = particles.GetParticleGLSL() .. light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION, 0) .. light_grid.GetGLSL(BINDING_LIGHT_GRID) .. scene_bvh.GetDeclarationsGLSL(BINDING_BVH_NODES, BINDING_BVH_TRIANGLES),
			shader = glsl_common.GetHashGLSL() .. glsl_common.GetPhaseGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("particle_data") .. screen_reconstruct.GetViewDepthGLSL("particle_data") .. scene_bvh.GetTraversalGLSL() .. ibl.GetEnvironmentGLSLCode() .. ddgi.GetCommonGLSL() .. light_occlusion.GetSamplingGLSL("particle_data") .. scene_lights.GetLightGLSLCode() .. medium_lighting.GetSunHelpersGLSL("particle_data") .. atmosphere.GetGLSLDefines("particle_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. directional_shadows.GetMediumDirectionalShadowGLSL("particle_data", "get_particle_sun_visibility") .. scene_lights.GetPointShadowGLSL("particle_data") .. medium_lighting.GetLocalLightsGLSL("particle_data", LOCAL_LIGHT_LIMIT) .. particles.GetSimulationGLSL(),
		},
	}
end

-- the seconds the simulation advances this frame, a frame that took long (a stall, a breakpoint) does not
-- throw particles across the world
function particles.GetStepTime()
	return math.clamp(system.GetElapsedTime() - render3d.GetPreviousElapsedTime(), 0, 0.1)
end

local draw_block = {
	name = "particle_draw",
	binding_index = 3,
	block = {
		render3d.camera_block,
		render3d.prev_camera_block,
		post_source.pre_exposure_block,
		{"b0_tex", "int"},
		{"moments_tex", "int"},
		{"depth_warp", "vec2"},
		{"dt", "float"},
		pools_and_systems,
	},
	write = function(self, block)
		render3d.WriteCameraBlock(self, block)
		render3d.WritePreviousCameraBlock(self, block)
		post_source.WritePreExposureBlock(self, block)
		local b0, moments = translucent_moments.GetTextures()
		block.b0_tex = self:GetTextureIndex(b0)
		block.moments_tex = self:GetTextureIndex(moments)
		translucent_moments.WriteDepthWarp(block.depth_warp)
		block.dt = system.GetElapsedTime() - render3d.GetPreviousElapsedTime()
		particles.WriteSystems(block)
		return block
	end,
	upload_scope = "frame",
}
local vertex_outputs = {
	{"position", "vec3"},
	{"radiance", "vec3"},
	{"alpha", "float"},
	{"shape", "vec3"},
	{"motion", "vec2"},
}

local function get_vertex_glsl()
	return particles.GetParticleGLSL() .. [[
		vec2 get_particle_screen_motion(vec3 world_pos, vec3 prev_world_pos) {
			vec4 clip = particle_draw.projection * particle_draw.view * vec4(world_pos, 1.0);
			vec4 prev_clip = particle_draw.prev_projection * particle_draw.prev_view * vec4(prev_world_pos, 1.0);

			if (clip.w <= 0.0001 || prev_clip.w <= 0.0001) return vec2(0.0);

			return (clip.xy / clip.w - prev_clip.xy / prev_clip.w) * 0.5;
		}

		void main() {
			// the instances run through the systems one after the other, an empty system starts where the next does
			int system_index = 0;

			while (system_index + 1 < particle_draw.system_count && gl_InstanceIndex >= particle_draw.systems[system_index + 1].first) system_index++;

			systems_t system = particle_draw.systems[system_index];
			Particle p = ParticleBufferRead(particle_draw.pools[system_index]).p[gl_InstanceIndex - system.first];

			if (p.visibility <= 0.0) {
				gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
				return;
			}

			vec3 camera = particle_draw.camera_position;
			vec3 head = p.position;
			vec3 tail = head - p.velocity * system.streak_time;
			vec3 to_particle = head - camera;
			float dist = length(to_particle);
			float width = p.width;
			// at least a pixel and a half wide, fainter by as much
			float pixel = dist * 2.0 / (abs(particle_draw.projection[1][1]) * particle_draw.render_size.y);
			float drawn_width = max(width, pixel * 1.5);
			vec3 axis = head - tail;
			float path = length(axis);
			vec3 along_dir = path > 1e-6 ? axis / path : normalize(mat3(particle_draw.inv_view)[0]);
			vec3 side = normalize(cross(along_dir, to_particle));
			// the path with a round particle at each end, core is the straight part's share of its length
			float core = path / (path + drawn_width);
			// the coverage profile's average over the quad, so rounding the ends doesn't change the total
			float profile_average = core * (2.0 / 3.0) + (1.0 - core) * 0.39269908;
			// a point on the path is covered while the particle passes it, its width of the path's length
			float alpha = width / (path + width) * (width / drawn_width) * system.coverage_scale * p.visibility;
			int corner = gl_VertexIndex;
			float across = float(corner & 1) * 2.0 - 1.0;
			float along = float(corner >> 1) * 2.0 - 1.0;
			vec3 position = mix(tail, head, along * 0.5 + 0.5) + along_dir * along * drawn_width * 0.5 + side * across * drawn_width * 0.5;
			out_position = position;
			out_radiance = p.radiance;
			out_alpha = alpha / profile_average;
			out_shape = vec3(across, along, core);
			out_motion = get_particle_screen_motion(position, position - p.velocity * particle_draw.dt);
			gl_Position = particle_draw.projection * particle_draw.view * vec4(position, 1.0);
		}
	]]
end

local coverage_glsl = [[
	float get_particle_alpha() {
		float end_distance = max(abs(in_shape.y) - in_shape.z, 0.0) / max(1.0 - in_shape.z, 1e-4);
		return min(in_alpha * max(1.0 - in_shape.x * in_shape.x - end_distance * end_distance, 0.0), 1.0);
	}
]]
particles.name = "particles"

function particles.IsActive()
	if not render3d.IsPassEnabled("particles") or not render3d.IsPassEnabled("translucent") then
		return false
	end

	for _, def in ipairs(particles.systems) do
		if def.IsActive() and def.pool then return true end
	end

	return false
end

function particles.Draw(pipeline, cmd)
	pipeline:UploadConstants()
	local total = 0

	for _, def in ipairs(particles.systems) do
		if def.IsActive() then total = total + (def.GetCount()) end
	end

	cmd:Draw(4, total, 0, 0)
end

function particles.BuildPasses()
	return {
		{
			name = "particles_moments",
			draw_in_prerender = false,
			dont_create_framebuffers = true,
			ColorFormat = {
				{"r32_sfloat", {"b0", "r"}},
				{"r32g32b32a32_sfloat", {"moments", "rgba"}},
			},
			DepthFormat = gbuffer_layout.DEPTH_FORMAT,
			Topology = "triangle_strip",
			vertex = {
				outputs = vertex_outputs,
				uniform_buffers = {draw_block},
				shader = get_vertex_glsl(),
			},
			fragment = {
				uniform_buffers = {draw_block},
				shader = translucent_moments.GLSL .. coverage_glsl .. [[
					void main() {
						float absorbance = -log(max(1.0 - get_particle_alpha(), 1e-3));
						float depth = moments_warp_depth(distance(in_position, particle_draw.camera_position), particle_draw.depth_warp);
						float depth2 = depth * depth;
						set_b0(absorbance);
						set_moments(vec4(depth, depth2, depth2 * depth, depth2 * depth2) * absorbance);
					}
				]],
			},
			CullMode = "none",
			Blend = true,
			SrcColorBlendFactor = "one",
			DstColorBlendFactor = "one",
			ColorBlendOp = "add",
			SrcAlphaBlendFactor = "one",
			DstAlphaBlendFactor = "one",
			AlphaBlendOp = "add",
			color_blend = {attachments = {{}, translucent_moments.ADDITIVE}},
			DepthTest = true,
			DepthWrite = false,
			DepthCompareOp = "greater_or_equal",
		},
		{
			name = "particles_accumulate",
			draw_in_prerender = false,
			dont_create_framebuffers = true,
			ColorFormat = {
				{"r16g16b16a16_sfloat", {"color", "rgba"}},
				{"r16g16b16a16_sfloat", {"motion", "rgba"}},
				{"r16g16b16a16_sfloat", {"additive", "rgba"}},
				{"r16g16b16a16_sfloat", {"modulate", "rgba"}},
			},
			DepthFormat = gbuffer_layout.DEPTH_FORMAT,
			Topology = "triangle_strip",
			vertex = {
				outputs = vertex_outputs,
				uniform_buffers = {draw_block},
				shader = get_vertex_glsl(),
			},
			fragment = {
				uniform_buffers = {draw_block},
				shader = post_source.GetPreExposureGLSL("particle_draw") .. translucent_moments.GLSL .. coverage_glsl .. [[
					void main() {
						ivec2 pixel = ivec2(gl_FragCoord.xy);
						float transmittance = moments_transmittance(
							texelFetch(TEXTURE(particle_draw.b0_tex), pixel, 0).r,
							texelFetch(TEXTURE(particle_draw.moments_tex), pixel, 0),
							moments_warp_depth(distance(in_position, particle_draw.camera_position), particle_draw.depth_warp)
						);
						float alpha = get_particle_alpha();
						set_color(vec4(min(in_radiance * (alpha * get_pre_exposure()), vec3(65504.0)), alpha) * transmittance);
						// streaks are thin and fast, a pixel with one follows it, or taa would average it away
						set_motion(vec4(in_motion, 1.0, 0.0) * transmittance);
						set_additive(vec4(0.0));
						set_modulate(vec4(1.0));
					}
				]],
			},
			CullMode = "none",
			Blend = true,
			SrcColorBlendFactor = "one",
			DstColorBlendFactor = "one",
			ColorBlendOp = "add",
			SrcAlphaBlendFactor = "one",
			DstAlphaBlendFactor = "one",
			AlphaBlendOp = "add",
			color_blend = {attachments = {{}, translucent_moments.ADDITIVE, translucent_moments.ADDITIVE, translucent_moments.MULTIPLY}},
			DepthTest = true,
			DepthWrite = false,
			DepthCompareOp = "greater_or_equal",
		},
	}
end

event.AddListener("PreDraw3DTranslucent", "particles", function()
	for _, def in ipairs(particles.systems) do
		if def.IsActive() and particles.IsActive() then
			render3d.ExtendTranslucentDepthRange(def.depth_near, def.depth_far)
		end
	end
end)

return particles
