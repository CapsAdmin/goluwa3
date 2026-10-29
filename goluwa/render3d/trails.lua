local ffi = require("ffi")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local translucent_moments = import("goluwa/render3d/translucent_moments.lua")
local exposure_compensation = import("goluwa/render3d/exposure_compensation.lua")
local trails = {}
trails.MAX_TRAILS = 128
trails.MAX_POINTS = 160
trails.MAX_TEXTURES = 8
trails.SUBDIVISIONS = 4
trails.motion_vectors = true
local FRAME_BUFFERS = 3
local get_time = system.GetElapsedTime
local Header = ffi.typeof([[struct {
	float tint[3];
	float alpha;
	float radius_start;
	float radius_end;
	float uv_scale;
	float uv_offset;
	float center[3];
	float drift;
	float tint_end[3];
	float flicker;
	float exposure_compensation;
	int32_t count;
	int32_t head;
	int32_t texture_slot;
	int32_t live;
}]])
local HEADER_BYTES = ffi.sizeof(Header) * trails.MAX_TRAILS
local POINT_BYTES = 16
local POINTS_BYTES = trails.MAX_TRAILS * trails.MAX_POINTS * POINT_BYTES
local headers = ffi.typeof("$[?]", Header)(trails.MAX_TRAILS)
local points = ffi.new("float[?]", trails.MAX_TRAILS * trails.MAX_POINTS * 4)
local sums = ffi.new("double[?]", trails.MAX_TRAILS * 3)
local objects = {}
local free_slots = {}
local high_water = 0
local active_count = 0
local texture_slots = {}
local texture_list = {}
local buffers = {}
local current_buffer
local META = {}
META.__index = META

for i = trails.MAX_TRAILS - 1, 0, -1 do
	free_slots[#free_slots + 1] = i
end

local function get_texture_slot(texture)
	local slot = texture_slots[texture]

	if slot then return slot end

	assert(#texture_list < trails.MAX_TEXTURES, "too many trail textures")
	texture_list[#texture_list + 1] = texture
	slot = #texture_list - 1
	texture_slots[texture] = slot
	return slot
end

function trails.Acquire(config)
	local slot = table.remove(free_slots)
	assert(slot, "too many trails")
	assert(config.points <= trails.MAX_POINTS, "trail has too many points")
	local header = headers[slot]
	header.tint[0], header.tint[1], header.tint[2] = config.r, config.g, config.b
	header.alpha = config.alpha or 1
	header.radius_start = config.radius_start or 0
	header.radius_end = config.radius_end or 0.05
	header.uv_scale = config.uv_scale or 1
	header.uv_offset = config.uv_offset or 0
	header.drift = config.drift or 0
	header.tint_end[0], header.tint_end[1], header.tint_end[2] = config.r_end or config.r, config.g_end or config.g, config.b_end or config.b
	header.flicker = config.flicker or 0
	header.exposure_compensation = config.exposure_compensation or 0
	header.count = config.points
	header.head = 0
	header.texture_slot = get_texture_slot(config.texture)
	header.live = 0
	local object = objects[slot]

	if not object then
		object = setmetatable({slot = slot}, META)
		objects[slot] = object
	end

	object.slot = slot
	object.primed = false
	high_water = math.max(high_water, slot + 1)
	return object
end

function META:Push(x, y, z)
	local now = get_time()
	local slot = self.slot
	local header = headers[slot]
	local count = header.count
	local base = slot * trails.MAX_POINTS
	local sum = sums + slot * 3

	if not self.primed then
		self.primed = true
		header.live = 1
		active_count = active_count + 1
		sum[0], sum[1], sum[2] = x * count, y * count, z * count

		for i = 0, count - 1 do
			local o = (base + i) * 4
			points[o], points[o + 1], points[o + 2], points[o + 3] = x, y, z, now
		end
	else
		local o = (base + header.head) * 4
		sum[0] = sum[0] + x - points[o]
		sum[1] = sum[1] + y - points[o + 1]
		sum[2] = sum[2] + z - points[o + 2]
		points[o], points[o + 1], points[o + 2], points[o + 3] = x, y, z, now
		header.head = (header.head + 1) % count
	end

	header.center[0], header.center[1], header.center[2] = sum[0] / count, sum[1] / count, sum[2] / count
end

function META:SetColor(r, g, b, a, r_end, g_end, b_end)
	local header = headers[self.slot]
	header.tint[0], header.tint[1], header.tint[2] = r, g, b
	header.tint_end[0], header.tint_end[1], header.tint_end[2] = r_end or r, g_end or g, b_end or b
	header.alpha = a
end

function META:Release()
	local header = headers[self.slot]

	if header.live == 1 then active_count = active_count - 1 end

	header.live = 0
	free_slots[#free_slots + 1] = self.slot
end

trails.system_name = "trails"

function trails.IsActive()
	return active_count > 0 and render3d.IsPassEnabled("translucent")
end

event.AddListener("PreDraw3DTranslucent", "trails", function()
	if not trails.IsActive() then return end

	render3d.ExtendTranslucentDepthRange(0.1, 300)
	local index = system.GetFrameNumber() % FRAME_BUFFERS
	local buffer = buffers[index]

	if not buffer then
		buffer = render.CreateBuffer{
			byte_size = HEADER_BYTES + POINTS_BYTES,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "trails",
		}
		buffers[index] = buffer
	end

	local mapped = buffer:Map()
	ffi.copy(mapped, headers, HEADER_BYTES)
	local points_mapped = mapped + HEADER_BYTES

	for slot = 0, high_water - 1 do
		local header = headers[slot]

		if header.live == 1 then
			local offset = slot * trails.MAX_POINTS * POINT_BYTES
			ffi.copy(
				points_mapped + offset,
				ffi.cast("uint8_t *", points) + offset,
				header.count * POINT_BYTES
			)
		end
	end

	current_buffer = buffer
end)

local draw_block = {
	name = "trail_draw",
	binding_index = 3,
	block = {
		render3d.camera_block,
		render3d.prev_camera_block,
		post_source.pre_exposure_block,
		{"b0_tex", "int"},
		{"moments_tex", "int"},
		{"depth_warp", "vec2"},
		{"headers", "uint64_t"},
		{"points", "uint64_t"},
		{"textures", "int", trails.MAX_TEXTURES},
		{"trail_count", "int"},
		{"time", "float"},
		{"motion_enabled", "int"},
	},
	write = function(self, block)
		render3d.WriteCameraBlock(self, block)
		render3d.WritePreviousCameraBlock(self, block)
		post_source.WritePreExposureBlock(self, block)
		local b0, moments = translucent_moments.GetTextures()
		block.b0_tex = self:GetTextureIndex(b0)
		block.moments_tex = self:GetTextureIndex(moments)
		translucent_moments.WriteDepthWarp(block.depth_warp)
		local address = current_buffer:GetDeviceAddress()
		block.headers = address
		block.points = address + HEADER_BYTES

		for i, texture in ipairs(texture_list) do
			block.textures[i - 1] = self:GetTextureIndex(texture)
		end

		block.trail_count = high_water
		block.time = get_time()
		block.motion_enabled = trails.motion_vectors and 1 or 0
		return block
	end,
	upload_scope = "frame",
}
local vertex_outputs = {
	{"position", "vec3"},
	{"uv", "vec2"},
	{"tint", "vec3"},
	{"alpha", "float"},
	{"texture_slot", "float"},
	{"flicker", "float"},
	{"exposure_compensation", "float"},
	{"motion", "vec2"},
}
local common_glsl = [[
	const int TRAIL_MAX_POINTS = ]] .. trails.MAX_POINTS .. [[;

	struct TrailHeader {
		vec3 tint;
		float alpha;
		float radius_start;
		float radius_end;
		float uv_scale;
		float uv_offset;
		vec3 center;
		float drift;
		vec3 tint_end;
		float flicker;
		float exposure_compensation;
		int count;
		int head;
		int texture_slot;
		int live;
	};

	layout(buffer_reference, scalar) readonly buffer TrailHeaderBuffer { TrailHeader h[]; };
	layout(buffer_reference, scalar) readonly buffer TrailPointBuffer { vec4 p[]; };
]]
local vertex_glsl = common_glsl .. [[
	const int TRAIL_SUBDIVISIONS = ]] .. trails.SUBDIVISIONS .. [[;

	vec3 trail_position(int slot, TrailHeader header, int logical, float now) {
		vec3 sum = vec3(0.0);
		float weights[3] = float[](1.0, 2.0, 1.0);

		for (int k = 0; k < 3; k++) {
			int index = clamp(logical + k - 1, 0, header.count - 1);
			vec4 p = TrailPointBuffer(trail_draw.points).p[slot * TRAIL_MAX_POINTS + (header.head + index) % header.count];
			sum += (p.xyz + (p.xyz - header.center) * header.drift * max(now - p.w, 0.0)) * weights[k];
		}

		return sum * 0.25;
	}

	void main() {
		int slot = gl_InstanceIndex;
		TrailHeader header = TrailHeaderBuffer(trail_draw.headers).h[slot];
		float side = float(gl_VertexIndex & 1) * 2.0 - 1.0;

		if (header.live == 0) {
			gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
			out_position = vec3(0.0);
			out_uv = vec2(0.0);
			out_tint = vec3(0.0);
			out_alpha = 0.0;
			out_texture_slot = 0.0;
			out_flicker = 0.0;
			out_exposure_compensation = 0.0;
			out_motion = vec2(0.0);
			return;
		}

		float now = trail_draw.time;
		float s = min(float(gl_VertexIndex >> 1) / float(TRAIL_SUBDIVISIONS), float(header.count - 1));
		int j = min(int(floor(s)), header.count - 2);
		float u = s - float(j);
		vec3 p0 = trail_position(slot, header, j - 1, now);
		vec3 p1 = trail_position(slot, header, j, now);
		vec3 p2 = trail_position(slot, header, j + 1, now);
		vec3 p3 = trail_position(slot, header, j + 2, now);
		vec3 a = -p0 + p2;
		vec3 b = 2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3;
		vec3 c = -p0 + 3.0 * p1 - 3.0 * p2 + p3;
		vec3 position = 0.5 * (2.0 * p1 + a * u + b * u * u + c * u * u * u);
		vec3 tangent = 0.5 * (a + 2.0 * b * u + 3.0 * c * u * u);
		vec3 to_camera = trail_draw.camera_position - position;
		float dist = length(to_camera);
		vec3 across = cross(tangent, to_camera);
		across = length(across) < 1e-6 ? mat3(trail_draw.inv_view)[0] : normalize(across);
		float t = s / float(max(header.count - 1, 1));
		float pixel = dist * 2.0 / (abs(trail_draw.projection[1][1]) * trail_draw.render_size.y);
		float radius = max(mix(header.radius_start, header.radius_end, t), pixel * 0.75);
		vec3 world = position + across * side * radius;
		out_position = world;
		out_uv = vec2(side * 0.5 + 0.5, t * header.uv_scale + header.uv_offset);
		out_tint = mix(header.tint_end, header.tint, t);
		out_alpha = header.alpha;
		out_texture_slot = float(header.texture_slot);
		out_flicker = header.flicker;
		out_exposure_compensation = header.exposure_compensation;
		vec4 clip = trail_draw.projection * trail_draw.view * vec4(world, 1.0);
		vec4 prev_clip = trail_draw.prev_projection * trail_draw.prev_view * vec4(world, 1.0);
		out_motion = clip.w > 0.0001 && prev_clip.w > 0.0001 ? (clip.xy / clip.w - prev_clip.xy / prev_clip.w) * 0.5 : vec2(0.0);
		gl_Position = trail_draw.projection * trail_draw.view * vec4(world, 1.0);
	}
]]
trails.name = "trails"

function trails.Draw(pipeline, cmd)
	if not pipeline or not current_buffer then return end

	pipeline:UploadConstants()
	cmd:Draw(((trails.MAX_POINTS - 1) * trails.SUBDIVISIONS + 1) * 2, high_water, 0, 0)
end

function trails.BuildPasses()
	return {
		{
			name = "trails_accumulate",
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
				shader = vertex_glsl,
			},
			fragment = {
				uniform_buffers = {draw_block},
				shader = post_source.GetPreExposureGLSL("trail_draw") .. exposure_compensation.GetGLSL() .. translucent_moments.GLSL .. render3d.GetEmissiveGLSL() .. [[
					void main() {
						ivec2 pixel = ivec2(gl_FragCoord.xy);
						float transmittance = moments_transmittance(
							texelFetch(TEXTURE(trail_draw.b0_tex), pixel, 0).r,
							texelFetch(TEXTURE(trail_draw.moments_tex), pixel, 0),
							moments_warp_depth(distance(in_position, trail_draw.camera_position), trail_draw.depth_warp)
						);
						vec3 texel = texture(TEXTURE(trail_draw.textures[int(in_texture_slot + 0.5)]), in_uv).rgb;
						float n0 = fract(sin(floor(in_uv.y * 48.0 - trail_draw.time * 9.0) * 12.9898) * 43758.5453);
						float n1 = fract(sin((floor(in_uv.y * 48.0 - trail_draw.time * 9.0) + 1.0) * 12.9898) * 43758.5453);
						float flick = 1.0 - in_flicker * mix(n0, n1, smoothstep(0.0, 1.0, fract(in_uv.y * 48.0 - trail_draw.time * 9.0)));
						vec3 emission = min(texel * in_tint * EMISSIVE_REFERENCE_LUMINANCE, vec3(EMISSIVE_MAX_LUMINANCE)) * in_alpha * flick * get_pre_exposure() * effect_exposure_gain(trail_draw.pre_exposure_tex, in_exposure_compensation);
						set_color(vec4(0.0));
						float coverage = trail_draw.motion_enabled != 0 ? clamp(dot(texel, vec3(0.3333)) * 4.0, 0.0, 1.0) * clamp(in_alpha * 8.0, 0.0, 1.0) : 0.0;
						set_motion(vec4(in_motion * coverage, coverage, 0.0) * transmittance);
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

return trails
