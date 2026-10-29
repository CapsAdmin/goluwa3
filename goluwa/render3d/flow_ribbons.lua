local ffi = require("ffi")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local particles = import("goluwa/render3d/particles.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local translucent_moments = import("goluwa/render3d/translucent_moments.lua")
local exposure_compensation = import("goluwa/render3d/exposure_compensation.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local flow_ribbons = {}
flow_ribbons.MAX_RIBBONS = 128
flow_ribbons.SEGMENTS = 96
flow_ribbons.SPRAY_POOL = 16384
flow_ribbons.after_aa = true
local FRAME_BUFFERS = 3
local get_time = system.GetElapsedTime
local Header = ffi.typeof([[struct {
	float origin[3];
	float age;
	float dir[3];
	float duration;
	float normal[3];
	float reach;
	float color[3];
	float width;
	float core[3];
	float curl;
	float loops;
	float phase;
	float plane;
	float spin;
	float travel;
	float tail;
	float emissive;
	float exposure_compensation;
	float meander;
	float spray_size;
	float spray_emissive;
	float spray_speed;
	float swirl;
	float flow;
	float drag;
	float life_min;
	float life_max;
	float inherit;
	float size_variation;
	float fizzle;
	float lift;
	float prev[3];
	float cur[3];
	float seed;
	int32_t live;
	int32_t uid;
	int32_t after_aa;
	int32_t kind;
}]])
local HEADER_BYTES = ffi.sizeof(Header) * flow_ribbons.MAX_RIBBONS
local headers = ffi.typeof("$[?]", Header)(flow_ribbons.MAX_RIBBONS)
local source_slots = ffi.new("int32_t[?]", flow_ribbons.MAX_RIBBONS)
local source_firsts = ffi.new("int32_t[?]", flow_ribbons.MAX_RIBBONS)
local source_counts = ffi.new("int32_t[?]", flow_ribbons.MAX_RIBBONS)
local states = {}
local free_slots = {}
local high_water = 0
local active_count = 0
local post_count = 0
local next_uid = 1
local source_count = 0
local spawn_total = 0
local spray_cursor = 0
local spray_cursor_start = 0
local last_frame
local buffers = {}
local current_buffer

for i = flow_ribbons.MAX_RIBBONS - 1, 0, -1 do
	free_slots[#free_slots + 1] = i
end

local function write_vec3(target, x, y, z)
	target[0], target[1], target[2] = x, y, z
end

local function write_color(target, color)
	target[0], target[1], target[2] = color.r, color.g, color.b
end

function flow_ribbons.Burst(config)
	local count = config.count or 26
	local normal = config.normal or Vec3(0, 1, 0)
	local position = config.position
	local color = config.color
	local core = config.core or color
	local reach = config.reach or 7
	local travel = config.travel or 0.7
	local tail = config.tail or 0.45
	local hold = config.hold or 0.7
	local spray_life = config.spray_life or 1.2
	local now = get_time()
	local across = normal:GetCross(math.abs(normal.y) < 0.99 and Vec3(0, 1, 0) or Vec3(1, 0, 0)):GetNormalized()
	local along = normal:GetCross(across)
	local seed = math.random() * 100

	for i = 1, count do
		local slot = table.remove(free_slots)
		assert(slot, "too many flow ribbons")
		local angle = (
				config.angle or
				0
			) + (
				i - 1 + math.randomf(-1, 1) * (
					config.jitter or
					0.35
				)
			) / count * math.pi * 2
		local dx = across.x * math.cos(angle) + along.x * math.sin(angle)
		local dy = across.y * math.cos(angle) + along.y * math.sin(angle)
		local dz = across.z * math.cos(angle) + along.z * math.sin(angle)
		local header = headers[slot]
		local ribbon_travel = travel * math.randomf(0.8, 1.25)
		write_vec3(header.origin, position.x, position.y, position.z)
		write_vec3(header.dir, dx, dy, dz)
		write_vec3(header.normal, normal.x, normal.y, normal.z)
		write_color(header.color, color)
		write_color(header.core, core)
		header.age = 0
		header.duration = ribbon_travel + tail + hold
		header.reach = reach * math.randomf(0.55, 1)
		header.width = (config.width or 0.05) * math.randomf(0.7, 1.3)
		header.curl = (config.curl or 0.11) * math.randomf(0.6, 1.4)
		header.loops = (config.loops or 2.5) * math.randomf(0.7, 1.3)
		header.phase = math.random() * math.pi * 2
		header.plane = math.random() * math.pi * 2
		header.spin = (config.spin or 3) * math.randomf(-1, 1)
		header.travel = ribbon_travel
		header.tail = tail * math.randomf(0.7, 1.3)
		header.emissive = config.emissive or 10
		header.exposure_compensation = config.exposure_compensation or 0
		header.meander = (config.meander or 0.12) * math.randomf(0.5, 1)
		header.spray_size = config.spray_size or 0.012
		header.spray_emissive = config.spray_emissive or 1.5e5
		header.spray_speed = config.spray_speed or 9
		header.swirl = config.swirl or 14
		header.flow = config.flow or 14
		header.drag = 2.2
		header.life_min = 0.5
		header.life_max = 1.2
		header.inherit = 0
		header.size_variation = config.size_variation or 0.4
		header.fizzle = config.fizzle or 0
		header.lift = config.lift or 0.04
		header.seed = seed + i * 0.37
		header.live = 1
		header.uid = next_uid
		header.after_aa = flow_ribbons.after_aa and 1 or 0
		header.kind = 0
		next_uid = next_uid + 1
		states[slot] = {
			start = now,
			lifespan = header.duration + spray_life,
			spray_rate = config.spray or 60,
			spray_travel = ribbon_travel + header.tail,
			accumulated = 0,
		}
		active_count = active_count + 1
		post_count = post_count + header.after_aa
		high_water = math.max(high_water, slot + 1)
	end
end

local EMITTER = {}
EMITTER.__index = EMITTER

function flow_ribbons.AcquireEmitter(config)
	local slot = table.remove(free_slots)
	assert(slot, "too many flow ribbons")
	local color = config.color
	local core = config.core or color
	local header = headers[slot]
	write_vec3(header.origin, 0, 0, 0)
	write_vec3(header.dir, 1, 0, 0)
	write_vec3(header.normal, 0, 1, 0)
	write_color(header.color, color)
	write_color(header.core, core)
	header.age = 0
	header.duration = 0
	header.travel = 1
	header.exposure_compensation = config.exposure_compensation or 0
	header.spray_size = config.spray_size or 0.004
	header.spray_emissive = config.spray_emissive or 4e5
	header.spray_speed = config.spray_speed or 0.6
	header.swirl = 0
	header.flow = config.flow or 0.3
	header.drag = config.drag or 12
	header.life_min = config.life_min or 0.75
	header.life_max = config.life_max or 1.5
	header.inherit = config.inherit or 0
	header.size_variation = config.size_variation or 0.5
	header.fizzle = config.fizzle or 1
	header.seed = math.random() * 100
	header.live = 1
	header.uid = next_uid
	header.after_aa = 0
	header.kind = 1
	next_uid = next_uid + 1
	states[slot] = {
		start = get_time(),
		lifespan = math.huge,
		spray_life = config.life_max or 1.5,
		density = config.density or 120,
		accumulated = 0,
		positioned = false,
		has_target = false,
		x = 0,
		y = 0,
		z = 0,
	}
	active_count = active_count + 1
	high_water = math.max(high_water, slot + 1)
	return setmetatable({slot = slot}, EMITTER)
end

function EMITTER:Move(x, y, z)
	local state = states[self.slot]
	state.x, state.y, state.z = x, y, z
	state.has_target = true
end

function EMITTER:Release()
	local state = states[self.slot]
	state.lifespan = get_time() - state.start + state.spray_life
	state.has_target = false
end

local function update_frame()
	local frame = system.GetFrameNumber()

	if last_frame == frame then return end

	last_frame = frame
	local index = frame % FRAME_BUFFERS
	local buffer = buffers[index]

	if not buffer then
		buffer = render.CreateBuffer{
			byte_size = HEADER_BYTES,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "flow ribbons",
		}
		buffers[index] = buffer
	end

	local now = get_time()
	local dt = particles.GetStepTime()
	source_count = 0
	spawn_total = 0
	spray_cursor_start = spray_cursor

	for slot = 0, high_water - 1 do
		local header = headers[slot]

		if header.live == 1 then
			local state = states[slot]
			local age = now - state.start

			if age >= state.lifespan then
				header.live = 0
				active_count = active_count - 1
				post_count = post_count - header.after_aa
				free_slots[#free_slots + 1] = slot
			else
				header.age = age

				if state.density then
					local spawn = 0

					if state.has_target then
						state.has_target = false
						local cur, prev = header.cur, header.prev

						if state.positioned then
							prev[0], prev[1], prev[2] = cur[0], cur[1], cur[2]
						else
							state.positioned = true
							prev[0], prev[1], prev[2] = state.x, state.y, state.z
						end

						cur[0], cur[1], cur[2] = state.x, state.y, state.z
						local dx, dy, dz = cur[0] - prev[0], cur[1] - prev[1], cur[2] - prev[2]
						state.accumulated = state.accumulated + state.density * math.sqrt(dx * dx + dy * dy + dz * dz)
						spawn = math.floor(state.accumulated)
						state.accumulated = state.accumulated - spawn
						spawn = math.min(spawn, flow_ribbons.SPRAY_POOL - spawn_total)
					end

					if spawn > 0 then
						source_slots[source_count] = slot
						source_firsts[source_count] = spawn_total
						source_counts[source_count] = spawn
						source_count = source_count + 1
						spawn_total = spawn_total + spawn
					end
				else
					local x = age / state.spray_travel

					if x < 1 then
						state.accumulated = state.accumulated + state.spray_rate * (1 - x) * (1 - x) * dt
						local spawn = math.floor(state.accumulated)
						state.accumulated = state.accumulated - spawn
						spawn = math.min(spawn, flow_ribbons.SPRAY_POOL - spawn_total)

						if spawn > 0 then
							source_slots[source_count] = slot
							source_firsts[source_count] = spawn_total
							source_counts[source_count] = spawn
							source_count = source_count + 1
							spawn_total = spawn_total + spawn
						end
					end
				end
			end
		end
	end

	spray_cursor = (spray_cursor + spawn_total) % flow_ribbons.SPRAY_POOL
	ffi.copy(buffer:Map(), headers, HEADER_BYTES)
	current_buffer = buffer
end

function flow_ribbons.IsActive()
	update_frame()
	return active_count > 0
end

function flow_ribbons.IsPostActive()
	update_frame()
	return post_count > 0 and render3d.IsPassEnabled("translucent")
end

function flow_ribbons.SetAfterAA(value)
	flow_ribbons.after_aa = value
	flow_ribbons.spray.after_aa = value
end

local common_glsl = [[
	struct FlowRibbon {
		vec3 origin;
		float age;
		vec3 dir;
		float duration;
		vec3 normal;
		float reach;
		vec3 color;
		float width;
		vec3 core;
		float curl;
		float loops;
		float phase;
		float plane;
		float spin;
		float travel;
		float tail;
		float emissive;
		float exposure_compensation;
		float meander;
		float spray_size;
		float spray_emissive;
		float spray_speed;
		float swirl;
		float flow;
		float drag;
		float life_min;
		float life_max;
		float inherit;
		float size_variation;
		float fizzle;
		float lift;
		vec3 prev;
		vec3 cur;
		float seed;
		int live;
		int uid;
		int after_aa;
		int kind;
	};

	layout(buffer_reference, scalar) readonly buffer FlowRibbonBuffer { FlowRibbon r[]; };

	float flow_ease(float x) {
		float k = 1.0 - clamp(x, 0.0, 1.0);
		return 1.0 - k * k * k;
	}

	vec3 flow_path(FlowRibbon r, float q, float age) {
		vec3 side = cross(r.normal, r.dir);
		float phi = 6.2831853 * r.loops * q + r.phase + age * r.spin;
		float envelope = smoothstep(0.0, 0.2, q);
		float amplitude = r.reach * r.curl * envelope;
		vec3 plane = side * cos(r.plane) + r.normal * abs(sin(r.plane));
		vec3 curl = r.dir * (-amplitude * sin(phi)) + plane * (amplitude * (1.1 - cos(phi)));
		vec3 drift = side * (r.reach * r.meander * sin(q * 5.0 + r.seed) * q) + r.normal * (r.reach * 0.02 * (1.0 + sin(q * 3.0 + r.seed * 1.7)) * q);
		return r.origin + r.dir * (r.reach * q) + curl + drift + r.normal * r.lift;
	}

	float flow_head(FlowRibbon r, float age) {
		return flow_ease(age / r.travel);
	}

	float flow_tail(FlowRibbon r, float age) {
		return flow_ease(max(age - r.tail, 0.0) / r.travel);
	}
]]
local draw_block = {
	name = "flow_ribbon_draw",
	binding_index = 3,
	block = {
		render3d.camera_block,
		render3d.prev_camera_block,
		post_source.pre_exposure_block,
		{"b0_tex", "int"},
		{"moments_tex", "int"},
		{"depth_warp", "vec2"},
		{"ribbons", "uint64_t"},
		{"ribbon_count", "int"},
		{"layer_active", "int"},
	},
	write = function(self, block)
		render3d.WriteCameraBlock(self, block)
		render3d.WritePreviousCameraBlock(self, block)
		post_source.WritePreExposureBlock(self, block)
		local b0, moments = translucent_moments.GetTextures()
		block.b0_tex = self:GetTextureIndex(b0)
		block.moments_tex = self:GetTextureIndex(moments)
		translucent_moments.WriteDepthWarp(block.depth_warp)
		block.ribbons = current_buffer:GetDeviceAddress()
		block.ribbon_count = high_water
		block.layer_active = post_source.IsEffectLayerActive() and 1 or 0
		return block
	end,
	upload_scope = "frame",
}
local vertex_outputs = {
	{"position", "vec3"},
	{"across", "float"},
	{"tint", "vec3"},
	{"core", "vec3"},
	{"strength", "float"},
	{"exposure_compensation", "float"},
}

local function get_vertex_glsl(layer)
	return "const int FLOW_LAYER = " .. layer .. ";\n" .. common_glsl .. [[
	const int FLOW_SEGMENTS = ]] .. flow_ribbons.SEGMENTS .. [[;

	void main() {
		FlowRibbon r = FlowRibbonBuffer(flow_ribbon_draw.ribbons).r[gl_InstanceIndex];
		float side = float(gl_VertexIndex & 1) * 2.0 - 1.0;
		float q_head = flow_head(r, r.age);
		float q_tail = flow_tail(r, r.age);

		if (r.live == 0 || r.age >= r.duration || q_head - q_tail < 1e-4 || ((r.after_aa != 0 && flow_ribbon_draw.layer_active != 0) != (FLOW_LAYER == 1))) {
			gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
			out_position = vec3(0.0);
			out_across = 0.0;
			out_tint = vec3(0.0);
			out_core = vec3(0.0);
			out_strength = 0.0;
			out_exposure_compensation = 0.0;
			return;
		}

		float w = float(gl_VertexIndex >> 1) / float(FLOW_SEGMENTS - 1);
		float q = mix(q_tail, q_head, w);
		float step_q = max((q_head - q_tail) / float(FLOW_SEGMENTS - 1), 1e-4);
		vec3 position = flow_path(r, q, r.age);
		vec3 tangent = flow_path(r, q + step_q, r.age) - flow_path(r, q - step_q, r.age);
		vec3 to_camera = flow_ribbon_draw.camera_position - position;
		float dist = length(to_camera);
		vec3 across = cross(tangent, to_camera);
		across = length(across) < 1e-8 ? mat3(flow_ribbon_draw.inv_view)[0] : normalize(across);
		float pixel = dist * 2.0 / (abs(flow_ribbon_draw.projection[1][1]) * flow_ribbon_draw.render_size.y);
		float profile = (0.12 + 0.88 * pow(w, 0.6)) * (1.0 - smoothstep(0.94, 1.0, w));
		float radius = max(r.width * profile, pixel * 0.75);
		float fade = 1.0 - smoothstep(r.travel + r.tail, r.duration, r.age);
		float speed = smoothstep(0.0, 0.06, r.age);
		vec3 world = position + across * side * radius;
		out_position = world;
		out_across = side;
		out_tint = r.color;
		out_core = r.core;
		out_strength = r.emissive * fade * speed * mix(0.2, 1.0, w) * min(pixel * 0.75 / max(r.width * profile, 1e-5), 1.0) ;
		out_exposure_compensation = r.exposure_compensation;
		gl_Position = flow_ribbon_draw.projection * flow_ribbon_draw.view * vec4(world, 1.0);
	}
]]
end

flow_ribbons.name = "flow_ribbons"

function flow_ribbons.Draw(pipeline, cmd)
	if not pipeline or not current_buffer then return end

	pipeline:UploadConstants()
	cmd:Draw(flow_ribbons.SEGMENTS * 2, high_water, 0, 0)
end

function flow_ribbons.BuildPasses()
	return {
		{
			name = "flow_ribbons_accumulate",
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
				shader = get_vertex_glsl(0),
			},
			fragment = {
				uniform_buffers = {draw_block},
				shader = post_source.GetPreExposureGLSL("flow_ribbon_draw") .. exposure_compensation.GetGLSL() .. translucent_moments.GLSL .. render3d.GetEmissiveGLSL() .. [[
					void main() {
						ivec2 pixel = ivec2(gl_FragCoord.xy);
						float transmittance = moments_transmittance(
							texelFetch(TEXTURE(flow_ribbon_draw.b0_tex), pixel, 0).r,
							texelFetch(TEXTURE(flow_ribbon_draw.moments_tex), pixel, 0),
							moments_warp_depth(distance(in_position, flow_ribbon_draw.camera_position), flow_ribbon_draw.depth_warp)
						);
						float x = in_across * in_across;
						float core = exp(-x * 9.0);
						float glow = exp(-x * 2.5);
						vec3 texel = in_core * core + in_tint * glow * 0.6;
						vec3 emission = min(texel * in_strength * EMISSIVE_REFERENCE_LUMINANCE, vec3(EMISSIVE_MAX_LUMINANCE)) * get_pre_exposure() * effect_exposure_gain(flow_ribbon_draw.pre_exposure_tex, in_exposure_compensation);
						set_color(vec4(0.0));
						set_motion(vec4(0.0));
						set_additive(vec4(min(emission, vec3(65504.0)), 0.0) * transmittance);
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
			color_blend = {
				attachments = {
					{},
					translucent_moments.ADDITIVE,
					translucent_moments.ADDITIVE,
					translucent_moments.MULTIPLY,
				},
			},
			DepthTest = true,
			DepthWrite = false,
			DepthCompareOp = "greater_or_equal",
		},
	}
end

function flow_ribbons.BuildPostPasses()
	return {
		{
			name = "flow_ribbons_post",
			draw_in_prerender = false,
			dont_create_framebuffers = true,
			ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
			DepthFormat = gbuffer_layout.DEPTH_FORMAT,
			Topology = "triangle_strip",
			vertex = {
				outputs = vertex_outputs,
				uniform_buffers = {draw_block},
				shader = get_vertex_glsl(1),
			},
			fragment = {
				uniform_buffers = {draw_block},
				shader = post_source.GetPreExposureGLSL("flow_ribbon_draw") .. exposure_compensation.GetGLSL() .. render3d.GetEmissiveGLSL() .. [[
					void main() {
						float x = in_across * in_across;
						vec3 texel = in_core * exp(-x * 9.0) + in_tint * exp(-x * 2.5) * 0.6;
						vec3 emission = min(texel * in_strength * EMISSIVE_REFERENCE_LUMINANCE, vec3(EMISSIVE_MAX_LUMINANCE)) * get_pre_exposure() * effect_exposure_gain(flow_ribbon_draw.pre_exposure_tex, in_exposure_compensation);
						set_color(vec4(min(emission, vec3(65504.0)), 0.0));
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
			DepthTest = true,
			DepthWrite = false,
			DepthCompareOp = "greater_or_equal",
		},
	}
end

event.AddListener("PreDraw3DTranslucent", "flow_ribbons", function()
	if flow_ribbons.IsActive() then
		render3d.ExtendTranslucentDepthRange(0.1, 300)
	end
end)

flow_ribbons.spray = particles.Register{
	name = "flow_ribbons",
	max_count = flow_ribbons.SPRAY_POOL,
	scatter_g = 0.3,
	streak_time = 1 / 24,
	fade_near = 0.3,
	depth_near = 0.1,
	depth_far = 300,
	lit = false,
	after_aa = flow_ribbons.after_aa,
	IsActive = flow_ribbons.IsActive,
	GetCount = function()
		return flow_ribbons.SPRAY_POOL, 1
	end,
	block = {
		{"ribbons", "uint64_t"},
		{
			"flow_sources",
			{
				{"slot", "int"},
				{"first", "int"},
				{"count", "int"},
				{"spare", "int"},
			},
			flow_ribbons.MAX_RIBBONS,
		},
		{"source_count", "int"},
		{"cursor", "int"},
		{"spawn_count", "int"},
		{"time", "float"},
	},
	WriteBlock = function(self, block)
		update_frame()
		block.ribbons = current_buffer:GetDeviceAddress()

		for i = 0, source_count - 1 do
			local entry = block.flow_sources[i]
			entry.slot = source_slots[i]
			entry.first = source_firsts[i]
			entry.count = source_counts[i]
		end

		block.source_count = source_count
		block.cursor = spray_cursor_start
		block.spawn_count = spawn_total
		block.time = get_time() % 1000
		return block
	end,
	declarations = glsl_common.GetNoiseGLSL() .. common_glsl .. [[
		#define FLOW_POOL ]] .. flow_ribbons.SPRAY_POOL .. [[u

		FlowRibbon flow_get_ribbon(uint slot) {
			return FlowRibbonBuffer(flow_ribbons_data.ribbons).r[slot];
		}

		vec3 flow_potential(vec3 q) {
			return vec3(value_noise3(q), value_noise3(q + 31.4), value_noise3(q + 71.7));
		}

		vec3 flow_field(vec3 position, FlowRibbon r) {
			vec3 q = position * 0.28 + vec3(r.seed, 0.0, flow_ribbons_data.time * 0.4);
			float e = 0.15;
			vec3 dx = flow_potential(q + vec3(e, 0.0, 0.0)) - flow_potential(q - vec3(e, 0.0, 0.0));
			vec3 dy = flow_potential(q + vec3(0.0, e, 0.0)) - flow_potential(q - vec3(0.0, e, 0.0));
			vec3 dz = flow_potential(q + vec3(0.0, 0.0, e)) - flow_potential(q - vec3(0.0, 0.0, e));
			vec3 curl = vec3(dy.z - dz.y, dz.x - dx.z, dx.y - dy.x) / (2.0 * e);
			vec3 rel = position - r.origin;
			vec3 planar = rel - r.normal * dot(rel, r.normal);
			vec3 swirl = cross(r.normal, planar) / (length(planar) + 1.0);
			return curl * r.flow + swirl * r.swirl;
		}

		uint flow_find_source(uint k) {
			for (int i = 0; i < flow_ribbons_data.source_count; i++) {
				flow_sources_t s = flow_ribbons_data.flow_sources[i];

				if (k < uint(s.first + s.count)) return uint(i);
			}

			return 0u;
		}
	]],
	should_spawn = [[
		uint k = (index + FLOW_POOL - uint(flow_ribbons_data.cursor)) % FLOW_POOL;
		return k < uint(flow_ribbons_data.spawn_count);
	]],
	spawn = [[
		uint k = (index + FLOW_POOL - uint(flow_ribbons_data.cursor)) % FLOW_POOL;

		if (k >= uint(flow_ribbons_data.spawn_count)) {
			p.life = 0.0;
			return;
		}

		flow_sources_t source = flow_ribbons_data.flow_sources[flow_find_source(k)];
		uint slot = uint(source.slot);
		FlowRibbon r = flow_get_ribbon(slot);

		if (r.live == 0) {
			p.life = 0.0;
			return;
		}

		vec3 rnd = pcg3d_unorm(uvec3(index, generation, 11u));
		vec3 rnd2 = pcg3d_unorm(uvec3(index, generation, 23u));
		float fraction = (float(k - uint(source.first)) + rnd2.z) / float(source.count);
		float elapsed = (1.0 - fraction) * particle_data.dt;
		vec3 origin;
		vec3 tangent;
		float lean = -0.3;
		vec3 inherited = vec3(0.0);

		if (r.kind == 1) {
			vec3 motion = r.cur - r.prev;
			float length_motion = length(motion);
			origin = mix(r.prev, r.cur, fraction);
			tangent = length_motion > 1e-5 ? motion / length_motion : vec3(0.0, 1.0, 0.0);
			inherited = motion / max(particle_data.dt, 1e-3);
		} else {
			float age = max(r.age - elapsed, 0.0);
			float q = mix(flow_tail(r, age), flow_head(r, age), rnd.x);
			origin = flow_path(r, q, age);
			tangent = normalize(flow_path(r, min(q + 0.02, 1.0), age) - flow_path(r, max(q - 0.02, 0.0), age) + 1e-5);
			lean = 0.25;
		}

		vec3 across = normalize(cross(tangent, abs(tangent.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 around = cross(tangent, across);
		float angle = 6.2831853 * rnd2.y;
		vec3 direction = across * cos(angle) + around * sin(angle) + tangent * lean;

		if (r.kind == 0) direction -= r.normal * min(dot(direction, r.normal), 0.0) * 2.0;

		direction = normalize(direction);
		p.velocity = direction * r.spray_speed * mix(0.3, 1.1, rnd.y) + inherited * r.inherit;
		p.position = origin + (rnd2 - 0.5) * 0.01 + p.velocity * elapsed;
		p.age = elapsed;
		p.life = mix(r.life_min, r.life_max, rnd.z);
		p.width = r.spray_size;
		p.spare = floatBitsToUint(1.0 + (pcg3d_unorm(uvec3(index, generation, 37u)).x * 2.0 - 1.0) * r.size_variation);
		p.user.y = slot;
		p.user.z = uint(r.uid);
	]],
	update = [[
		FlowRibbon r = flow_get_ribbon(min(p.user.y, uint(]] .. flow_ribbons.MAX_RIBBONS - 1 .. [[)));

		if (r.live == 0 || uint(r.uid) != p.user.z) {
			p.life = 0.0;
			return;
		}

		float t = clamp(p.age / p.life, 0.0, 1.0);
		p.width = r.spray_size * uintBitsToFloat(p.spare) * mix(1.0, 0.35, t);
		p.velocity += flow_field(p.position, r) * dt;
		float fizzle_weight = smoothstep(0.6, 1.0, t);

		if (r.fizzle > 0.0 && fizzle_weight > 0.0) {
			vec3 q = p.position * 60.0 + vec3(r.seed, flow_ribbons_data.time * 6.0, float(index) * 0.37);
			vec3 scatter = vec3(value_noise3(q), value_noise3(q + 17.3), value_noise3(q + 41.7)) - 0.5;
			p.velocity += normalize(scatter + 1e-4) * r.fizzle * fizzle_weight * dt;
		}

		p.velocity *= exp(-r.drag * dt);
		p.position += p.velocity * dt;
		float height = dot(p.position - r.origin, r.normal);

		if (r.kind == 0 && height < 0.0) {
			p.position -= r.normal * height;
			p.velocity -= r.normal * dot(p.velocity, r.normal);
		}
	]],
	visibility = [[
		float t = clamp(p.age / p.life, 0.0, 1.0);
		return smoothstep(0.0, 0.05, t) * (1.0 - t * t);
	]],
	shade = [[
		FlowRibbon r = flow_get_ribbon(min(p.user.y, uint(]] .. flow_ribbons.MAX_RIBBONS - 1 .. [[)));
		float t = clamp(p.age / p.life, 0.0, 1.0);
		p.radiance = mix(r.core, r.color, smoothstep(0.0, 0.6, t)) * r.spray_emissive * effect_exposure_gain(particle_data.pre_exposure_tex, r.exposure_compensation);
	]],
}
return flow_ribbons
