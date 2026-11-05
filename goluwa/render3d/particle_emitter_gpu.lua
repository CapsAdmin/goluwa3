local ffi = require("ffi")
local list = import("goluwa/list.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local particles = import("goluwa/render3d/particles.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local shaders = import("goluwa/render3d/particle_shaders.lua")
local gpu = {}
gpu.MAX_EMITTERS = 128
gpu.POOL_SIZE = 65536
local ranges = {}
local free_slots = {}
local next_uid = 1
local high_water = 0
local last_sync_frame
local SHAPES = {point = 0, sphere = 1, cone = 2, box = 3, disc = 4}
local COLLISIONS = {none = 0, shelter_map = 1, scene_depth = 2, rays = 3}
local ON_HIT = {bounce = 0, stick = 1, kill = 2}
local ORIENTATIONS = {screen = 0, ground = 1}
local SAMPLES = particle_emitter.CURVE_SAMPLES
local CURVE_BUFFERS = 3
local curve_record = ffi.typeof(
	"struct { float size_low[$]; float size_high[$]; float emissive_low[$]; float emissive_high[$]; float color_low[$]; float color_high[$]; }",
	SAMPLES,
	SAMPLES,
	SAMPLES,
	SAMPLES,
	SAMPLES * 4,
	SAMPLES * 4
)
local curve_pointer = ffi.typeof("$ *", curve_record)
local curve_buffers = {}

local function get_curves()
	local index = system.GetFrameNumber() % CURVE_BUFFERS
	local curves = curve_buffers[index]

	if not curves then
		local buffer = render.CreateBuffer{
			byte_size = gpu.MAX_EMITTERS * ffi.sizeof(curve_record),
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "gpu emitter curves",
		}
		curves = {
			buffer = buffer,
			records = ffi.cast(curve_pointer, buffer:Map()),
			address = buffer:GetDeviceAddress(),
		}
		curve_buffers[index] = curves
	end

	return curves
end

local function release(range)
	list.remove_value(ranges, range)
	range.emitter.gpu_range = nil
end

local function by_first(a, b)
	return a.first < b.first
end

local function allocate(count)
	table.sort(ranges, by_first)
	local first = 0

	for _, range in ipairs(ranges) do
		if range.first - first >= count then return first end

		first = range.first + range.count
	end

	if first + count <= gpu.POOL_SIZE then return first end
end

local function sync()
	local frame = system.GetFrameNumber()

	if last_sync_frame == frame then return end

	last_sync_frame = frame

	for i = #ranges, 1, -1 do
		local range = ranges[i]
		local emitter = range.emitter

		if
			emitter.particle_removed or
			emitter.particle_backend ~= "gpu" or
			not particle_emitter.IsShown(emitter)
			or
			emitter.MaxParticles ~= range.count
		then
			release(range)
		end
	end

	for _, emitter in ipairs(particle_emitter.instances) do
		if
			not emitter.gpu_range and
			emitter.particle_backend == "gpu" and
			particle_emitter.IsShown(emitter)
		then
			if #ranges >= gpu.MAX_EMITTERS then break end

			local first = allocate(emitter.MaxParticles)

			if first then
				local slot = 0
				local taken = {}

				for _, range in ipairs(ranges) do
					taken[range.slot] = true
				end

				while taken[slot] do
					slot = slot + 1
				end

				local range = {
					emitter = emitter,
					first = first,
					count = emitter.MaxParticles,
					slot = slot,
					uid = next_uid,
					cursor = 0,
				}
				next_uid = next_uid + 1
				ranges[#ranges + 1] = range
				emitter.gpu_range = range
			end
		end
	end

	high_water = 0

	for _, range in ipairs(ranges) do
		high_water = math.max(high_water, range.first + range.count)
	end
end

function gpu.GetRanges()
	sync()
	return ranges
end

local function resolve_sprite(name)
	if type(name) ~= "string" then return name, 1, 1, nil, 1 end

	local vfx = import("goluwa/render3d/vfx.lua")

	if table.has_value(vfx.GetFlipbookNames(), name) then
		local flipbook = vfx.GetFlipbook(name)
		return flipbook.Texture, flipbook.Columns, flipbook.Rows, nil, flipbook.Frames
	end

	if table.has_value(vfx.GetTextureNames(), name) then
		return vfx.GetTexture(name), 1, 1, nil, 1
	end

	local sheet = import("goluwa/render3d/sprite_sheets.lua").Load(name)

	if sheet.Rects then
		return sheet.Texture, sheet.Frames, 1, sheet.Rects, sheet.SequenceFrames
	end

	return sheet.Texture, 1, 1, nil, 1
end

local function write_vec3(target, x, y, z)
	target[0], target[1], target[2] = x, y, z
end

gpu.base_declarations = glsl_common.GetNoiseGLSL() .. "#define GPU_EMITTER_COUNT " .. gpu.MAX_EMITTERS .. "u\n#define EMITTER_CURVE_SAMPLES " .. SAMPLES .. "\n" .. [[
		struct EmitterCurve {
			float size_low[EMITTER_CURVE_SAMPLES];
			float size_high[EMITTER_CURVE_SAMPLES];
			float emissive_low[EMITTER_CURVE_SAMPLES];
			float emissive_high[EMITTER_CURVE_SAMPLES];
			vec4 color_low[EMITTER_CURVE_SAMPLES];
			vec4 color_high[EMITTER_CURVE_SAMPLES];
		};

		layout(buffer_reference, scalar) readonly buffer EmitterCurves { EmitterCurve curves[]; };

		uint find_emitter(uint index) {
			for (int i = 0; i < emitters_data.emitter_count; i++) {
				if (emitters_data.emitters[i].enabled != 0 && index >= uint(emitters_data.emitters[i].first) && index < uint(emitters_data.emitters[i].first + emitters_data.emitters[i].count)) return uint(i);
			}

			return GPU_EMITTER_COUNT;
		}

		bool get_particle_emitter(Particle p, out uint slot) {
			slot = min(p.user.y, GPU_EMITTER_COUNT - 1u);
			return emitters_data.emitters[slot].enabled != 0 && uint(emitters_data.emitters[slot].uid) == p.user.z;
		}

		vec3 emitter_flow_potential(vec3 q) {
			return vec3(value_noise3(q), value_noise3(q + 31.4), value_noise3(q + 71.7));
		}

		vec3 emitter_flow(vec3 position, float scale, float seed) {
			vec3 q = position * scale + vec3(seed, 0.0, 0.0);
			float e = 0.15;
			vec3 dx = emitter_flow_potential(q + vec3(e, 0.0, 0.0)) - emitter_flow_potential(q - vec3(e, 0.0, 0.0));
			vec3 dy = emitter_flow_potential(q + vec3(0.0, e, 0.0)) - emitter_flow_potential(q - vec3(0.0, e, 0.0));
			vec3 dz = emitter_flow_potential(q + vec3(0.0, 0.0, e)) - emitter_flow_potential(q - vec3(0.0, 0.0, e));
			return vec3(dy.z - dz.y, dz.x - dx.z, dx.y - dy.x) / (2.0 * e);
		}

		vec3 emitter_random_a(emitters_t e, uint index, Particle p) {
			return pcg3d_unorm(uvec3(index, p.user.x, uint(e.seed) + 32452843u));
		}

		vec3 emitter_random_b(emitters_t e, uint index, Particle p) {
			return pcg3d_unorm(uvec3(index, p.user.x, uint(e.seed) + 49979687u));
		}

		float emitter_curve_size(uint slot, float t, float r) {
			EmitterCurves buf = EmitterCurves(emitters_data.curves);
			float x = clamp(t, 0.0, 1.0) * float(EMITTER_CURVE_SAMPLES - 1);
			uint i = min(uint(x), uint(EMITTER_CURVE_SAMPLES - 2));
			float f = x - float(i);
			float low = mix(buf.curves[slot].size_low[i], buf.curves[slot].size_low[i + 1u], f);
			float high = mix(buf.curves[slot].size_high[i], buf.curves[slot].size_high[i + 1u], f);
			return mix(low, high, r);
		}

		float emitter_curve_emissive(uint slot, float t, float r) {
			EmitterCurves buf = EmitterCurves(emitters_data.curves);
			float x = clamp(t, 0.0, 1.0) * float(EMITTER_CURVE_SAMPLES - 1);
			uint i = min(uint(x), uint(EMITTER_CURVE_SAMPLES - 2));
			float f = x - float(i);
			float low = mix(buf.curves[slot].emissive_low[i], buf.curves[slot].emissive_low[i + 1u], f);
			float high = mix(buf.curves[slot].emissive_high[i], buf.curves[slot].emissive_high[i + 1u], f);
			return mix(low, high, r);
		}

		vec4 emitter_curve_color(uint slot, float t, float r) {
			EmitterCurves buf = EmitterCurves(emitters_data.curves);
			float x = clamp(t, 0.0, 1.0) * float(EMITTER_CURVE_SAMPLES - 1);
			uint i = min(uint(x), uint(EMITTER_CURVE_SAMPLES - 2));
			float f = x - float(i);
			vec4 low = mix(buf.curves[slot].color_low[i], buf.curves[slot].color_low[i + 1u], f);
			vec4 high = mix(buf.curves[slot].color_high[i], buf.curves[slot].color_high[i + 1u], f);
			return mix(low, high, r);
		}

		float emitter_size_at(emitters_t e, uint index, Particle p, float f) {
			return emitter_curve_size(p.user.y, f, emitter_random_a(e, index, p).y);
		}

		vec4 emitter_color_at(emitters_t e, uint index, Particle p, float f) {
			return emitter_curve_color(p.user.y, f, emitter_random_a(e, index, p).z);
		}

		vec3 get_random_unit_vector(vec2 r) {
			float z = r.x * 2.0 - 1.0;
			float phi = 6.2831853 * r.y;
			return vec3(sqrt(1.0 - z * z) * vec2(cos(phi), sin(phi)), z);
		}
]]
gpu.system = particles.Register{
	name = "emitters",
	max_count = gpu.POOL_SIZE,
	scatter_g = 0.3,
	streak_time = 1 / 30,
	fade_time = 0.1,
	fade_near = 0.3,
	depth_near = 0.1,
	depth_far = 300,
	collision = "per_particle",
	IsActive = function()
		sync()
		return #ranges > 0
	end,
	GetCount = function()
		sync()
		return high_water, 1
	end,
	UsesRays = function()
		for _, range in ipairs(ranges) do
			if range.emitter.Collision == "rays" then return true end
		end

		return false
	end,
	block = {
		{
			"emitters",
			{
				{"position", "vec3"},
				{"axis", "vec3"},
				{"velocity", "vec3"},
				{"previous", "vec3"},
				{"shape_size", "vec3"},
				{"speed_min", "float"},
				{"speed_max", "float"},
				{"life_min", "float"},
				{"life_max", "float"},
				{"spread", "float"},
				{"gravity_min", "float"},
				{"gravity_max", "float"},
				{"drag_min", "float"},
				{"drag_max", "float"},
				{"restitution", "float"},
				{"friction", "float"},
				{"exposure_compensation", "float"},
				{"fizzle", "float"},
				{"fizzle_start", "float"},
				{"flow", "float"},
				{"flow_scale", "float"},
				{"sparkle", "float"},
				{"saturation_jitter", "float"},
				{"params", "vec4", shaders.PARAM_FLOATS / 4},
				{"shader", "int"},
				{"sprite_slot", "int"},
				{"flipbook_frames", "int"},
				{"flipbook_fps", "float"},
				{"flipbook_random", "int"},
				{"flipbook_sequence_frames", "int"},
				{"sequence_min", "float"},
				{"sequence_max", "float"},
				{"spin_min", "float"},
				{"spin_max", "float"},
				{"stretch", "float"},
				{"swirl", "float"},
				{"min_speed", "float"},
				{"flip_random", "float"},
				{"orientation", "int"},
				{"alpha_from_color", "int"},
				{"flatten", "float"},
				{"path", "int"},
				{"shape", "int"},
				{"collision", "int"},
				{"on_hit", "int"},
				{"lit", "int"},
				{"enabled", "int"},
				{"first", "int"},
				{"count", "int"},
				{"cursor", "int"},
				{"spawn_count", "int"},
				{"uid", "int"},
				{"seed", "int"},
				{"slot", "int"},
			},
			gpu.MAX_EMITTERS,
		},
		{"emitter_count", "int"},
		{"curves", "uint64_t"},
	},
	WriteBlock = function(self, block)
		sync()
		local dt = particles.GetStepTime()
		local slots = 0
		local curves = get_curves()
		block.curves = curves.address

		for i = 0, gpu.MAX_EMITTERS - 1 do
			block.emitters[i].enabled = 0
		end

		for _, range in ipairs(ranges) do
			local emitter = range.emitter
			local state = particle_emitter.Sample(emitter, dt)
			local entry = block.emitters[range.slot]
			slots = math.max(slots, range.slot + 1)
			write_vec3(entry.position, state.position.x, state.position.y, state.position.z)
			local following = emitter.RatePerMeter > 0 and state.moved > 1e-6

			if following then
				write_vec3(
					entry.axis,
					(state.previous.x - state.position.x) / state.moved,
					(state.previous.y - state.position.y) / state.moved,
					(state.previous.z - state.position.z) / state.moved
				)
			else
				write_vec3(entry.axis, state.axis.x, state.axis.y, state.axis.z)
			end

			write_vec3(entry.previous, state.previous.x, state.previous.y, state.previous.z)
			local inherit = emitter.InheritVelocity
			write_vec3(
				entry.velocity,
				state.velocity.x * inherit,
				state.velocity.y * inherit,
				state.velocity.z * inherit
			)
			local size = emitter.ShapeSize
			write_vec3(entry.shape_size, size.x, size.y, size.z)
			local record = curves.records[range.slot]
			particle_emitter.BakeScalar(emitter.Size, record.size_low, record.size_high)
			particle_emitter.BakeColor(emitter.Color, record.color_low, record.color_high)
			entry.slot = range.slot
			entry.speed_min, entry.speed_max = particle_emitter.GetRange(emitter.Speed)
			entry.life_min, entry.life_max = particle_emitter.GetRange(emitter.Lifetime)
			entry.spread = math.rad(emitter.Spread)
			entry.gravity_min, entry.gravity_max = particle_emitter.GetRange(emitter.GravityScale)
			entry.drag_min, entry.drag_max = particle_emitter.GetRange(emitter.Drag)
			entry.restitution = emitter.Restitution
			entry.friction = emitter.Friction
			particle_emitter.BakeScalar(emitter.Emissive, record.emissive_low, record.emissive_high)
			entry.exposure_compensation = emitter.ExposureCompensation
			entry.fizzle = emitter.Fizzle
			entry.fizzle_start = emitter.FizzleStart
			entry.flow = emitter.Flow
			entry.flow_scale = emitter.FlowScale
			entry.sparkle = emitter.Sparkle
			entry.saturation_jitter = emitter.SaturationJitter
			entry.shape = SHAPES[emitter.Shape]
			entry.collision = COLLISIONS[emitter.Collision]
			entry.on_hit = ON_HIT[emitter.OnHit]
			entry.lit = emitter.Lit and 1 or 0
			entry.enabled = 1
			entry.first = range.first
			entry.count = range.count
			entry.cursor = range.cursor
			local spawn_count = particle_emitter.Step(emitter, dt)
			entry.path = 0

			if following and emitter.Playing then
				state.path_carry = state.path_carry + emitter.RatePerMeter * state.moved
				local whole = math.floor(state.path_carry)
				state.path_carry = state.path_carry - whole

				if whole > 0 then
					entry.path = 1
					spawn_count = math.min(spawn_count + whole, emitter.MaxParticles)
				end
			end

			entry.spawn_count = spawn_count
			entry.uid = range.uid
			entry.seed = emitter.Seed
			local shader = emitter.Shader
			entry.shader = shaders.GetId(shader)
			entry.sprite_slot = 0
			entry.flipbook_frames = 1
			entry.flipbook_fps = emitter.FlipbookFps
			entry.flipbook_sequence_frames = 1
			entry.sequence_min, entry.sequence_max = particle_emitter.GetRange(emitter.Sequence)
			entry.flipbook_random = emitter.FlipbookRandomStart and 1 or 0
			local spin_min, spin_max = particle_emitter.GetRange(emitter.Spin)
			entry.spin_min, entry.spin_max = math.rad(spin_min), math.rad(spin_max)
			entry.stretch = emitter.Stretch
			entry.swirl = emitter.Swirl
			entry.min_speed = emitter.MinSpeed
			entry.flip_random = emitter.FlipRandom
			entry.orientation = ORIENTATIONS[emitter.Orientation]
			entry.alpha_from_color = emitter.AlphaFromColor and 1 or 0
			entry.flatten = emitter.Flatten

			if entry.shader ~= 0 then
				shaders.WriteParams(shader, emitter.ShaderParams, entry.params)
				local sprite_param = shaders.GetSpriteParam(shader)

				if sprite_param then
					local name = emitter.ShaderParams and emitter.ShaderParams[sprite_param]

					if name == nil then
						for _, param in ipairs(shaders.Get(shader).definition.Params) do
							if param.Name == sprite_param then name = param.Default end
						end
					end

					if range.sprite_name ~= name then
						range.sprite_name = name
						range.sprite_texture, range.sprite_columns, range.sprite_rows, range.sprite_rects, range.sprite_sequence_frames = resolve_sprite(name)
					end

					if range.sprite_texture then
						entry.sprite_slot = particles.GetSpriteSlot(
							range.sprite_texture,
							range.sprite_columns,
							range.sprite_rows,
							range.sprite_rects
						)
						entry.flipbook_frames = range.sprite_columns * range.sprite_rows
						entry.flipbook_sequence_frames = range.sprite_sequence_frames
					end
				end
			end

			range.cursor = (range.cursor + entry.spawn_count) % range.count
		end

		block.emitter_count = slots
		return block
	end,
	GetDeclarations = function()
		return gpu.base_declarations .. shaders.GetGLSL()
	end,
	should_spawn = [[
		uint slot = find_emitter(index);

		if (slot == GPU_EMITTER_COUNT) return false;

		emitters_t e = emitters_data.emitters[slot];
		uint local_index = index - uint(e.first);
		return (local_index + uint(e.count) - uint(e.cursor)) % uint(e.count) < uint(e.spawn_count);
	]],
	spawn = [[
		uint slot = find_emitter(index);

		if (slot == GPU_EMITTER_COUNT) {
			p.life = 0.0;
			return;
		}

		emitters_t e = emitters_data.emitters[slot];
		vec3 r = pcg3d_unorm(uvec3(index, generation, uint(e.seed)));
		vec3 r2 = pcg3d_unorm(uvec3(index, generation, uint(e.seed) + 7919u));
		vec3 r3 = pcg3d_unorm(uvec3(index, generation, uint(e.seed) + 104729u));
		vec3 axis = e.axis;
		vec3 across = normalize(cross(axis, abs(axis.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 along = cross(axis, across);
		float radius = e.shape_size.x * 0.5;
		float base_angle = 6.2831853 * r.x;
		vec3 offset = vec3(0.0);
		vec3 radial = vec3(0.0);

		if (e.shape == 1) {
			radial = get_random_unit_vector(r.xy);
			offset = radial * radius * pow(r3.x, 1.0 / 3.0);
		} else if (e.shape == 2 || e.shape == 4) {
			offset = (across * cos(base_angle) + along * sin(base_angle)) * radius * sqrt(r3.x);
		} else if (e.shape == 3) {
			offset = across * (r.x - 0.5) * e.shape_size.x + axis * (r.y - 0.5) * e.shape_size.y + along * (r.z - 0.5) * e.shape_size.z;
		}

		float cos_theta = mix(1.0, cos(e.spread), r2.x);
		float phi = 6.2831853 * r2.y;
		vec3 direction = axis * cos_theta + (across * cos(phi) + along * sin(phi)) * sqrt(1.0 - cos_theta * cos_theta);

		if (e.shape == 1) direction = radial;

		vec3 flat_direction = direction - axis * dot(direction, axis);

		if (length(flat_direction) > 1e-4) direction = normalize(mix(direction, flat_direction, e.flatten));

		float elapsed = 0.0;
		p.position = e.position + offset;

		if (e.path != 0) {
			uint local_index = index - uint(e.first);
			float fraction = (float((local_index + uint(e.count) - uint(e.cursor)) % uint(e.count)) + r2.z) / float(e.spawn_count);
			elapsed = (1.0 - fraction) * particle_data.dt;
			p.position = mix(e.previous, e.position, fraction) + offset;
		}

		p.velocity = direction * mix(e.speed_min, e.speed_max, r3.y) + e.velocity;
		p.position += p.velocity * elapsed;
		p.age = elapsed;
		p.life = mix(e.life_min, e.life_max, r3.z);
		p.width = emitter_size_at(e, index, p, 0.0);
		p.user.y = slot;
		p.user.z = uint(e.uid);
		p.sprite = e.stretch > 0.0 ? vec4(e.stretch, -float(e.sprite_slot), 0.0, 1.0) : vec4(r.x * 6.2831853, float(e.sprite_slot), 0.0, 1.0);

		if (e.flip_random > 0.0 && pcg3d_unorm(uvec3(index, generation, uint(e.seed) + 86028121u)).x < e.flip_random) p.spare |= 2u;

		if (e.orientation == 1) p.spare |= 4u;

		if (e.alpha_from_color != 0) p.spare |= 8u;
		emitter_shader_spawn(e, index, generation, p);
	]],
	update = [[
		uint slot;

		if (!get_particle_emitter(p, slot)) {
			p.life = 0.0;
			return;
		}

		emitters_t e = emitters_data.emitters[slot];
		float t = clamp(p.age / p.life, 0.0, 1.0);
		vec3 random_a = emitter_random_a(e, index, p);
		vec3 random_b = emitter_random_b(e, index, p);
		p.width = emitter_curve_size(slot, t, random_a.y) * p.sprite.w;

		if (p.sprite.y > 0.0 && (e.spin_min != 0.0 || e.spin_max != 0.0)) {
			p.sprite.x += mix(e.spin_min, e.spin_max, random_a.x) * dt;
		}

		if (e.flipbook_frames > 1) {
			float frames = float(e.flipbook_sequence_frames);
			vec3 sequence_random = pcg3d_unorm(uvec3(index, p.user.x, uint(e.seed) + 15485863u));
			float sequence_first = floor(mix(e.sequence_min, e.sequence_max + 0.999, sequence_random.y)) * frames;

			if (e.flipbook_fps > 0.0) {
				float start = e.flipbook_random != 0 ? floor(sequence_random.x * frames) : 0.0;
				p.sprite.z = sequence_first + mod(start + floor(p.age * e.flipbook_fps), frames);
			} else {
				p.sprite.z = sequence_first + min(floor(t * frames), frames - 1.0);
			}
		}

		if (e.min_speed > 0.0 && p.age > 0.1 && dot(p.velocity, p.velocity) < e.min_speed * e.min_speed) p.age += dt * 4.0;

		if ((p.spare & 1u) != 0u) {
			p.velocity = vec3(0.0);
			return;
		}

		p.velocity.y -= 9.81 * mix(e.gravity_min, e.gravity_max, random_b.y) * dt;

		if (e.swirl != 0.0) {
			vec3 around = p.position - e.position;
			around -= e.axis * dot(around, e.axis);
			float around_length = length(around);

			if (around_length > 1e-4) p.velocity += cross(e.axis, around / around_length) * e.swirl * dt;
		}

		if (e.flow > 0.0) p.velocity += emitter_flow(p.position, e.flow_scale, float(e.seed)) * e.flow * dt;

		if (e.fizzle > 0.0 && t > e.fizzle_start) {
			vec3 q = p.position * 60.0 + vec3(float(e.uid) * 3.1, p.age * 6.0, float(index) * 0.37);
			vec3 scatter = vec3(value_noise3(q), value_noise3(q + 17.3), value_noise3(q + 41.7)) - 0.5;
			p.velocity += normalize(scatter + 1e-4) * e.fizzle * smoothstep(e.fizzle_start, 1.0, t) * dt;
		}

		emitter_shader_update(e, index, dt, t, p);
		p.velocity *= exp(-mix(e.drag_min, e.drag_max, random_b.x) * dt);
		p.position += p.velocity * dt;
	]],
	visibility = [[
		uint slot;

		if (!get_particle_emitter(p, slot)) return 0.0;

		emitters_t e = emitters_data.emitters[slot];
		float seed = fract(sin(p.life * 12345.678) * 43758.5453);
		float twinkle = 0.5 + 0.5 * sin(p.age * mix(18.0, 60.0, seed) + seed * 6.2831853);
		float t = clamp(p.age / p.life, 0.0, 1.0);
		return emitter_curve_color(slot, t, emitter_random_a(e, index, p).z).a * mix(1.0, twinkle * twinkle, e.sparkle) * emitter_shader_visibility(e, index, t, p);
	]],
	shade = [[
		uint slot;

		if (!get_particle_emitter(p, slot)) return;

		emitters_t e = emitters_data.emitters[slot];
		vec3 tint = emitter_curve_color(slot, clamp(p.age / p.life, 0.0, 1.0), emitter_random_a(e, index, p).z).rgb;
		float luma = dot(tint, vec3(0.2126, 0.7152, 0.0722));
		float jitter = fract(sin(p.life * 4321.987 + 3.7) * 24634.6345);
		tint = max(mix(vec3(luma), tint, 1.0 + (jitter - 0.5) * 2.0 * e.saturation_jitter), vec3(0.0));
		float emissive = emitter_curve_emissive(slot, clamp(p.age / p.life, 0.0, 1.0), emitter_random_b(e, index, p).z);
		p.radiance = tint * ((e.lit != 0 ? p.light : vec3(0.0)) + emissive * effect_exposure_gain(particle_data.pre_exposure_tex, e.exposure_compensation));
		emitter_shader_shade(e, index, clamp(p.age / p.life, 0.0, 1.0), p);
	]],
	collision_mode = [[
		uint slot;

		if (!get_particle_emitter(p, slot)) return 0;

		return emitters_data.emitters[slot].collision;
	]],
	collide = [[
		uint slot;

		if (!get_particle_emitter(p, slot)) return;

		emitters_t e = emitters_data.emitters[slot];

		if (e.on_hit == 0) {
			particle_bounce(p, hit, normal, e.restitution, e.friction);
		} else if (e.on_hit == 1) {
			particle_stick(p, hit, normal);
			p.spare |= 1u;
		} else {
			p.life = 0.0;
		}
	]],
}
return gpu
