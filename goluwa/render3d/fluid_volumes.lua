local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Texture = import("goluwa/render/texture.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local media = import("goluwa/render3d/media.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local medium_common = import("goluwa/render3d/medium_common.lua")
local medium_lighting = import("goluwa/render3d/medium_lighting.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local Color = import("goluwa/structs/color.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local event = import("goluwa/event.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local rt = import("goluwa/render3d/scene/rt.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local physics = import("goluwa/physics.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local fluid_volumes = {}
fluid_volumes.MAX_VOLUMES = 16
fluid_volumes.MAX_EMITTERS = 16
fluid_volumes.MAX_RESOLUTION = 128
fluid_volumes.MAX_SUBSTEPS = 2
fluid_volumes.MAX_STEP = 1 / 30
fluid_volumes.PRESSURE_ITERATIONS = 24
fluid_volumes.PRESSURE_OVERRELAXATION = 1.6
fluid_volumes.OBSTACLE_INTERVAL = 0.5
fluid_volumes.AMBIENT_TEMPERATURE = 293
fluid_volumes.GRAVITY = 9.81
fluid_volumes.EMITTER_RESPONSE = 20
fluid_volumes.MAX_PUSHERS = 16
fluid_volumes.MAX_LIGHT_SLOTS = 4
fluid_volumes.MAX_FREE_STATES = 8
fluid_volumes.MAX_TRANSIENTS = 6
fluid_volumes.TRANSIENT_MIN_AGE = 1
fluid_volumes.TRANSIENT_MAX_AGE = 40
fluid_volumes.TRANSIENT_SMOKE = 0.05
fluid_volumes.FIRE_LIGHT_RESPONSE = 0.5
fluid_volumes.FIRE_LIGHT_MIN_LUMEN = 1
fluid_volumes.PUSHER_DRAG = 15
fluid_volumes.PUSHER_REACH = 1.5
fluid_volumes.PUSHER_BOX_ROUNDING = 0.05
fluid_volumes.MODES = {raymarch = 0, froxels = 1}
fluid_volumes.volumes = {}
fluid_volumes.emitters = {}
fluid_volumes.generation = 0
local RAY_QUERY
local LOCAL_SIZE = 4
local SLOTS_PER_FRAME = fluid_volumes.MAX_VOLUMES * fluid_volumes.MAX_SUBSTEPS
local FRAME_SPAN

local function read_device()
	if FRAME_SPAN then return end

	RAY_QUERY = render.GetDevice().ray_query_supported
	FRAME_SPAN = math.max(render.GetSwapchainImageCount() or 1, 1)
end

local states = {}
local splats = {}
local atlas = {width = 0, height = 0, depth = 0}
fluid_volumes.atlas = atlas

function fluid_volumes.AddVolume(volume)
	list.insert(fluid_volumes.volumes, volume)
end

function fluid_volumes.GetVolumes()
	return fluid_volumes.volumes
end

function fluid_volumes.AddEmitter(emitter)
	list.insert(fluid_volumes.emitters, emitter)
end

function fluid_volumes.RemoveEmitter(emitter)
	for i, other in ipairs(fluid_volumes.emitters) do
		if other == emitter then
			list.remove(fluid_volumes.emitters, i)

			break
		end
	end
end

function fluid_volumes.Splat(position, radius, amounts)
	list.insert(
		splats,
		{
			position = position:Copy(),
			radius = radius,
			smoke = amounts.smoke or 0,
			temperature = amounts.temperature or 0,
			fuel = amounts.fuel or 0,
			velocity = amounts.velocity and amounts.velocity:Copy() or Vec3(0, 0, 0),
			expand = amounts.expand or 0,
		}
	)
end

function fluid_volumes.Reset(volume)
	local state = states[volume]

	if state then state.needs_fill = true end
end

function fluid_volumes.GetGridSize(volume)
	local size = volume:GetSize()
	local resolution = volume:GetResolution()
	assert(
		resolution >= 2 and resolution <= fluid_volumes.MAX_RESOLUTION,
		"fluid volume resolution must be between 2 and " .. fluid_volumes.MAX_RESOLUTION
	)
	local cell = math.max(size.x, size.y, size.z) / resolution
	return math.max(math.ceil(size.x / cell - 1e-3), 2),
	math.max(math.ceil(size.y / cell - 1e-3), 2),
	math.max(math.ceil(size.z / cell - 1e-3), 2),
	cell
end

local EMITTER_LAYOUT = {
	{"sphere", "vec4"},
	{"amounts", "vec4"},
	{"velocity", "vec4"},
}
local params = {shift_x = 0, shift_y = 0, shift_z = 0}
local fluid_block = {
	{"to_world", "mat4"},
	{"to_local", "mat4"},
	{"size", "ivec4"},
	{"half_size", "vec4"},
	{"gravity", "vec4"},
	{"wind", "vec4"},
	{"fill", "vec4"},
	{"shape", "vec4"},
	{"forces", "vec4"},
	{"decay", "vec4"},
	{"combustion", "vec4"},
	{"thermal", "vec4"},
	{"turbulence", "vec4"},
	{"optics", "vec4"},
	{"light_slots", "ivec4"},
	{"shift", "ivec4"},
	{"flags", "ivec4"},
	{"emitters", EMITTER_LAYOUT, fluid_volumes.MAX_EMITTERS},
}

local function write_fluid_block(self, block)
	ffi.copy(block.to_world, params.to_world, 64)
	ffi.copy(block.to_local, params.to_local, 64)
	block.size[0], block.size[1], block.size[2], block.size[3] = params.nx, params.ny, params.nz, params.atlas_z
	block.half_size[0], block.half_size[1], block.half_size[2], block.half_size[3] = params.half.x, params.half.y, params.half.z, params.cell
	block.gravity[0], block.gravity[1], block.gravity[2] = params.gravity.x, params.gravity.y, params.gravity.z
	block.wind[0], block.wind[1], block.wind[2] = params.wind.x, params.wind.y, params.wind.z
	block.fill[0], block.fill[1], block.fill[2], block.fill[3] = params.fill, params.noise_scale, params.noise_amount, params.time
	block.shape[0], block.shape[1] = params.height_falloff, params.edge_softness
	block.forces[0], block.forces[1], block.forces[2], block.forces[3] = params.buoyancy, params.weight, params.vorticity, params.dt
	block.decay[0], block.decay[1], block.decay[2], block.decay[3] = params.dissipation, params.cooling, params.flame_life, params.soot_yield
	block.combustion[0], block.combustion[1], block.combustion[2] = params.ignition, params.burn_rate, params.heat_release
	block.thermal[0], block.thermal[1] = fluid_volumes.AMBIENT_TEMPERATURE, params.flame_temperature
	block.turbulence[0], block.turbulence[1] = params.turbulence, params.turbulence_scale
	block.optics[0], block.optics[1] = params.smoke_absorption, params.flame_absorption

	for i = 0, 3 do
		block.light_slots[i] = params.light_slots[i + 1]
	end

	block.shift[0], block.shift[1], block.shift[2] = params.shift_x, params.shift_y, params.shift_z
	block.flags[0], block.flags[1], block.flags[2], block.flags[3] = params.floor, params.emitter_count, params.obstacle_rays and 1 or 0, 0

	for i = 0, params.emitter_count - 1 do
		local src = params.emitters[i + 1]
		local dst = block.emitters[i]
		dst.sphere[0], dst.sphere[1], dst.sphere[2], dst.sphere[3] = src.x, src.y, src.z, src.radius
		dst.amounts[0], dst.amounts[1], dst.amounts[2], dst.amounts[3] = src.smoke, src.temperature, src.fuel, src.blend
		dst.velocity[0], dst.velocity[1], dst.velocity[2], dst.velocity[3] = src.vx, src.vy, src.vz, src.expand
	end

	return block
end

local FLUID_UBO = {
	name = "fluid",
	binding_index = 9,
	block = fluid_block,
	write = write_fluid_block,
}
local PUSHER_LAYOUT = {
	{"center", "vec4"},
	{"axis_x", "vec4"},
	{"axis_y", "vec4"},
	{"axis_z", "vec4"},
	{"half_size", "vec4"},
	{"velocity", "vec4"},
	{"spin", "vec4"},
}
local pushers = {count = 0, drag = 0}

local function write_vec3(out, v)
	out[0], out[1], out[2] = v.x, v.y, v.z
end

local function write_pusher_block(self, block)
	block.count = pushers.count
	block.drag = pushers.drag
	block.reach = fluid_volumes.PUSHER_REACH

	for i = 0, pushers.count - 1 do
		local src = pushers[i + 1]
		local dst = block.pushers[i]
		write_vec3(dst.center, src.center)
		dst.center[3] = src.radius
		write_vec3(dst.axis_x, src.axis_x)
		write_vec3(dst.axis_y, src.axis_y)
		write_vec3(dst.axis_z, src.axis_z)
		write_vec3(dst.half_size, src.half_size)
		write_vec3(dst.velocity, src.velocity)
		write_vec3(dst.spin, src.spin)
	end

	return block
end

local COMMON_GLSL = [[
	ivec3 fluid_dims() {
		return fluid.size.xyz;
	}

	bool fluid_in_grid(ivec3 c) {
		return all(greaterThanEqual(c, ivec3(0))) && all(lessThan(c, fluid.size.xyz));
	}

	vec3 fluid_cell_local(vec3 g) {
		return g * fluid.half_size.w - fluid.half_size.xyz;
	}

	vec3 fluid_grid_uvw(vec3 g) {
		return g / vec3(fluid.size.xyz);
	}

	float fluid_outside(vec3 g) {
		vec3 d = max(max(-g, g - vec3(fluid.size.xyz)), vec3(0.0));
		return clamp(max(d.x, max(d.y, d.z)), 0.0, 1.0);
	}

	float fluid_emitter_weight(int i, vec3 local) {
		vec4 sphere = fluid.emitters[i].sphere;
		float d = length(local - sphere.xyz) / max(sphere.w, 1e-4);
		float w = clamp(1.0 - d, 0.0, 1.0);
		return w * w * (3.0 - 2.0 * w);
	}
]]

local function obstacle_glsl(binding)
	return "layout(set = 0, binding = " .. binding .. ", r8) uniform readonly image3D obstacles;\n"
end

local SOLID_GLSL = [[
	bool fluid_solid(ivec3 c) {
		return fluid_in_grid(c) && imageLoad(obstacles, c).r > 0.5;
	}
]]

local function motion_glsl(binding)
	return "layout(set = 0, binding = " .. binding .. ", rgba16f) uniform readonly image3D motion;\n"
end

local function create_pipeline(name, config)
	config.name = "fluid_" .. name
	config.DescriptorSetCount = FRAME_SPAN * SLOTS_PER_FRAME
	config.LocalSize = config.LocalSize or {x = LOCAL_SIZE, y = LOCAL_SIZE, z = LOCAL_SIZE}
	return EasyPipeline.Compute(config)
end

local pipelines = {}

local function get_pipelines()
	if pipelines.fill then return pipelines end

	pipelines.fill = create_pipeline(
		"fill",
		{
			storage_images = {
				{binding_index = 0},
				{binding_index = 1},
				{binding_index = 2},
				{binding_index = 3},
				{binding_index = 4},
			},
			uniform_buffers = {FLUID_UBO},
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba16f) uniform writeonly image3D velocity_a;
				layout(set = 0, binding = 1, rgba16f) uniform writeonly image3D velocity_b;
				layout(set = 0, binding = 2, rgba16f) uniform writeonly image3D scalars_a;
				layout(set = 0, binding = 3, rgba16f) uniform writeonly image3D scalars_b;
				layout(set = 0, binding = 4, r32f) uniform writeonly image3D pressure;
			]],
			shader = glsl_common.GetNoiseGLSL() .. COMMON_GLSL .. [[
				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					vec3 world = (fluid.to_world * vec4(fluid_cell_local(vec3(c) + 0.5), 1.0)).xyz;
					vec3 p = (world - fluid.wind.xyz * fluid.fill.w) / max(fluid.fill.y, 1e-4);
					float n = value_noise3(p) * 0.5 + value_noise3(p * 2.03 + 17.1) * 0.3 + value_noise3(p * 4.11 + 41.7) * 0.2;
					float density = fluid.fill.x * max(mix(1.0, (n - 0.5) * 3.0 + 1.0, fluid.fill.z), 0.0);
					vec3 local = fluid_cell_local(vec3(c) + 0.5);

					if (fluid.shape.x > 0.0) density *= exp(-(local.y + fluid.half_size.y) / fluid.shape.x);

					if (fluid.shape.y > 0.0) {
						vec3 inside = fluid.half_size.xyz - abs(local);
						density *= smoothstep(0.0, fluid.shape.y, min(inside.x, min(inside.y, inside.z)));
					}
					vec4 scalars = vec4(density, fluid.thermal.x, 0.0, 0.0);
					imageStore(velocity_a, c, vec4(fluid.wind.xyz, 0.0));
					imageStore(velocity_b, c, vec4(fluid.wind.xyz, 0.0));
					imageStore(scalars_a, c, scalars);
					imageStore(scalars_b, c, scalars);
					imageStore(pressure, c, vec4(0.0));
				}
			]],
		}
	)
	pipelines.obstacles = create_pipeline(
		"obstacles",
		{
			storage_images = {{binding_index = 0}},
			uniform_buffers = {FLUID_UBO},
			descriptor_sets = RAY_QUERY and
				{
					{type = "acceleration_structure_khr", binding_index = 1, stageFlags = "compute"},
				} or
				nil,
			custom_declarations = (
					RAY_QUERY and
					hit.GetSceneGLSL("fluid_scene", 1) or
					""
				) .. [[
				layout(set = 0, binding = 0, r8) uniform writeonly image3D out_obstacles;
			]],
			shader = COMMON_GLSL .. (
					RAY_QUERY and
					hit.GetOccludedGLSL("fluid_scene") or
					hit.GetStubOccludedGLSL()
				) .. [[
				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					bool solid = fluid.flags.x != 0 && c.y == 0;

					if (!solid && fluid.flags.z != 0) {
						vec3 world = (fluid.to_world * vec4(fluid_cell_local(vec3(c) + 0.5), 1.0)).xyz;
						float reach = fluid.half_size.w * 0.5;

						for (int axis = 0; axis < 6 && !solid; axis++) {
							vec3 dir = vec3(0.0);
							dir[axis >> 1] = (axis & 1) == 0 ? 1.0 : -1.0;
							solid = scene_occluded(world, normalize(mat3(fluid.to_world) * dir), 0.0, reach);
						}
					}

					imageStore(out_obstacles, c, vec4(solid ? 1.0 : 0.0));
				}
			]],
		}
	)
	pipelines.shift = create_pipeline(
		"shift",
		{
			storage_images = {
				{binding_index = 0},
				{binding_index = 1},
				{binding_index = 2},
				{binding_index = 3},
				{binding_index = 4},
				{binding_index = 5},
				{binding_index = 6},
			},
			uniform_buffers = {FLUID_UBO},
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba16f) uniform readonly image3D velocity_source;
				layout(set = 0, binding = 1, rgba16f) uniform writeonly image3D velocity_target;
				layout(set = 0, binding = 2, rgba16f) uniform readonly image3D scalars_source;
				layout(set = 0, binding = 3, rgba16f) uniform writeonly image3D scalars_target;
				layout(set = 0, binding = 4, r8) uniform readonly image3D obstacles_source;
				layout(set = 0, binding = 5, r8) uniform writeonly image3D obstacles_target;
				layout(set = 0, binding = 6, r32f) uniform writeonly image3D pressure;
			]],
			shader = COMMON_GLSL .. [[
				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					ivec3 source = c + fluid.shift.xyz;
					bool inside = fluid_in_grid(source);
					imageStore(velocity_target, c, inside ? imageLoad(velocity_source, source) : vec4(fluid.wind.xyz, 0.0));
					imageStore(scalars_target, c, inside ? imageLoad(scalars_source, source) : vec4(0.0, fluid.thermal.x, 0.0, 0.0));
					imageStore(obstacles_target, c, inside ? imageLoad(obstacles_source, source) : vec4(0.0));
					imageStore(pressure, c, vec4(0.0));
				}
			]],
		}
	)
	pipelines.pushers = create_pipeline(
		"pushers",
		{
			storage_images = {{binding_index = 0}, {binding_index = 1}, {binding_index = 2}},
			uniform_buffers = {
				FLUID_UBO,
				{
					name = "pusher_data",
					binding_index = 10,
					block = {
						{"count", "int"},
						{"drag", "float"},
						{"reach", "float"},
						{"pushers", PUSHER_LAYOUT, fluid_volumes.MAX_PUSHERS},
					},
					write = write_pusher_block,
				},
			},
			custom_declarations = [[
				layout(set = 0, binding = 0, r8) uniform writeonly image3D out_obstacles;
				layout(set = 0, binding = 1, rgba16f) uniform writeonly image3D out_motion;
				layout(set = 0, binding = 2, r8) uniform readonly image3D static_obstacles;
			]],
			shader = COMMON_GLSL .. [[
				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					bool solid = imageLoad(static_obstacles, c).r > 0.5;
					vec3 local = fluid_cell_local(vec3(c) + 0.5);
					vec3 velocity = vec3(0.0);
					float weight = 0.0;
					float reach = pusher_data.reach * fluid.half_size.w;

					for (int i = 0; i < pusher_data.count && !solid; i++) {
						vec4 center = pusher_data.pushers[i].center;
						vec3 d = local - center.xyz;
						vec3 p = vec3(dot(d, pusher_data.pushers[i].axis_x.xyz), dot(d, pusher_data.pushers[i].axis_y.xyz), dot(d, pusher_data.pushers[i].axis_z.xyz));
						vec3 q = abs(p) - (pusher_data.pushers[i].half_size.xyz - center.w);
						float dist = length(max(q, vec3(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0) - center.w;

						if (dist >= reach) continue;

						vec3 v = pusher_data.pushers[i].velocity.xyz + cross(pusher_data.pushers[i].spin.xyz, d);

						if (dist <= 0.0) {
							solid = true;
							velocity = v;
							weight = 1.0;
						} else if (1.0 - dist / reach > weight) {
							weight = 1.0 - dist / reach;
							velocity = v;
						}
					}

					imageStore(out_obstacles, c, vec4(solid ? 1.0 : 0.0));
					imageStore(out_motion, c, vec4(velocity, solid ? 1.0 : weight * pusher_data.drag));
				}
			]],
		}
	)
	pipelines.advect_velocity = create_pipeline(
		"advect_velocity",
		{
			storage_images = {{binding_index = 0}, {binding_index = 3}, {binding_index = 4}},
			sampled_images = {{binding_index = 1}, {binding_index = 2}},
			uniform_buffers = {FLUID_UBO},
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba16f) uniform writeonly image3D out_velocity;
				layout(set = 0, binding = 1) uniform sampler3D velocity;
				layout(set = 0, binding = 2) uniform sampler3D scalars;
			]] .. obstacle_glsl(3) .. motion_glsl(4),
			shader = glsl_common.GetNoiseGLSL() .. COMMON_GLSL .. SOLID_GLSL .. [[
				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					vec4 m = imageLoad(motion, c);

					if (fluid_solid(c)) {
						imageStore(out_velocity, c, vec4(m.xyz, 0.0));
						return;
					}

					float dt = fluid.forces.w;
					vec3 g = vec3(c) + 0.5;
					vec3 u = texelFetch(velocity, c, 0).xyz;
					vec3 back = g - dt * u / fluid.half_size.w;
					vec3 advected = mix(textureLod(velocity, fluid_grid_uvw(back), 0.0).xyz, fluid.wind.xyz, fluid_outside(back));
					vec4 s = texelFetch(scalars, c, 0);
					float ambient = fluid.thermal.x;
					vec3 up = -normalize(fluid.gravity.xyz);
					float lift = fluid.forces.x * (s.y - ambient) / ambient - fluid.forces.y * s.x;
					advected += dt * length(fluid.gravity.xyz) * lift * up;
					vec3 local = fluid_cell_local(g);

					if (fluid.turbulence.x > 0.0) {
						float time = fluid.fill.w;
						vec3 q = local / max(fluid.turbulence.y, 1e-4) + vec3(0.37, -0.53, 0.29) * time / max(fluid.turbulence.y, 1e-4);
						vec3 swirl = vec3(value_noise3(q), value_noise3(q + vec3(31.7, 7.1, 3.3)), value_noise3(q + vec3(5.9, 71.3, 17.9))) - 0.5;
						advected += dt * fluid.turbulence.x * 2.0 * swirl;
					}

					for (int i = 0; i < fluid.flags.y; i++) {
						float w = fluid_emitter_weight(i, local);

						if (w <= 0.0) continue;

						vec4 v = fluid.emitters[i].velocity;
						vec3 outward = local - fluid.emitters[i].sphere.xyz;
						advected = mix(advected, v.xyz + outward / max(length(outward), 1e-4) * v.w, w * fluid.emitters[i].amounts.w);
					}

					advected = mix(advected, m.xyz, m.w);
					imageStore(out_velocity, c, vec4(advected, 0.0));
				}
			]],
		}
	)
	pipelines.predict = create_pipeline(
		"predict",
		{
			storage_images = {{binding_index = 0}},
			sampled_images = {{binding_index = 1}, {binding_index = 2}},
			uniform_buffers = {FLUID_UBO},
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba16f) uniform writeonly image3D out_predicted;
				layout(set = 0, binding = 1) uniform sampler3D velocity;
				layout(set = 0, binding = 2) uniform sampler3D scalars;
			]],
			shader = COMMON_GLSL .. [[
				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					vec3 g = vec3(c) + 0.5;
					vec3 back = g - fluid.forces.w * texelFetch(velocity, c, 0).xyz / fluid.half_size.w;
					vec4 inflow = vec4(0.0, fluid.thermal.x, 0.0, 0.0);
					imageStore(out_predicted, c, mix(textureLod(scalars, fluid_grid_uvw(back), 0.0), inflow, fluid_outside(back)));
				}
			]],
		}
	)
	pipelines.correct = create_pipeline(
		"correct",
		{
			storage_images = {{binding_index = 0}, {binding_index = 4}},
			sampled_images = {{binding_index = 1}, {binding_index = 2}, {binding_index = 3}},
			uniform_buffers = {FLUID_UBO},
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba16f) uniform writeonly image3D out_scalars;
				layout(set = 0, binding = 1) uniform sampler3D velocity;
				layout(set = 0, binding = 2) uniform sampler3D scalars;
				layout(set = 0, binding = 3) uniform sampler3D predicted;
			]] .. obstacle_glsl(4),
			shader = COMMON_GLSL .. SOLID_GLSL .. [[
				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					float ambient = fluid.thermal.x;

					if (fluid_solid(c)) {
						imageStore(out_scalars, c, vec4(0.0, ambient, 0.0, 0.0));
						return;
					}

					float dt = fluid.forces.w;
					vec3 g = vec3(c) + 0.5;
					vec3 step_cells = dt * texelFetch(velocity, c, 0).xyz / fluid.half_size.w;
					vec3 back = g - step_cells;
					vec4 inflow = vec4(0.0, ambient, 0.0, 0.0);
					vec4 hat = texelFetch(predicted, c, 0);
					vec4 hat_back = mix(textureLod(predicted, fluid_grid_uvw(g + step_cells), 0.0), inflow, fluid_outside(g + step_cells));
					vec4 result = hat + 0.5 * (texelFetch(scalars, c, 0) - hat_back);
					ivec3 base = ivec3(floor(back - 0.5));
					vec4 low = vec4(1e30);
					vec4 high = vec4(-1e30);

					for (int i = 0; i < 8; i++) {
						vec4 v = texelFetch(scalars, clamp(base + ivec3(i & 1, (i >> 1) & 1, i >> 2), ivec3(0), fluid.size.xyz - 1), 0);
						low = min(low, v);
						high = max(high, v);
					}

					float outside = fluid_outside(back);
					low = mix(low, min(low, inflow), outside);
					high = mix(high, max(high, inflow), outside);
					result = mix(result, hat, vec4(lessThan(result, low)) + vec4(greaterThan(result, high)));
					result.yzw = hat.yzw;
					float smoke = result.x;
					float temperature = result.y;
					float fuel = result.z;
					float flame = result.w;
					vec3 local = fluid_cell_local(g);

					for (int i = 0; i < fluid.flags.y; i++) {
						float w = fluid_emitter_weight(i, local);

						if (w <= 0.0) continue;

						vec4 amounts = fluid.emitters[i].amounts;
						smoke += amounts.x * w * dt;
						fuel += amounts.z * w * dt;

						if (amounts.y > temperature) temperature = mix(temperature, amounts.y, w * amounts.w);
					}

					if (fuel > 0.0 && temperature > fluid.combustion.x) {
						float burned = fuel * (1.0 - exp(-fluid.combustion.y * dt));
						fuel -= burned;
						flame += burned;
						temperature += min(burned * fluid.combustion.z, max(fluid.thermal.y - temperature, 0.0));
					}

					float oxidized = flame * (1.0 - exp(-dt / max(fluid.decay.z, 1e-4)));
					flame -= oxidized;
					smoke += oxidized * fluid.decay.w;
					float dissipation = exp(-fluid.decay.x * dt);
					smoke *= dissipation;
					fuel *= dissipation;
					temperature = ambient + (temperature - ambient) * exp(-fluid.decay.y * dt);
					imageStore(out_scalars, c, max(vec4(smoke, temperature, fuel, flame), vec4(0.0)));
				}
			]],
		}
	)
	pipelines.curl = create_pipeline(
		"curl",
		{
			storage_images = {{binding_index = 0}, {binding_index = 1}},
			uniform_buffers = {FLUID_UBO},
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba16f) uniform writeonly image3D out_curl;
				layout(set = 0, binding = 1, rgba16f) uniform readonly image3D velocity;
			]],
			shader = COMMON_GLSL .. [[
				vec3 v(ivec3 c) {
					return imageLoad(velocity, clamp(c, ivec3(0), fluid.size.xyz - 1)).xyz;
				}

				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					vec3 l = v(c - ivec3(1, 0, 0));
					vec3 r = v(c + ivec3(1, 0, 0));
					vec3 d = v(c - ivec3(0, 1, 0));
					vec3 u = v(c + ivec3(0, 1, 0));
					vec3 b = v(c - ivec3(0, 0, 1));
					vec3 f = v(c + ivec3(0, 0, 1));
					vec3 curl = vec3((u.z - d.z) - (f.y - b.y), (f.x - b.x) - (r.z - l.z), (r.y - l.y) - (u.x - d.x)) / (2.0 * fluid.half_size.w);
					imageStore(out_curl, c, vec4(curl, length(curl)));
				}
			]],
		}
	)
	pipelines.confine = create_pipeline(
		"confine",
		{
			storage_images = {{binding_index = 0}, {binding_index = 1}},
			uniform_buffers = {FLUID_UBO},
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba16f) uniform image3D velocity;
				layout(set = 0, binding = 1, rgba16f) uniform readonly image3D curl;
			]],
			shader = COMMON_GLSL .. [[
				float magnitude(ivec3 c) {
					return imageLoad(curl, clamp(c, ivec3(0), fluid.size.xyz - 1)).w;
				}

				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					vec3 eta = vec3(
						magnitude(c + ivec3(1, 0, 0)) - magnitude(c - ivec3(1, 0, 0)),
						magnitude(c + ivec3(0, 1, 0)) - magnitude(c - ivec3(0, 1, 0)),
						magnitude(c + ivec3(0, 0, 1)) - magnitude(c - ivec3(0, 0, 1))
					);
					float eta_length = length(eta);

					if (eta_length < 1e-6) return;

					vec3 force = fluid.forces.z * fluid.half_size.w * cross(eta / eta_length, imageLoad(curl, c).xyz);
					imageStore(velocity, c, imageLoad(velocity, c) + vec4(force * fluid.forces.w, 0.0));
				}
			]],
		}
	)
	pipelines.divergence = create_pipeline(
		"divergence",
		{
			storage_images = {
				{binding_index = 0},
				{binding_index = 1},
				{binding_index = 2},
				{binding_index = 3},
			},
			uniform_buffers = {FLUID_UBO},
			custom_declarations = [[
				layout(set = 0, binding = 0, r32f) uniform writeonly image3D out_divergence;
				layout(set = 0, binding = 1, rgba16f) uniform readonly image3D velocity;
			]] .. obstacle_glsl(2) .. motion_glsl(3),
			shader = COMMON_GLSL .. SOLID_GLSL .. [[
				vec3 v(ivec3 c, vec3 center) {
					if (!fluid_in_grid(c)) return center;
					if (fluid_solid(c)) return imageLoad(motion, c).xyz;
					return imageLoad(velocity, c).xyz;
				}

				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					vec3 center = imageLoad(velocity, c).xyz;
					float divergence = (
						v(c + ivec3(1, 0, 0), center).x - v(c - ivec3(1, 0, 0), center).x +
						v(c + ivec3(0, 1, 0), center).y - v(c - ivec3(0, 1, 0), center).y +
						v(c + ivec3(0, 0, 1), center).z - v(c - ivec3(0, 0, 1), center).z
					) / (2.0 * fluid.half_size.w);
					imageStore(out_divergence, c, vec4(divergence));
				}
			]],
		}
	)
	pipelines.pressure = create_pipeline(
		"pressure",
		{
			storage_images = {{binding_index = 0}, {binding_index = 1}, {binding_index = 2}},
			block = {
				{"nx", "int"},
				{"ny", "int"},
				{"nz", "int"},
				{"parity", "int"},
				{"cell", "float"},
				{"omega", "float"},
			},
			write = function(self, block)
				block.nx, block.ny, block.nz = params.nx, params.ny, params.nz
				block.cell = params.cell
				block.parity = params.parity
				block.omega = fluid_volumes.PRESSURE_OVERRELAXATION
				return block
			end,
			custom_declarations = [[
				layout(set = 0, binding = 0, r32f) uniform image3D pressure;
				layout(set = 0, binding = 1, r32f) uniform readonly image3D divergence;
				layout(set = 0, binding = 2, r8) uniform readonly image3D obstacles;
			]],
			shader = [[
				bool in_grid(ivec3 c) {
					return all(greaterThanEqual(c, ivec3(0))) && all(lessThan(c, ivec3(compute.nx, compute.ny, compute.nz)));
				}

				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);
					c.x = c.x * 2 + ((c.y + c.z + compute.parity) & 1);

					if (!in_grid(c) || imageLoad(obstacles, c).r > 0.5) return;

					float sum = 0.0;
					float count = 0.0;

					for (int i = 0; i < 6; i++) {
						ivec3 n = c;
						n[i >> 1] += (i & 1) == 0 ? 1 : -1;

						if (!in_grid(n)) {
							count += 1.0;
						} else if (imageLoad(obstacles, n).r < 0.5) {
							sum += imageLoad(pressure, n).r;
							count += 1.0;
						}
					}

					if (count == 0.0) return;

					float p = imageLoad(pressure, c).r;
					float solved = (sum - compute.cell * compute.cell * imageLoad(divergence, c).r) / count;
					imageStore(pressure, c, vec4(mix(p, solved, compute.omega)));
				}
			]],
		}
	)
	pipelines.project = create_pipeline(
		"project",
		{
			storage_images = {
				{binding_index = 0},
				{binding_index = 1},
				{binding_index = 2},
				{binding_index = 3},
			},
			uniform_buffers = {FLUID_UBO},
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba16f) uniform image3D velocity;
				layout(set = 0, binding = 1, r32f) uniform readonly image3D pressure;
			]] .. obstacle_glsl(2) .. motion_glsl(3),
			shader = COMMON_GLSL .. SOLID_GLSL .. [[
				float p(ivec3 c, float center) {
					if (!fluid_in_grid(c)) return 0.0;
					if (fluid_solid(c)) return center;
					return imageLoad(pressure, c).r;
				}

				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					if (fluid_solid(c)) {
						imageStore(velocity, c, vec4(imageLoad(motion, c).xyz, 0.0));
						return;
					}

					float center = imageLoad(pressure, c).r;
					vec3 gradient = vec3(
						p(c + ivec3(1, 0, 0), center) - p(c - ivec3(1, 0, 0), center),
						p(c + ivec3(0, 1, 0), center) - p(c - ivec3(0, 1, 0), center),
						p(c + ivec3(0, 0, 1), center) - p(c - ivec3(0, 0, 1), center)
					) / (2.0 * fluid.half_size.w);
					vec3 u = imageLoad(velocity, c).xyz - gradient;

					for (int axis = 0; axis < 3; axis++) {
						ivec3 o = ivec3(0);
						o[axis] = 1;

						if (fluid_solid(c + o)) u[axis] = min(u[axis], imageLoad(motion, c + o)[axis]);
						if (fluid_solid(c - o)) u[axis] = max(u[axis], imageLoad(motion, c - o)[axis]);
					}

					imageStore(velocity, c, vec4(u, 0.0));
				}
			]],
		}
	)
	pipelines.light = create_pipeline(
		"light",
		{
			storage_images = {
				{binding_index = 0},
				{binding_index = 1},
				{binding_index = 3},
				{binding_index = 5},
				{binding_index = 6},
			},
			sampled_images = {{binding_index = 2}, {binding_index = 7}},
			storage_buffers = {{binding_index = 4}},
			uniform_buffers = {
				FLUID_UBO,
				{
					name = "light_data",
					binding_index = 10,
					block = {
						render3d.camera_block,
						{"lights", "uint64_t"},
						{"light_count", "int"},
						{"shadows", scene_lights.BuildShadowsBlockLayout()},
						atmosphere.GetBlockLayout(),
						unpack(light_occlusion.GetBlockLayout()),
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						medium_lighting.WriteLightsBlock(self, block)
						light_occlusion.WriteOcclusionBlock(block)
						return block
					end,
				},
			},
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba16f) uniform writeonly image3D out_fields;
				layout(set = 0, binding = 1, rgba16f) uniform writeonly image3D out_light;
				layout(set = 0, binding = 2) uniform sampler3D scalars;
				layout(set = 0, binding = 5, rgba16f) uniform writeonly image3D out_slot_depth;
				layout(set = 0, binding = 6, rgba8) uniform writeonly image3D out_slot_visibility;
				layout(std430, set = 0, binding = 4) buffer FluidStats {
					uint stats[16];
				};
			]] .. obstacle_glsl(3) .. light_occlusion.GetDeclarationGLSL(7, 0),
			shader = glsl_common.GetBlackbodyGLSL() .. scene_lights.GetLightGLSLCode() .. medium_lighting.GetSunHelpersGLSL("light_data") .. atmosphere.GetGLSLDefines("light_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. directional_shadows.GetMediumDirectionalShadowGLSL("light_data", "get_fluid_sun_visibility") .. scene_lights.GetPointShadowGLSL("light_data") .. light_occlusion.GetSamplingGLSL("light_data") .. medium_lighting.GetLightVisibilityGLSL("light_data") .. COMMON_GLSL .. SOLID_GLSL .. [[
				vec2 march(vec3 g, vec3 dir, float first, float growth, int steps) {
					vec2 depth = vec2(0.0);
					float t = first;
					float previous = 0.0;

					for (int i = 0; i < steps; i++) {
						vec3 p = g + dir * t;

						if (fluid_outside(p) > 0.0) break;

						vec4 s = textureLod(scalars, fluid_grid_uvw(p), 0.0);
						depth += vec2(s.x, s.w) * ((t - previous) * fluid.half_size.w);
						previous = t;
						t = t * growth + 1.0;

						if (depth.x + depth.y > 64.0) break;
					}

					return depth;
				}

				float march_to(vec3 g, vec3 target) {
					vec3 to = target - g;
					float distance = min(length(to), 160.0);
					int steps = max(int(ceil(distance)), 1);
					float step_length = distance / float(steps);
					vec3 dir = to / max(length(to), 1e-4);
					float depth = 0.0;

					for (int i = 0; i < steps; i++) {
						vec3 p = g + dir * ((float(i) + 0.5) * step_length);

						if (fluid_outside(p) > 0.0) break;

						depth += textureLod(scalars, fluid_grid_uvw(p), 0.0).x;
					}

					return depth * step_length * fluid.half_size.w;
				}

				void main() {
					ivec3 c = ivec3(gl_GlobalInvocationID);

					if (!fluid_in_grid(c)) return;

					ivec3 atlas_c = c + ivec3(0, 0, fluid.size.w);
					vec3 cell_world = (fluid.to_world * vec4(fluid_cell_local(vec3(c) + 0.5), 1.0)).xyz;
					vec4 slot_depth = vec4(0.0);
					vec4 slot_visibility = vec4(1.0);
					bool cell_solid = fluid_solid(c);

					for (int k = 0; k < 4; k++) {
						int i = fluid.light_slots[k];

						if (i < 0) continue;

						lights_t light = scene_light(light_data.lights, i);
						vec3 light_grid_pos = ((fluid.to_local * vec4(light.position.xyz, 1.0)).xyz + fluid.half_size.xyz) / fluid.half_size.w;
						slot_depth[k] = march_to(vec3(c) + 0.5, light_grid_pos);

						if (!cell_solid) slot_visibility[k] = get_medium_light_visibility(i, light, cell_world, normalize(light.position.xyz - cell_world));
					}

					imageStore(out_slot_depth, atlas_c, slot_depth);
					imageStore(out_slot_visibility, atlas_c, slot_visibility);

					vec3 g = vec3(c) + 0.5;
					vec3 sun_world = get_current_primary_sun_direction();
					vec3 sun = normalize(mat3(fluid.to_local) * sun_world);
					vec2 sun_depth = march(g, sun, 0.5, 1.0, 160);

					if (fluid_solid(c)) {
						imageStore(out_fields, atlas_c, vec4(0.0, fluid.thermal.x, 0.0, 0.0));
						imageStore(out_light, atlas_c, vec4(sun_depth.x, 0.0, 1.0, sun_depth.y));
						atomicAdd(stats[6], 1u);
						return;
					}

					vec4 s = texelFetch(scalars, c, 0);

					if (s.x > 1e-3) {
						atomicMax(stats[0], floatBitsToUint(s.x));
						atomicAdd(stats[4], uint(s.x * 256.0));
						atomicAdd(stats[5], uint(s.x * 16.0 * float(c.y)));
					}

					atomicMax(stats[1], floatBitsToUint(s.y));
					atomicMax(stats[2], floatBitsToUint(s.z));
					atomicMax(stats[3], floatBitsToUint(s.w));
					float intensity = (s.x * fluid.optics.x + s.w * fluid.optics.y) * blackbody_luminance(s.y) * fluid.half_size.w * fluid.half_size.w * fluid.half_size.w;

					if (intensity > 1e-3) {
						atomicAdd(stats[7], uint(intensity * 16.0));
						atomicAdd(stats[8], uint(intensity * g.x));
						atomicAdd(stats[9], uint(intensity * g.y));
						atomicAdd(stats[10], uint(intensity * g.z));
						atomicAdd(stats[11], uint(intensity * s.y / 64.0));
					}
					vec3 up = -normalize(fluid.gravity.xyz);
					vec3 side = normalize(abs(up.y) < 0.9 ? cross(up, vec3(0.0, 1.0, 0.0)) : cross(up, vec3(1.0, 0.0, 0.0)));
					vec3 other = cross(up, side);
					float ambient_depth = march(g, up, 0.5, 1.5, 10).x * 0.4;
					ambient_depth += march(g, normalize(up + side), 0.5, 1.5, 10).x * 0.15;
					ambient_depth += march(g, normalize(up - side), 0.5, 1.5, 10).x * 0.15;
					ambient_depth += march(g, normalize(up + other), 0.5, 1.5, 10).x * 0.15;
					ambient_depth += march(g, normalize(up - other), 0.5, 1.5, 10).x * 0.15;
					vec3 world = (fluid.to_world * vec4(fluid_cell_local(g), 1.0)).xyz;
					float visibility = get_fluid_sun_visibility(world, sun_world);
					imageStore(out_fields, atlas_c, s);
					imageStore(out_light, atlas_c, vec4(sun_depth.x, ambient_depth, visibility, sun_depth.y));
				}
			]],
		}
	)
	return pipelines
end

local function next_slot(pipeline)
	if pipeline.fluid_serial ~= render.frame_serial then
		pipeline.fluid_serial = render.frame_serial
		pipeline.fluid_slot = 0
	end

	pipeline.fluid_slot = pipeline.fluid_slot + 1
	assert(pipeline.fluid_slot <= SLOTS_PER_FRAME, "too many fluid dispatches in one frame")
	return (
			(
				(
					render.GetCurrentFrame() or
					1
				) - 1
			) % FRAME_SPAN
		) * SLOTS_PER_FRAME + pipeline.fluid_slot
end

local function dispatch(cmd, pipeline, storage, sampled, buffers)
	local slot = next_slot(pipeline)

	if buffers then
		for binding, buffer in pairs(buffers) do
			pipeline:UpdateDescriptorSet("storage_buffer", slot, binding, 0, buffer, buffer:GetSize())
		end
	end

	for binding, texture in pairs(storage) do
		pipeline:BindStorageImage(cmd, slot, binding, texture)
	end

	if sampled then
		for binding, texture in pairs(sampled) do
			if texture.GetView then
				pipeline:UpdateDescriptorSet("combined_image_sampler", slot, binding, 0, texture)
			else
				pipeline:UpdateDescriptorSet("combined_image_sampler", slot, binding, 0, texture[1], texture[2])
			end
		end
	end

	if pipeline == pipelines.obstacles and RAY_QUERY then
		pipeline:UpdateDescriptorSet("acceleration_structure_khr", slot, 1, 0, rt.GetTLAS(cmd))
		cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "compute", memoryBarrier = true}
	end

	pipeline:UploadConstants()
	pipeline.pipeline:Dispatch(
		cmd,
		math.ceil(params.nx / LOCAL_SIZE),
		math.ceil(params.ny / LOCAL_SIZE),
		math.ceil(params.nz / LOCAL_SIZE),
		slot,
		pipeline.dynamic_offsets
	)
	return slot
end

local function barrier(cmd)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
end

local function create_grid_texture(nx, ny, nz, format, name, filter)
	local texture = Texture.New{
		width = nx,
		height = ny,
		format = format,
		sampled_layout = "general",
		image = {
			image_type = "3d",
			depth = nz,
			usage = {"storage", "sampled"},
		},
		view = {view_type = "3d"},
		sampler = {
			min_filter = filter,
			mag_filter = filter,
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
			wrap_r = "clamp_to_edge",
		},
	}
	texture:SetDebugName("fluid " .. name)
	return texture
end

local free_states = {}

local function destroy_state(state)
	for _, texture in ipairs(state.textures) do
		texture:Remove()
	end

	for _, buffer in pairs(state.stats) do
		buffer:Remove()
	end

	if state.fire_light then state.fire_light:Remove() end
end

function fluid_volumes.RemoveVolume(volume)
	for i, other in ipairs(fluid_volumes.volumes) do
		if other == volume then
			list.remove(fluid_volumes.volumes, i)

			break
		end
	end

	local state = states[volume]

	if not state then return end

	states[volume] = nil

	if state.fire_light then
		state.fire_light:Remove()
		state.fire_light = nil
	end

	list.insert(free_states, state)

	if #free_states > fluid_volumes.MAX_FREE_STATES then
		destroy_state(list.remove(free_states, 1))
	end
end

local function create_state(nx, ny, nz, cell, cmd)
	local state = {
		nx = nx,
		ny = ny,
		nz = nz,
		cell = cell,
		textures = {},
		stats = {},
		light_slots = {-1, -1, -1, -1},
	}

	local function grid(format, name, filter)
		local texture = create_grid_texture(nx, ny, nz, format, name, filter or "linear")
		render.TransitionResourceToComputeStorage(texture, {cmd = cmd})
		list.insert(state.textures, texture)
		return texture
	end

	state.velocity = {
		grid("r16g16b16a16_sfloat", "velocity a"),
		grid("r16g16b16a16_sfloat", "velocity b"),
	}
	state.scalars = {
		grid("r16g16b16a16_sfloat", "scalars a"),
		grid("r16g16b16a16_sfloat", "scalars b"),
	}
	state.predicted = grid("r16g16b16a16_sfloat", "predicted")
	state.curl = grid("r16g16b16a16_sfloat", "curl")
	state.pressure = grid("r32_sfloat", "pressure", "nearest")
	state.divergence = grid("r32_sfloat", "divergence", "nearest")
	state.static_obstacles = grid("r8_unorm", "static obstacles", "nearest")
	state.obstacles = grid("r8_unorm", "obstacles", "nearest")
	state.motion = grid("r16g16b16a16_sfloat", "motion", "nearest")
	return state
end

local function reset_state(state, cell)
	state.cell = cell
	state.current = 1
	state.needs_fill = true
	state.obstacle_time = -math.huge
	state.origin = nil
	state.last_stats = nil

	for k = 1, 4 do
		state.light_slots[k] = -1
	end

	return state
end

local function take_free_state(nx, ny, nz)
	for i, state in ipairs(free_states) do
		if state.nx == nx and state.ny == ny and state.nz == nz then
			return list.remove(free_states, i)
		end
	end
end

local function ensure_state(volume, cmd)
	local nx, ny, nz, cell = fluid_volumes.GetGridSize(volume)
	local state = states[volume]

	if state and state.nx == nx and state.ny == ny and state.nz == nz then
		state.cell = cell
		return state
	end

	if state then destroy_state(state) end

	state = reset_state(take_free_state(nx, ny, nz) or create_state(nx, ny, nz, cell, cmd), cell)
	states[volume] = state
	fluid_volumes.generation = fluid_volumes.generation + 1
	return state
end

local function create_atlas_texture(name, format)
	local texture = Texture.New{
		width = atlas.width,
		height = atlas.height,
		format = format or "r16g16b16a16_sfloat",
		image = {
			image_type = "3d",
			depth = atlas.depth,
			usage = {"storage", "sampled"},
		},
		view = {view_type = "3d"},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
			wrap_r = "clamp_to_edge",
		},
	}
	texture:SetDebugName("fluid atlas " .. name)
	return texture
end

local function ensure_atlas(width, height, depth)
	if
		atlas.fields and
		atlas.width >= width and
		atlas.height >= height and
		atlas.depth >= depth
	then
		return
	end

	if atlas.fields then
		atlas.fields:Remove()
		atlas.light:Remove()
		atlas.slot_depth:Remove()
		atlas.slot_visibility:Remove()
	end

	atlas.width = math.max(width, atlas.width, 1)
	atlas.height = math.max(height, atlas.height, 1)
	atlas.depth = math.max(depth, atlas.depth, 1)
	atlas.fields = create_atlas_texture("fields")
	atlas.light = create_atlas_texture("light")
	atlas.slot_depth = create_atlas_texture("light slot depth")
	atlas.slot_visibility = create_atlas_texture("light slot visibility", "r8g8b8a8_unorm")
	atlas.generation = (atlas.generation or 0) + 1
end

function fluid_volumes.GetAtlas()
	ensure_atlas(1, 1, 1)
	return atlas
end

local function rotate_vector(m, v)
	return Vec3(
		v.x * m.m00 + v.y * m.m10 + v.z * m.m20,
		v.x * m.m01 + v.y * m.m11 + v.z * m.m21,
		v.x * m.m02 + v.y * m.m12 + v.z * m.m22
	)
end

local emitter_targets = setmetatable({}, {__mode = "k"})

local function finest_volume(position)
	local best
	local best_cell = math.huge

	for _, volume in ipairs(fluid_volumes.active) do
		local state = states[volume]
		local x, y, z = state.to_local:TransformVectorUnpacked(position.x, position.y, position.z)

		if
			state.cell < best_cell and
			math.abs(x) <= state.nx * state.cell / 2 and
			math.abs(y) <= state.ny * state.cell / 2 and
			math.abs(z) <= state.nz * state.cell / 2
		then
			best = volume
			best_cell = state.cell
		end
	end

	return best
end

local function assign_sources()
	for _, emitter in ipairs(fluid_volumes.emitters) do
		emitter_targets[emitter] = finest_volume(Vec3(emitter.Owner.transform:GetWorldMatrix():GetTranslation()))
	end

	for _, splat in ipairs(splats) do
		splat.target = finest_volume(splat.position)
	end
end

local function collect_emitters(volume, to_local, half, dt, with_splats)
	local emitters = params.emitters
	local count = 0

	local function add(position, radius, smoke, temperature, fuel, velocity, blend, expand)
		if count >= fluid_volumes.MAX_EMITTERS then return end

		local x, y, z = to_local:TransformVectorUnpacked(position.x, position.y, position.z)

		if
			math.abs(x) > half.x + radius or
			math.abs(y) > half.y + radius or
			math.abs(z) > half.z + radius
		then
			return
		end

		count = count + 1
		local e = emitters[count]

		if not e then
			e = {}
			emitters[count] = e
		end

		local v = rotate_vector(to_local, velocity)
		e.x, e.y, e.z, e.radius = x, y, z, radius
		e.smoke, e.temperature, e.fuel, e.blend = smoke, temperature, fuel, blend
		e.vx, e.vy, e.vz = v.x, v.y, v.z
		e.expand = expand
	end

	local blend = 1 - math.exp(-fluid_volumes.EMITTER_RESPONSE * dt)

	for _, emitter in ipairs(fluid_volumes.emitters) do
		if emitter:IsEmitting() and emitter_targets[emitter] == volume then
			local world = emitter.Owner.transform:GetWorldMatrix()
			add(
				Vec3(world:GetTranslation()),
				emitter:GetRadius(),
				emitter:GetSmoke(),
				emitter:GetTemperature(),
				emitter:GetFuel(),
				rotate_vector(world, emitter:GetVelocity()),
				blend,
				0
			)
		end
	end

	if with_splats and dt > 0 then
		for _, splat in ipairs(splats) do
			if splat.target == volume then
				add(
					splat.position,
					splat.radius,
					splat.smoke / dt,
					splat.temperature,
					splat.fuel / dt,
					splat.velocity,
					1,
					splat.expand
				)
			end
		end
	end

	params.emitter_count = count
end

local body_motion = setmetatable({}, {__mode = "k"})
local moving_bodies = {}
local AXIS_X = Vec3(1, 0, 0)
local AXIS_Y = Vec3(0, 1, 0)
local AXIS_Z = Vec3(0, 0, 1)
local ZERO = Vec3(0, 0, 0)
fluid_volumes.TELEPORT_SPEED = 50

local function update_body_motion(now)
	list.clear(moving_bodies)
	local alpha = physics.GetInterpolationAlpha()

	for _, body in ipairs(RigidBody.Instances) do
		if body.MotionType ~= "static" then
			local half = body:GetHalfExtents()
			local bounds = body.LocalBounds
			local rotation = body:GetInterpolatedRotation(alpha)
			local center = body:GetInterpolatedPosition(alpha)

			if bounds then
				center = center + rotation:VecMul((bounds.min + bounds.max) * 0.5)
			end

			local motion = body_motion[body]

			if not motion then
				motion = {time = now, center = center, velocity = Vec3(0, 0, 0)}
				body_motion[body] = motion
			end

			if now > motion.time then
				local velocity = (center - motion.center) / (now - motion.time)
				motion.velocity = velocity:GetLength() < fluid_volumes.TELEPORT_SPEED and velocity or Vec3(0, 0, 0)
				motion.time = now
			end

			local shape = body:GetShapeType()
			motion.center = center
			motion.rotation = rotation
			motion.half = half
			motion.radius = (
					shape == "sphere" or
					shape == "capsule"
				)
				and
				math.max(half.x, half.z) or
				fluid_volumes.PUSHER_BOX_ROUNDING
			motion.spin = body:GetAngularVelocity() or ZERO
			list.insert(moving_bodies, motion)
		end
	end
end

local function collect_pushers(volume, state, to_local, dt)
	local count = 0

	if volume:GetPushers() and volume:GetSimulation() == "fluid" then
		local half = Vec3(state.nx, state.ny, state.nz) * (state.cell / 2)

		for _, motion in ipairs(moving_bodies) do
			if count >= fluid_volumes.MAX_PUSHERS then break end

			local c = motion.center
			local x, y, z = to_local:TransformVectorUnpacked(c.x, c.y, c.z)
			local reach = motion.half:GetLength() + fluid_volumes.PUSHER_REACH * state.cell

			if
				math.abs(x) <= half.x + reach and
				math.abs(y) <= half.y + reach and
				math.abs(z) <= half.z + reach
			then
				count = count + 1
				local entry = pushers[count]

				if not entry then
					entry = {}
					pushers[count] = entry
				end

				entry.center = Vec3(x, y, z)
				entry.radius = motion.radius
				entry.axis_x = rotate_vector(to_local, motion.rotation:VecMul(AXIS_X)):GetNormalized()
				entry.axis_y = rotate_vector(to_local, motion.rotation:VecMul(AXIS_Y)):GetNormalized()
				entry.axis_z = rotate_vector(to_local, motion.rotation:VecMul(AXIS_Z)):GetNormalized()
				entry.half_size = motion.half
				entry.velocity = rotate_vector(to_local, motion.velocity)
				entry.spin = rotate_vector(to_local, motion.spin)
			end
		end
	end

	pushers.count = count
	pushers.drag = 1 - math.exp(-fluid_volumes.PUSHER_DRAG * dt)
end

local function choose_light_slots(volume, state)
	local slots = state.light_slots
	local scores = {}

	for k = 1, fluid_volumes.MAX_LIGHT_SLOTS do
		slots[k] = -1
		scores[k] = 0
	end

	local to_local = state.to_local
	local half = Vec3(state.nx, state.ny, state.nz) * (state.cell / 2)
	local lights = render3d.GetLights()

	for index = 1, #lights do
		local light = lights[index]

		if light.Type ~= "light_sun" and light.Type ~= "light_directional" then
			local range = light:GetEffectiveRange()
			local x, y, z = to_local:TransformVectorUnpacked(light.Owner.transform:GetWorldMatrix():GetTranslation())
			local dx = math.max(math.abs(x) - half.x, 0)
			local dy = math.max(math.abs(y) - half.y, 0)
			local dz = math.max(math.abs(z) - half.z, 0)
			local distance_squared = dx * dx + dy * dy + dz * dz

			if distance_squared < range * range then
				local score = light:GetPhotometricAmount() / math.max(distance_squared, state.cell * state.cell)
				local at = fluid_volumes.MAX_LIGHT_SLOTS + 1

				while at > 1 and score > scores[at - 1] do
					at = at - 1
				end

				if at <= fluid_volumes.MAX_LIGHT_SLOTS then
					for k = fluid_volumes.MAX_LIGHT_SLOTS, at + 1, -1 do
						slots[k] = slots[k - 1]
						scores[k] = scores[k - 1]
					end

					slots[at] = index - 1
					scores[at] = score
				end
			end
		end
	end
end

local function blackbody_color(kelvin)
	local t = kelvin / 100
	local r = t <= 66 and 1 or math.clamp(1.29293618606 * (t - 60) ^ -0.1332047592, 0, 1)
	local g = t <= 66 and
		math.clamp(0.39008157876 * math.log(t) - 0.63184144378, 0, 1) or
		math.clamp(1.12989086089 * (t - 60) ^ -0.0755148492, 0, 1)
	local b = t >= 66 and
		1 or
		(
			t <= 19 and
			0 or
			math.clamp(0.54320678911 * math.log(t - 10) - 1.19625408914, 0, 1)
		)
	return Color(r ^ 2.2, g ^ 2.2, b ^ 2.2, 1)
end

local function update_fire_light(volume, state)
	local stats = state.last_stats
	local lumen = stats and stats.emission_center and 4 * math.pi * stats.emitted_intensity or 0

	if not volume:GetEmitLight() or lumen < fluid_volumes.FIRE_LIGHT_MIN_LUMEN then
		if state.fire_light then state.fire_light.light_point:SetVisible(false) end

		return
	end

	if not state.fire_light then
		state.fire_light = import("goluwa/entities/entity.lua").New{
			Name = "fluid_fire_light",
			HideFromEditor = true,
			transform = {},
			light_point = {Lumen = 0},
		}
	end

	local light = state.fire_light.light_point
	local center = stats.emission_center
	local x, y, z = state.to_world:TransformVectorUnpacked(center.x, center.y, center.z)
	local response = fluid_volumes.FIRE_LIGHT_RESPONSE
	state.fire_light.transform:SetPosition(Vec3(x, y, z))
	light:SetVisible(true)
	light:SetColor(blackbody_color(stats.emission_temperature))
	light:SetLumen(math.lerp(response, light:GetLumen(), lumen))
	light:SetSourceRadius(state.cell * 2)
end

local function update_frame(volume, state)
	local transform = volume.Owner.transform

	if volume:GetSpace() ~= "world" then
		state.to_world = transform:GetWorldMatrix()
		state.to_local = transform:GetWorldMatrixInverse()
		state.origin = nil
		return
	end

	local x, y, z = transform:GetWorldMatrix():GetTranslation()
	local cell = state.cell
	local cx, cy, cz = math.floor(x / cell + 0.5), math.floor(y / cell + 0.5), math.floor(z / cell + 0.5)
	local origin = state.origin

	if origin then
		state.shift_x, state.shift_y, state.shift_z = cx - origin[1], cy - origin[2], cz - origin[3]
	else
		state.shift_x, state.shift_y, state.shift_z = 0, 0, 0
	end

	state.origin = {cx, cy, cz}
	state.to_world = Matrix44(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, cx * cell, cy * cell, cz * cell, 1)
	state.to_local = Matrix44(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -cx * cell, -cy * cell, -cz * cell, 1)
end

local function shift_state(cmd, state)
	local x, y, z = state.shift_x or 0, state.shift_y or 0, state.shift_z or 0

	if x == 0 and y == 0 and z == 0 then return end

	state.shift_x, state.shift_y, state.shift_z = 0, 0, 0
	state.fill_key = nil

	if math.abs(x) >= state.nx or math.abs(y) >= state.ny or math.abs(z) >= state.nz then
		state.needs_fill = true
		state.obstacle_time = -math.huge
		return
	end

	params.shift_x, params.shift_y, params.shift_z = x, y, z
	local next = 3 - state.current
	dispatch(
		cmd,
		pipelines.shift,
		{
			[0] = state.velocity[state.current],
			[1] = state.velocity[next],
			[2] = state.scalars[state.current],
			[3] = state.scalars[next],
			[4] = state.static_obstacles,
			[5] = state.obstacles,
			[6] = state.pressure,
		}
	)
	barrier(cmd)
	params.shift_x, params.shift_y, params.shift_z = 0, 0, 0
	state.current = next
	state.static_obstacles, state.obstacles = state.obstacles, state.static_obstacles
end

local function write_params(volume, state, dt, with_splats)
	local to_world = state.to_world
	local to_local = state.to_local
	params.to_world = params.to_world or ffi.new("float[16]")
	params.to_local = params.to_local or ffi.new("float[16]")
	params.emitters = params.emitters or {}
	to_world:CopyToFloatPointer(params.to_world)
	to_local:CopyToFloatPointer(params.to_local)
	params.nx, params.ny, params.nz, params.cell = state.nx, state.ny, state.nz, state.cell
	params.atlas_z = state.atlas_z
	params.half = Vec3(state.nx, state.ny, state.nz) * (state.cell / 2)
	params.gravity = rotate_vector(to_local, Vec3(0, -fluid_volumes.GRAVITY, 0))
	params.wind = rotate_vector(to_local, atmosphere.GetWind() or Vec3(0, 0, 0))
	params.fill = volume:GetFill()
	params.noise_scale = volume:GetNoiseScale()
	params.noise_amount = volume:GetNoiseAmount()
	params.height_falloff = volume:GetHeightFalloff()
	params.edge_softness = volume:GetEdgeSoftness()
	params.time = system.GetElapsedTime() % 100000
	params.buoyancy = volume:GetBuoyancy()
	params.weight = volume:GetWeight()
	params.vorticity = volume:GetVorticity()
	params.dt = dt
	params.dissipation = volume:GetDissipation()
	params.cooling = volume:GetCooling()
	params.flame_life = volume:GetFlameLife()
	params.soot_yield = volume:GetSootYield()
	params.ignition = volume:GetIgnitionTemperature()
	params.burn_rate = volume:GetBurnRate()
	params.heat_release = volume:GetHeatRelease()
	params.turbulence = volume:GetTurbulence()
	params.turbulence_scale = volume:GetTurbulenceScale()
	params.flame_temperature = volume:GetFlameTemperature()
	params.smoke_absorption = media.presets[volume:GetMedium()].Absorption:Dot(Vec3(0.2126, 0.7152, 0.0722)) * volume:GetDensity()
	params.flame_absorption = media.presets.flame.Absorption.x
	params.light_slots = state.light_slots
	params.floor = volume:GetFloor() and 1 or 0
	collect_emitters(volume, to_local, params.half, dt, with_splats)
end

local function step(cmd, state)
	local p = pipelines
	local current = state.current
	local next = 3 - current
	local obstacles = state.obstacles
	dispatch(
		cmd,
		p.advect_velocity,
		{[0] = state.velocity[next], [3] = obstacles, [4] = state.motion},
		{[1] = state.velocity[current], [2] = state.scalars[current]}
	)
	dispatch(
		cmd,
		p.predict,
		{[0] = state.predicted},
		{[1] = state.velocity[current], [2] = state.scalars[current]}
	)
	barrier(cmd)
	dispatch(
		cmd,
		p.correct,
		{[0] = state.scalars[next], [4] = obstacles},
		{
			[1] = state.velocity[current],
			[2] = state.scalars[current],
			[3] = state.predicted,
		}
	)
	dispatch(cmd, p.curl, {[0] = state.curl, [1] = state.velocity[next]})
	barrier(cmd)
	dispatch(cmd, p.confine, {[0] = state.velocity[next], [1] = state.curl})
	barrier(cmd)
	dispatch(
		cmd,
		p.divergence,
		{
			[0] = state.divergence,
			[1] = state.velocity[next],
			[2] = obstacles,
			[3] = state.motion,
		}
	)
	barrier(cmd)
	local slot = next_slot(p.pressure)
	p.pressure:BindStorageImage(cmd, slot, 0, state.pressure)
	p.pressure:BindStorageImage(cmd, slot, 1, state.divergence)
	p.pressure:BindStorageImage(cmd, slot, 2, obstacles)

	for i = 0, fluid_volumes.PRESSURE_ITERATIONS * 2 - 1 do
		params.parity = i % 2
		p.pressure:UploadConstants()
		p.pressure.pipeline:Dispatch(
			cmd,
			math.ceil(math.ceil(state.nx / 2) / LOCAL_SIZE),
			math.ceil(state.ny / LOCAL_SIZE),
			math.ceil(state.nz / LOCAL_SIZE),
			slot,
			p.pressure.dynamic_offsets
		)
		barrier(cmd)
	end

	dispatch(
		cmd,
		p.project,
		{
			[0] = state.velocity[next],
			[1] = state.pressure,
			[2] = obstacles,
			[3] = state.motion,
		}
	)
	barrier(cmd)
	state.current = next
end

local StatsPointer = ffi.typeof("uint32_t*")
local stats_float = ffi.new("union { uint32_t u; float f; }")

local function as_float(bits)
	stats_float.u = bits
	return stats_float.f
end

local function read_stats(state)
	local frame = ((render.GetCurrentFrame() or 1) - 1) % FRAME_SPAN + 1
	local buffer = state.stats[frame]

	if not buffer then
		buffer = render.CreateBuffer{
			byte_size = 64,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "fluid_stats",
			data = ffi.new("uint8_t[64]"),
		}
		state.stats[frame] = buffer
	else
		local values = ffi.cast(StatsPointer, buffer:Map(0, 64))
		local intensity = values[7] / 16
		local total = values[4] / 256
		state.last_stats = {
			max_smoke = as_float(values[0]),
			max_temperature = as_float(values[1]),
			max_fuel = as_float(values[2]),
			max_flame = as_float(values[3]),
			smoke_total = total * state.cell ^ 3,
			smoke_height = total > 0 and
				(
					(
						values[5] / 16
					) / total + 0.5
				) * state.cell - state.ny * state.cell / 2 or
				0,
			solid_cells = values[6],
			emitted_intensity = intensity,
			emission_center = intensity > 0 and
				Vec3(values[8], values[9], values[10]) / intensity * state.cell - Vec3(state.nx, state.ny, state.nz) * (
					state.cell / 2
				)
				or
				nil,
			emission_temperature = intensity > 0 and values[11] * 64 / intensity or 0,
		}
	end

	ffi.fill(buffer:Map(0, 64), 64)
	return buffer
end

function fluid_volumes.GetStats(volume)
	local state = states[volume]
	return state and state.last_stats
end

local record_type = ffi.typeof([[
	struct {
		float to_local[16];
		float half_size[3];
		float cell;
		float grid[3];
		float atlas_z;
		float absorption[3];
		float g;
		float scattering[3];
		float flame_absorption;
		float floor;
		int mode;
		int light_slots[4];
		float pad[2];
	}
]])
local header_type = ffi.typeof([[
	struct {
		int counts[4];
		float atlas_inv[4];
	}
]])
local RECORD_SIZE = ffi.sizeof(record_type)
local HEADER_SIZE = ffi.sizeof(header_type)
local RecordPointer = ffi.typeof("$*", record_type)
local HeaderPointer = ffi.typeof("$*", header_type)
local BytePointer = ffi.typeof("uint8_t*")
local record_buffers = {}
local active = {}
fluid_volumes.active = active

local function write_record(record, volume, state)
	local medium = media.presets[volume:GetMedium()]
	local density = volume:GetDensity()
	state.to_local:CopyToFloatPointer(record.to_local)
	record.half_size[0], record.half_size[1], record.half_size[2] = state.nx * state.cell / 2, state.ny * state.cell / 2, state.nz * state.cell / 2
	record.cell = state.cell
	record.grid[0], record.grid[1], record.grid[2] = state.nx, state.ny, state.nz
	record.atlas_z = state.atlas_z
	record.absorption[0], record.absorption[1], record.absorption[2] = medium.Absorption.x * density, medium.Absorption.y * density, medium.Absorption.z * density
	record.scattering[0], record.scattering[1], record.scattering[2] = medium.Scattering.x * density, medium.Scattering.y * density, medium.Scattering.z * density
	record.g = medium.PhaseG
	record.flame_absorption = media.presets.flame.Absorption.x
	record.floor = volume:GetFloor() and 1 or 0
	record.mode = volume:GetRaymarch() and
		fluid_volumes.MODES.raymarch or
		fluid_volumes.MODES.froxels

	for i = 0, 3 do
		record.light_slots[i] = state.light_slots[i + 1]
	end
end

local function write_records()
	local frame = ((render.GetCurrentFrame() or 1) - 1) % FRAME_SPAN + 1
	local buffer = record_buffers[frame]

	if not buffer then
		local size = HEADER_SIZE + RECORD_SIZE * fluid_volumes.MAX_VOLUMES
		buffer = render.CreateBuffer{
			byte_size = size,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "fluid_volumes",
			data = ffi.new("uint8_t[?]", size),
		}
		record_buffers[frame] = buffer
	end

	local base = ffi.cast(BytePointer, buffer:Map(0, buffer:GetSize()))
	local header = ffi.cast(HeaderPointer, base)
	local records = ffi.cast(RecordPointer, base + HEADER_SIZE)
	local raymarched = 0

	for i, volume in ipairs(active) do
		write_record(records[i - 1], volume, states[volume])

		if volume:GetRaymarch() then raymarched = raymarched + 1 end
	end

	header.counts[0] = #active
	header.counts[1] = raymarched
	header.counts[2] = #active - raymarched
	header.atlas_inv[0], header.atlas_inv[1], header.atlas_inv[2] = 1 / atlas.width, 1 / atlas.height, 1 / atlas.depth
	fluid_volumes.raymarched_count = raymarched
	fluid_volumes.froxel_count = #active - raymarched
	fluid_volumes.record_buffer = buffer
	return buffer
end

function fluid_volumes.GetRecordBuffer()
	read_device()
	return fluid_volumes.record_buffer or write_records()
end

function fluid_volumes.HasRaymarched()
	return (fluid_volumes.raymarched_count or 0) > 0
end

function fluid_volumes.GetStepTime()
	return math.clamp(system.GetElapsedTime() - render3d.GetPreviousElapsedTime(), 0, 0.1)
end

local prewarm_requests = {}

function fluid_volumes.Prewarm(size, resolution, count)
	list.insert(prewarm_requests, {size = size, resolution = resolution, count = count})
end

local function prewarm(cmd)
	for _, request in ipairs(prewarm_requests) do
		local nx, ny, nz, cell = fluid_volumes.GetGridSize{
			GetSize = function()
				return request.size
			end,
			GetResolution = function()
				return request.resolution
			end,
		}

		for _ = 1, request.count do
			if #free_states >= fluid_volumes.MAX_FREE_STATES then break end

			list.insert(free_states, create_state(nx, ny, nz, cell, cmd))
		end

		ensure_atlas(
			math.max(atlas.width, nx),
			math.max(atlas.height, ny),
			atlas.depth + nz * request.count
		)
	end

	list.clear(prewarm_requests)
end

local transients = {}

local function transient_contains(transient, position, margin)
	local entity = transient.entity
	local size = entity.fluid_volume:GetSize()
	local center = Vec3(entity.transform:GetWorldMatrix():GetTranslation())
	local d = position - center
	return math.abs(d.x) <= size.x / 2 - margin and
		math.abs(d.y) <= size.y / 2 - margin and
		math.abs(d.z) <= size.z / 2 - margin
end

function fluid_volumes.Spawn(config)
	local now = system.GetElapsedTime()
	local position = config.position
	local radius = config.radius or 0.5

	for _, transient in ipairs(transients) do
		if transient.entity:IsValid() and transient_contains(transient, position, radius) then
			transient.time = now
			fluid_volumes.Splat(position, radius, config)
			return transient.entity.fluid_volume
		end
	end

	if #transients >= fluid_volumes.MAX_TRANSIENTS then
		list.remove(transients, 1).entity:Remove()
	end

	local volume = table.copy(config.volume or {})
	volume.Space = volume.Space or "world"
	local entity = import("goluwa/entities/entity.lua").New{
		Name = "fluid_transient",
		HideFromEditor = true,
		transform = {Position = position + (config.offset or Vec3(0, 0, 0))},
		fluid_volume = volume,
	}
	list.insert(transients, {entity = entity, time = now})
	fluid_volumes.Splat(position, radius, config)
	return entity.fluid_volume
end

function fluid_volumes.GetTransients()
	for i = #transients, 1, -1 do
		if not transients[i].entity:IsValid() then list.remove(transients, i) end
	end

	return transients
end

event.AddListener("Update", "fluid_transients", function()
	local now = system.GetElapsedTime()

	for i = #transients, 1, -1 do
		local transient = transients[i]
		local age = now - transient.time
		local stats = transient.entity:IsValid() and
			fluid_volumes.GetStats(transient.entity.fluid_volume)
		local spent = stats and
			stats.smoke_total < fluid_volumes.TRANSIENT_SMOKE and
			stats.max_flame < 0.01 and
			stats.max_temperature < fluid_volumes.AMBIENT_TEMPERATURE + 30

		if
			not transient.entity:IsValid() or
			age > fluid_volumes.TRANSIENT_MAX_AGE or
			(
				age > fluid_volumes.TRANSIENT_MIN_AGE and
				spent
			)
		then
			if transient.entity:IsValid() then transient.entity:Remove() end

			list.remove(transients, i)
		end
	end
end)

function fluid_volumes.Simulate(cmd)
	read_device()
	list.clear(active)

	for _, volume in ipairs(fluid_volumes.volumes) do
		if #active >= fluid_volumes.MAX_VOLUMES then break end

		list.insert(active, volume)
	end

	if not active[1] then
		list.clear(splats)
		write_records()
		return
	end

	get_pipelines()
	prewarm(cmd)
	local width, height, depth = 1, 1, 0

	for _, volume in ipairs(active) do
		local state = ensure_state(volume, cmd)
		state.atlas_z = depth
		width = math.max(width, state.nx)
		height = math.max(height, state.ny)
		depth = depth + state.nz
	end

	ensure_atlas(width, height, depth)

	for _, volume in ipairs(active) do
		update_frame(volume, states[volume])
	end

	assign_sources()
	render.TransitionResourceToComputeStorage(atlas.fields, {cmd = cmd, srcStage = "compute"})
	render.TransitionResourceToComputeStorage(atlas.light, {cmd = cmd, srcStage = "compute"})
	render.TransitionResourceToComputeStorage(atlas.slot_depth, {cmd = cmd, srcStage = "compute"})
	render.TransitionResourceToComputeStorage(atlas.slot_visibility, {cmd = cmd, srcStage = "compute"})
	local frame_dt = fluid_volumes.GetStepTime()
	local steps = math.min(math.ceil(frame_dt / fluid_volumes.MAX_STEP), fluid_volumes.MAX_SUBSTEPS)
	local now = system.GetElapsedTime()
	update_body_motion(now)

	for _, volume in ipairs(active) do
		local state = states[volume]
		local simulated = volume:GetSimulation() == "fluid"
		write_params(volume, state, 0)
		shift_state(cmd, state)

		if
			now - state.obstacle_time >= fluid_volumes.OBSTACLE_INTERVAL or
			now < state.obstacle_time
		then
			params.obstacle_rays = volume:GetObstacles() and
				RAY_QUERY and
				instances.GetCount() > 0 and
				meshes.GetPendingCount() == 0

			if params.obstacle_rays or not volume:GetObstacles() or not RAY_QUERY then
				state.obstacle_time = now
			end

			dispatch(cmd, pipelines.obstacles, {[0] = state.static_obstacles})
			barrier(cmd)
		end

		collect_pushers(volume, state, state.to_local, steps > 0 and frame_dt / steps or 0)
		dispatch(
			cmd,
			pipelines.pushers,
			{[0] = state.obstacles, [1] = state.motion, [2] = state.static_obstacles}
		)
		barrier(cmd)
		local fill_key = not simulated and
			volume:GetNoiseAmount() == 0 and
			table.concat(
				{
					volume:GetFill(),
					volume:GetHeightFalloff(),
					volume:GetEdgeSoftness(),
					state.nx,
					state.ny,
					state.nz,
				},
				" "
			)

		if fill_key and fill_key ~= state.fill_key then state.needs_fill = true end

		state.fill_key = fill_key

		if state.needs_fill or (not simulated and not fill_key) then
			state.needs_fill = false
			dispatch(
				cmd,
				pipelines.fill,
				{
					[0] = state.velocity[1],
					[1] = state.velocity[2],
					[2] = state.scalars[1],
					[3] = state.scalars[2],
					[4] = state.pressure,
				}
			)
			barrier(cmd)
		end

		if simulated and steps > 0 then
			for i = 1, steps do
				write_params(volume, state, frame_dt / steps, i == 1)
				step(cmd, state)
			end
		end

		choose_light_slots(volume, state)
		write_params(volume, state, 0)
		dispatch(
			cmd,
			pipelines.light,
			{
				[0] = atlas.fields,
				[1] = atlas.light,
				[3] = state.obstacles,
				[5] = atlas.slot_depth,
				[6] = atlas.slot_visibility,
			},
			{
				[2] = state.scalars[state.current],
				[7] = light_occlusion.GetOcclusionDescriptor(),
			},
			{[4] = read_stats(state)}
		)
		update_fire_light(volume, state)
	end

	if steps > 0 then list.clear(splats) end

	for _, texture in ipairs{atlas.fields, atlas.light, atlas.slot_depth, atlas.slot_visibility} do
		render.TransitionResourceFrom(
			texture,
			"shader_read_only_optimal",
			{
				cmd = cmd,
				srcStage = "compute",
				srcAccess = "shader_write",
				dstStage = "compute",
				dstAccess = "shader_read",
			}
		)
	end

	write_records()
end

function fluid_volumes.GetDeclarationGLSL(
	record_binding,
	fields_binding,
	light_binding,
	slot_depth_binding,
	slot_visibility_binding
)
	return [[
		struct fluid_record {
			mat4 to_local;
			vec3 half_size;
			float cell;
			vec3 grid;
			float atlas_z;
			vec3 absorption;
			float g;
			vec3 scattering;
			float flame_absorption;
			float floor;
			int mode;
			ivec4 light_slots;
			vec2 pad;
		};

		layout(scalar, set = 0, binding = ]] .. record_binding .. [[) readonly buffer FluidRecords {
			ivec4 fluid_counts;
			vec4 fluid_atlas_inv;
			fluid_record fluid_records[]] .. fluid_volumes.MAX_VOLUMES .. [[];
		};

		layout(set = 0, binding = ]] .. fields_binding .. [[) uniform sampler3D fluid_fields_atlas;
		layout(set = 0, binding = ]] .. light_binding .. [[) uniform sampler3D fluid_light_atlas;
		layout(set = 0, binding = ]] .. slot_depth_binding .. [[) uniform sampler3D fluid_slot_depth_atlas;
		layout(set = 0, binding = ]] .. slot_visibility_binding .. [[) uniform sampler3D fluid_slot_visibility_atlas;
	]]
end

function fluid_volumes.GetGLSL()
	return glsl_common.GetBlackbodyGLSL() .. medium_common.GetGLSL() .. [[
		#define FLUID_MODE_RAYMARCH ]] .. fluid_volumes.MODES.raymarch .. [[

		#define FLUID_MODE_FROXELS ]] .. fluid_volumes.MODES.froxels .. [[

		vec3 fluid_atlas_uvw(fluid_record v, vec3 local) {
			vec3 c = clamp((local + v.half_size) / v.cell, vec3(0.5), v.grid - 0.5);
			return (c + vec3(0.0, 0.0, v.atlas_z)) * fluid_atlas_inv.xyz;
		}

		float fluid_edge(fluid_record v, vec3 local) {
			vec3 inside = (v.half_size - abs(local)) / (1.5 * v.cell);
			float bottom = v.floor > 0.5 ? 1.0 : inside.y;
			inside.y = local.y > 0.0 ? inside.y : bottom;
			return clamp(min(inside.x, min(inside.y, inside.z)), 0.0, 1.0);
		}

		vec3 fluid_emission(float kelvin) {
			return effect_blackbody(kelvin) * blackbody_luminance(kelvin);
		}

		vec3 fluid_sun_phase(fluid_record v, vec4 light, float mu) {
			vec3 depth = light.x * (v.absorption + v.scattering) + light.w * v.flame_absorption;
			return medium_multiple_scattering(depth, mu, v.g, 0.0, 0.0, 1.0 - dot(exp(-depth), vec3(1.0 / 3.0)));
		}

		vec3 fluid_ambient_transmittance(fluid_record v, vec4 light) {
			return exp(-light.y * (v.absorption + v.scattering));
		}

		vec3 fluid_sun_transmittance(vec3 world, vec3 sun_dir, int skip_index, int skip_mode) {
			vec3 transmittance = vec3(1.0);

			for (int i = 0; i < fluid_counts.x; i++) {
				fluid_record v = fluid_records[i];

				if (i == skip_index || v.mode == skip_mode) continue;

				float t0;
				float t1;

				if (!medium_box_intersect(v.to_local, -v.half_size, v.half_size, world, sun_dir, t0, t1)) continue;

				vec3 local = (v.to_local * vec4(world + sun_dir * max(t0, 0.0), 1.0)).xyz;
				vec4 l = textureLod(fluid_light_atlas, fluid_atlas_uvw(v, local), 0.0);
				transmittance *= exp(-(l.x * (v.absorption + v.scattering) + l.w * v.flame_absorption));
			}

			return transmittance;
		}

		vec3 fluid_light_slot_transmittance(fluid_record v, vec4 depths, vec4 visibility, int light_index) {
			for (int k = 0; k < 4; k++) {
				if (v.light_slots[k] == light_index) return exp(-depths[k] * (v.absorption + v.scattering)) * visibility[k];
			}

			return vec3(1.0);
		}

		vec3 fluid_local_light_transmittance(vec3 world, vec3 light_position, int light_index) {
			vec3 transmittance = vec3(1.0);
			vec3 to_light = light_position - world;
			float distance = length(to_light);
			vec3 dir = to_light / max(distance, 1e-4);

			for (int i = 0; i < fluid_counts.x; i++) {
				fluid_record v = fluid_records[i];
				int slot = v.light_slots.x == light_index ? 0 : (v.light_slots.y == light_index ? 1 : (v.light_slots.z == light_index ? 2 : (v.light_slots.w == light_index ? 3 : -1)));

				if (slot < 0) continue;

				float t0;
				float t1;

				if (!medium_box_intersect(v.to_local, -v.half_size, v.half_size, world, dir, t0, t1) || t0 > distance) continue;

				vec3 local = (v.to_local * vec4(world + dir * max(t0, 0.0), 1.0)).xyz;
				float depth = textureLod(fluid_slot_depth_atlas, fluid_atlas_uvw(v, local), 0.0)[slot];
				transmittance *= exp(-depth * (v.absorption + v.scattering));
			}

			return transmittance;
		}

		float fluid_segment_sample(fluid_record v, vec3 origin, vec3 dir, float t0, float t1, out vec4 fields, out vec4 light) {
			fields = vec4(0.0);
			light = vec4(0.0);
			float a;
			float b;

			if (!medium_box_intersect(v.to_local, -v.half_size, v.half_size, origin, dir, a, b)) return 0.0;

			a = max(a, t0);
			b = min(b, t1);

			if (b <= a) return 0.0;

			for (int s = 0; s < 2; s++) {
				vec3 local = (v.to_local * vec4(origin + dir * mix(a, b, 0.25 + 0.5 * float(s)), 1.0)).xyz;
				vec3 uvw = fluid_atlas_uvw(v, local);
				vec4 f = textureLod(fluid_fields_atlas, uvw, 0.0);
				float edge = fluid_edge(v, local);
				fields += 0.5 * vec4(f.x * edge, f.y, f.z, f.w * edge);
				light += 0.5 * textureLod(fluid_light_atlas, uvw, 0.0);
			}

			return (b - a) / max(t1 - t0, 1e-6);
		}

		vec3 fluid_froxel_segment_extinction(vec3 origin, vec3 dir, float t0, float t1) {
			vec3 extinction = vec3(0.0);

			for (int i = 0; i < fluid_counts.x; i++) {
				fluid_record v = fluid_records[i];

				if (v.mode != FLUID_MODE_FROXELS) continue;

				vec4 f;
				vec4 l;
				float coverage = fluid_segment_sample(v, origin, dir, t0, t1, f, l);
				extinction += coverage * (f.x * (v.absorption + v.scattering) + f.w * v.flame_absorption);
			}

			return extinction;
		}
	]]
end

return fluid_volumes
