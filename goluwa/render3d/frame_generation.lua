local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Texture = import("goluwa/render/texture.lua")
local render = import("goluwa/render/render.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local frame_generation = {}
local SLOTS_PER_FRAME = 32
local MAX_FRAMES = 9
local state = {
	history_valid = false,
	frames_since_reset = 0,
	reproject = Matrix44(),
	inv_projection = Matrix44(),
}
local compose_pipelines = {}
local compute = {}
local resources = {}
-- shared by every frame interpolation pass; "fi" is the per frame uniform block, "compute" the per dispatch push constants
local FI_GLSL = [[
	const float FI_EPSILON = 1e-3;
	const uint PRIORITY_LOW_MAX = 31u;
	const uint PRIORITY_HIGH_MAX = 1023u;
	const uint PRIORITY_LOW_OFFSET = 16u;
	const uint PRIORITY_HIGH_OFFSET = 21u;
	const uint PRIMARY_BIT = 0x80000000u;
	const ivec2 BILINEAR_OFFSETS[4] = ivec2[4](ivec2(0, 0), ivec2(1, 0), ivec2(0, 1), ivec2(1, 1));

	ivec2 render_size() {
		return ivec2(fi.render_size);
	}

	ivec2 display_size() {
		return ivec2(fi.display_size);
	}

	bool on_screen(ivec2 p, ivec2 size) {
		return all(lessThan(uvec2(p), uvec2(size)));
	}

	bool uv_inside(vec2 uv) {
		return uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0;
	}

	float min_divided_by_max(float a, float b) {
		float m = max(a, b);
		return m != 0.0 ? min(a, b) / m : 0.0;
	}

	float luminance_of(vec3 c) {
		return dot(c, vec3(0.2126, 0.7152, 0.0722));
	}

	ivec2 bilinear_base;
	vec4 bilinear_weights;

	void bilinear(vec2 uv, ivec2 size) {
		vec2 p = uv * vec2(size) - 0.5;
		bilinear_base = ivec2(floor(p));
		vec2 f = fract(p);
		bilinear_weights = vec4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
	}

	float view_depth(float device_depth) {
		vec4 p = fi.inv_projection * vec4(0.0, 0.0, device_depth, 1.0);
		return min(-p.z / p.w, 1e6);
	}

	uvec2 pack_entry(bool primary, uint high, uint low, vec2 mv) {
		uint priority = (primary ? PRIMARY_BIT : 0u) | ((high & PRIORITY_HIGH_MAX) << PRIORITY_HIGH_OFFSET) | ((low & PRIORITY_LOW_MAX) << PRIORITY_LOW_OFFSET);
		return uvec2(priority | (packHalf2x16(vec2(mv.x, 0.0)) & 0xFFFFu), priority | (packHalf2x16(vec2(mv.y, 0.0)) & 0xFFFFu));
	}

	struct Entry {
		vec2 mv;
		float high;
		float low;
		bool valid;
		bool primary;
		bool inpainted;
		bool neg_outside;
		bool pos_outside;
	};

	Entry unpack_entry(uvec2 packed) {
		Entry e;
		e.high = float((packed.x >> PRIORITY_HIGH_OFFSET) & PRIORITY_HIGH_MAX) / float(PRIORITY_HIGH_MAX);
		e.low = float((packed.x >> PRIORITY_LOW_OFFSET) & PRIORITY_LOW_MAX) / float(PRIORITY_LOW_MAX);
		e.primary = (packed.x & PRIMARY_BIT) != 0u;
		e.valid = e.high > 0.0;

		if (e.valid && !e.primary) e.high = 1.0 - e.high;

		e.mv = vec2(unpackHalf2x16(packed.x).x, unpackHalf2x16(packed.y).x);
		e.inpainted = false;
		e.neg_outside = false;
		e.pos_outside = false;
		return e;
	}
]]
local GAME_FIELD_GLSL = [[
	vec4 mv_inpainting_level(vec2 uv, int mip, ivec2 size) {
		bilinear(uv, size);
		float sum = 0.0;
		vec4 color = vec4(0.0);

		for (int i = 0; i < 4; i++) {
			ivec2 p = bilinear_base + BILINEAR_OFFSETS[i];

			if (on_screen(p, size)) {
				vec4 s = texelFetch(TEXTURE(fi.game_pyramid_tex), p, mip);
				float w = bilinear_weights[i] * float(s.z > 0.0) * s.z;
				sum += w;
				color += s * w;
			}
		}

		return color / (sum > 0.0 ? sum : 1.0);
	}

	Entry load_game_mv(vec2 uv) {
		ivec2 p = clamp(ivec2(uv * vec2(render_size())), ivec2(0), render_size() - 1);
		Entry e = unpack_entry(uvec2(imageLoad(game_x, p).r, imageLoad(game_y, p).r));

		if (!e.valid) {
			ivec2 size = render_size();
			vec4 v = vec4(0.0);

			for (int mip = 0; mip < fi.game_pyramid_mips && v.w == 0.0; mip++) {
				size /= 2;
				v = mv_inpainting_level(uv, mip, size);
			}

			e.mv = v.xy;
			e.high = v.z;
			e.low = v.w;
			e.inpainted = true;
		}

		e.neg_outside = !uv_inside(uv - e.mv);
		e.pos_outside = !uv_inside(uv + e.mv);
		return e;
	}
]]
local FI_BLOCK = {
	{"reproject", "mat4"},
	{"inv_projection", "mat4"},
	{"render_size", "vec2"},
	{"display_size", "vec2"},
	{"view_scale", "float"},
	{"kfov", "float"},
	{"depth_tex", "int"},
	{"velocity_tex", "int"},
	{"scene_tex", "int"},
	{"history_tex", "int"},
	{"game_pyramid_tex", "int"},
	{"game_pyramid_mips", "int"},
	{"disocclusion_tex", "int"},
	{"color_pyramid_tex", "int"},
	{"color_pyramid_mips", "int"},
	{"frames_since_reset", "int"},
}
local PUSH_BLOCK = {
	{"mode", "int"},
	{"mip", "int"},
}

local function write_fi(self, block)
	state.reproject:CopyToFloatPointer(block.reproject)
	state.inv_projection:CopyToFloatPointer(block.inv_projection)
	block.render_size[0] = resources.render_width
	block.render_size[1] = resources.render_height
	block.display_size[0] = resources.display_width
	block.display_size[1] = resources.display_height
	block.view_scale = state.view_scale
	block.kfov = state.kfov
	block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
	block.velocity_tex = render3d.velocity_enabled:Get() and
		self:GetTextureIndex(gbuffer_layout.GetTexture("velocity")) or
		-1
	block.scene_tex = self:GetTextureIndex(state.scene)
	block.history_tex = self:GetTextureIndex(resources.history)
	block.game_pyramid_tex = self:GetTextureIndex(resources.game_pyramid)
	block.game_pyramid_mips = #resources.game_pyramid_views
	block.disocclusion_tex = self:GetTextureIndex(resources.disocclusion)
	block.color_pyramid_tex = self:GetTextureIndex(resources.color_pyramid)
	block.color_pyramid_mips = #resources.color_pyramid_views
	block.frames_since_reset = state.frames_since_reset
	return block
end

local function write_push(self, block)
	block.mode = state.mode
	block.mip = state.mip
	return block
end

local function get_compute(name, storage_count, declarations, shader)
	if compute[name] then return compute[name] end

	local storage_images = {}

	for i = 0, storage_count - 1 do
		storage_images[#storage_images + 1] = {binding_index = i}
	end

	compute[name] = EasyPipeline.Compute{
		name = "frame_generation_" .. name,
		DescriptorSetCount = MAX_FRAMES * SLOTS_PER_FRAME,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = storage_images,
		uniform_buffers = {
			{name = "fi", binding_index = storage_count, block = FI_BLOCK, write = write_fi},
		},
		block = PUSH_BLOCK,
		write = write_push,
		custom_declarations = declarations,
		shader = FI_GLSL .. shader,
	}
	return compute[name]
end

local CLEAR_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32ui) uniform writeonly uimage2D prev_depth;
	layout(set = 0, binding = 1, r32ui) uniform writeonly uimage2D interp_depth;
	layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D game_x;
	layout(set = 0, binding = 3, r32ui) uniform writeonly uimage2D game_y;
	layout(set = 0, binding = 4, rg16f) uniform writeonly image2D disocclusion;
]]
local CLEAR_SHADER = [[
	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);

		if (!on_screen(p, render_size())) return;

		imageStore(prev_depth, p, uvec4(0u));
		imageStore(interp_depth, p, uvec4(0u));
		imageStore(game_x, p, uvec4(0u));
		imageStore(game_y, p, uvec4(0u));
		imageStore(disocclusion, p, vec4(0.0));
	}
]]
local DILATE_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32f) uniform writeonly image2D dilated_depth;
	layout(set = 0, binding = 1, rg16f) uniform writeonly image2D dilated_motion;
	layout(set = 0, binding = 2, r32ui) uniform uimage2D prev_depth;
]]
local DILATE_SHADER = [[
	const ivec2 NEIGHBOURS[9] = ivec2[9](ivec2(0, 0), ivec2(1, 0), ivec2(0, 1), ivec2(0, -1), ivec2(-1, 0), ivec2(-1, 1), ivec2(1, 1), ivec2(-1, -1), ivec2(1, -1));

	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);
		ivec2 size = render_size();

		if (!on_screen(p, size)) return;

		float nearest = texelFetch(TEXTURE(fi.depth_tex), p, 0).r;
		ivec2 nearest_pixel = p;

		for (int i = 1; i < 9; i++) {
			ivec2 q = p + NEIGHBOURS[i];

			if (on_screen(q, size)) {
				float d = texelFetch(TEXTURE(fi.depth_tex), q, 0).r;

				if (d > nearest) {
					nearest = d;
					nearest_pixel = q;
				}
			}
		}

		vec2 uv = (vec2(nearest_pixel) + 0.5) / vec2(size);
		vec2 mv;

		if (nearest > 0.0 && fi.velocity_tex != -1) {
			mv = -texelFetch(TEXTURE(fi.velocity_tex), nearest_pixel, 0).xy;
		} else {
			vec4 prev_clip = fi.reproject * vec4(uv * 2.0 - 1.0, nearest, 1.0);
			mv = (prev_clip.xy / prev_clip.w * 0.5 + 0.5) - uv;
		}

		imageStore(dilated_depth, p, vec4(nearest));
		imageStore(dilated_motion, p, vec4(mv, 0.0, 0.0));
		vec2 scatter_mv = mv * float(length(mv * display_size()) > 0.1);
		bilinear((vec2(p) + 0.5) / vec2(size) + scatter_mv, size);

		for (int i = 0; i < 4; i++) {
			ivec2 q = bilinear_base + BILINEAR_OFFSETS[i];

			if (bilinear_weights[i] > FI_EPSILON && on_screen(q, size)) imageAtomicMax(prev_depth, q, floatBitsToUint(nearest));
		}
	}
]]
local INTERP_DEPTH_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32f) uniform readonly image2D dilated_depth;
	layout(set = 0, binding = 1, rg16f) uniform readonly image2D dilated_motion;
	layout(set = 0, binding = 2, r32ui) uniform uimage2D interp_depth;
]]
local INTERP_DEPTH_SHADER = [[
	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);
		ivec2 size = render_size();

		if (!on_screen(p, size)) return;

		float depth = imageLoad(dilated_depth, p).r;
		bilinear((vec2(p) + 0.5) / vec2(size) + imageLoad(dilated_motion, p).xy * 0.5, size);

		for (int i = 0; i < 4; i++) {
			ivec2 q = bilinear_base + BILINEAR_OFFSETS[i];

			if (bilinear_weights[i] > FI_EPSILON && on_screen(q, size)) imageAtomicMax(interp_depth, q, floatBitsToUint(depth));
		}
	}
]]
local GAME_FIELD_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32f) uniform readonly image2D dilated_depth;
	layout(set = 0, binding = 1, rg16f) uniform readonly image2D dilated_motion;
	layout(set = 0, binding = 2, r32ui) uniform uimage2D game_x;
	layout(set = 0, binding = 3, r32ui) uniform uimage2D game_y;
]]
local GAME_FIELD_SHADER = [[
	uint priority_from_view_depth(float meters) {
		meters = pow(meters, 0.33);
		return max(1u, uint((1.0 - meters / (1.0 + meters)) * float(PRIORITY_HIGH_MAX)));
	}

	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);
		ivec2 size = render_size();

		if (!on_screen(p, size)) return;

		vec2 uv = (vec2(p) + 0.5) / vec2(size);
		float depth = imageLoad(dilated_depth, p).r;
		vec2 mv = imageLoad(dilated_motion, p).xy;
		vec2 mv_half = mv * 0.5;
		vec2 interpolated_uv = uv + mv_half;
		uint high_primary = priority_from_view_depth(view_depth(depth) / fi.view_scale);
		float prev_luma = 0.001 + luminance_of(textureLod(TEXTURE(fi.history_tex), uv + mv, 0.0).rgb);
		float curr_luma = 0.001 + luminance_of(textureLod(TEXTURE(fi.scene_tex), uv, 0.0).rgb);
		uint low = uint(round(min_divided_by_max(prev_luma, curr_luma) * float(PRIORITY_LOW_MAX))) * uint(uv_inside(uv + mv));
		uvec2 primary = pack_entry(true, high_primary, low, mv_half);
		bilinear(interpolated_uv, size);

		for (int i = 0; i < 4; i++) {
			ivec2 q = bilinear_base + BILINEAR_OFFSETS[i];

			if (on_screen(q, size)) {
				imageAtomicMax(game_x, q, primary.x);
				imageAtomicMax(game_y, q, primary.y);
			}
		}

		if (length(mv_half * vec2(size)) > FI_EPSILON) {
			bool write_secondary = true;
			uint primary_hits = 0u;
			float step_scale = length(1.0 / vec2(size));
			vec2 step_mv = normalize(mv);
			float break_distance = min(length(mv_half), length(vec2(0.5)));

			for (float scale = step_scale; scale <= break_distance && write_secondary; scale += step_scale) {
				vec2 secondary_uv = interpolated_uv - step_mv * scale;
				bilinear(secondary_uv, size);
				uint high_secondary = max(1u, PRIORITY_HIGH_MAX - high_primary);
				vec2 to_center = normalize(vec2(0.5) - secondary_uv);
				uint low_secondary = uint(max(0.0, dot(to_center, step_mv)) * float(PRIORITY_LOW_MAX));
				uvec2 secondary = pack_entry(false, high_secondary, low_secondary, mv_half);
				ivec2 q = bilinear_base;
				write_secondary = on_screen(q, size);

				if (write_secondary) {
					uint existing = max(imageAtomicMax(game_x, q, secondary.x), imageAtomicMax(game_y, q, secondary.y));
					primary_hits += uint((existing & PRIMARY_BIT) != 0u);
					write_secondary = primary_hits <= 3u;
				}
			}
		}
	}
]]
-- mode 0 reduces the source field into mip 0, mode 1 reduces the previous mip into the next
local GAME_PYRAMID_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D game_x;
	layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D game_y;
	layout(set = 0, binding = 2, rgba16f) uniform readonly image2D source_mip;
	layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D target_mip;
]]
local GAME_PYRAMID_SHADER = [[
	vec4 load_source(ivec2 p) {
		if (compute.mode == 0) {
			if (!on_screen(p, render_size())) return vec4(0.0);

			Entry e = unpack_entry(uvec2(imageLoad(game_x, p).r, imageLoad(game_y, p).r));
			return vec4(e.mv, e.high, e.low);
		}

		if (!on_screen(p, imageSize(source_mip))) return vec4(0.0);

		return imageLoad(source_mip, p);
	}

	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);

		if (!on_screen(p, imageSize(target_mip))) return;

		vec4 sum = vec4(0.0);
		float weight = 0.0;

		for (int i = 0; i < 4; i++) {
			vec4 s = load_source(p * 2 + BILINEAR_OFFSETS[i]);
			float w = float(s.z > 0.0);
			sum += s * w;
			weight += w;
		}

		imageStore(target_mip, p, sum / (weight > FI_EPSILON ? weight : 1.0));
	}
]]
local DISOCCLUSION_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32f) uniform readonly image2D dilated_depth;
	layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D prev_depth;
	layout(set = 0, binding = 2, r32ui) uniform readonly uimage2D interp_depth;
	layout(set = 0, binding = 3, r32ui) uniform readonly uimage2D game_x;
	layout(set = 0, binding = 4, r32ui) uniform readonly uimage2D game_y;
	layout(set = 0, binding = 5, rg16f) uniform writeonly image2D disocclusion;
]]
local DISOCCLUSION_SHADER = GAME_FIELD_GLSL .. [[
	float estimated_depth(int index, ivec2 p) {
		return index == 0 ? uintBitsToFloat(imageLoad(prev_depth, p).r) : imageLoad(dilated_depth, p).r;
	}

	float depth_clip(int index, vec2 uv, float current_depth) {
		ivec2 size = render_size();
		float current_view = view_depth(current_depth);
		bilinear(uv, size);
		float depth = 0.0;
		float weight_sum = 0.0;

		for (int i = 0; i < 4; i++) {
			ivec2 q = bilinear_base + BILINEAR_OFFSETS[i];
			float w = bilinear_weights[i];

			if (on_screen(q, size) && w > FI_EPSILON) {
				float previous_view = view_depth(estimated_depth(index, q));
				float difference = current_view - previous_view;

				if (difference > 0.0) {
					float required_separation = 1.37e-05 * fi.kfov * length(vec2(size)) * min(current_view, previous_view);
					depth += float(required_separation / difference >= 1.0) * w;
					weight_sum += w;
				}
			}
		}

		return weight_sum > 0.0 ? clamp(1.0 - depth / weight_sum, 0.0, 1.0) : 0.0;
	}

	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);
		ivec2 size = render_size();

		if (!on_screen(p, size)) return;

		float depth = uintBitsToFloat(imageLoad(interp_depth, p).r);
		vec2 uv = (vec2(p) + 0.5) / vec2(size);
		Entry game = load_game_mv(uv);
		vec2 mask = vec2(1.0 - depth_clip(0, uv + game.mv, depth), 1.0 - depth_clip(1, uv - game.mv, depth));
		mask = vec2(greaterThanEqual(mask, vec2(FI_EPSILON)));
		mask.x = clamp(mask.x + float(!on_screen(ivec2((uv + game.mv * 2.0) * vec2(size)), size)), 0.0, 1.0);
		mask.y = clamp(mask.y + float(!on_screen(ivec2((uv - game.mv * 2.0) * vec2(size)), size)), 0.0, 1.0);
		imageStore(disocclusion, p, vec4(mask, 0.0, 0.0));
	}
]]
local INTERPOLATION_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D game_x;
	layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D game_y;
	layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D interpolated;
]]
local INTERPOLATION_SHADER = GAME_FIELD_GLSL .. [[
	vec4 sample_source(bool current, vec2 uv) {
		ivec2 size = display_size();
		bilinear(uv, size);
		vec3 color = vec3(0.0);
		float weight_sum = 0.0;

		for (int i = 0; i < 4; i++) {
			ivec2 q = bilinear_base + BILINEAR_OFFSETS[i];

			if (on_screen(q, size)) {
				float w = bilinear_weights[i];
				color += (current ? texelFetch(TEXTURE(fi.scene_tex), q, 0).rgb : texelFetch(TEXTURE(fi.history_tex), q, 0).rgb) * w;
				weight_sum += w;
			}
		}

		return vec4(weight_sum != 0.0 ? color / weight_sum : vec3(0.0), weight_sum);
	}

	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);
		ivec2 size = display_size();

		if (!on_screen(p, size)) return;

		if (fi.frames_since_reset == 0) {
			imageStore(interpolated, p, vec4(texelFetch(TEXTURE(fi.scene_tex), p, 0).rgb, 0.0));
			return;
		}

		vec2 uv = (vec2(p) + 0.5) / vec2(size);
		Entry game = load_game_mv(uv);
		vec2 disocclusion = vec2(equal(clamp(textureLod(TEXTURE(fi.disocclusion_tex), uv, 0.0).xy, 0.0, 1.0), vec2(1.0)));
		vec4 previous = sample_source(false, uv + game.mv);
		vec4 current = sample_source(true, uv - game.mv);
		disocclusion.x *= float(!game.pos_outside);
		disocclusion.y *= float(!game.neg_outside);
		float inpainting = length(disocclusion) <= FI_EPSILON ? 1.0 : 0.0;
		float t = 0.5 + 0.5 * (1.0 - disocclusion.x) - 0.5 * (1.0 - disocclusion.y);
		vec3 color = mix(previous.rgb, current.rgb, clamp(t, 0.0, 1.0));

		if (previous.w == 0.0) {
			color = current.rgb;
		} else if (current.w == 0.0) {
			color = previous.rgb;
		}

		if (previous.w == 0.0 && current.w == 0.0) inpainting = 1.0;

		imageStore(interpolated, p, vec4(color, inpainting));
	}
]]
local COLOR_PYRAMID_DECLARATIONS = [[
	layout(set = 0, binding = 0, rgba16f) uniform readonly image2D interpolated;
	layout(set = 0, binding = 1, rgba16f) uniform readonly image2D source_mip;
	layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D target_mip;
]]
local COLOR_PYRAMID_SHADER = [[
	vec4 load_source(ivec2 p) {
		if (compute.mode == 0) {
			if (!on_screen(p, display_size())) return vec4(0.0);

			vec4 c = imageLoad(interpolated, p);
			return vec4(c.rgb, clamp(1.0 - c.w, 0.0, 1.0));
		}

		if (!on_screen(p, imageSize(source_mip))) return vec4(0.0);

		return imageLoad(source_mip, p);
	}

	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);

		if (!on_screen(p, imageSize(target_mip))) return;

		vec4 v[4];
		float sum = 0.0;

		for (int i = 0; i < 4; i++) {
			v[i] = load_source(p * 2 + BILINEAR_OFFSETS[i]);
			sum += v[i].w;
		}

		imageStore(target_mip, p, sum == 0.0 ? vec4(0.0) : (v[0] * v[0].w + v[1] * v[1].w + v[2] * v[2].w + v[3] * v[3].w) / sum);
	}
]]
local INPAINTING_DECLARATIONS = [[
	layout(set = 0, binding = 0, rgba16f) uniform image2D interpolated;
]]
local INPAINTING_SHADER = [[
	vec4 inpainting_level(vec2 uv, int mip, ivec2 size) {
		bilinear(uv, size);
		vec4 color = vec4(0.0);

		for (int i = 0; i < 4; i++) {
			ivec2 q = bilinear_base + BILINEAR_OFFSETS[i];

			if (on_screen(q, size)) {
				vec4 s = texelFetch(TEXTURE(fi.color_pyramid_tex), q, mip);
				float w = bilinear_weights[i] * float(s.w > 0.0);
				color += vec4(s.rgb * w, w);
			}
		}

		return color;
	}

	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);
		ivec2 size = display_size();

		if (!on_screen(p, size)) return;

		vec4 interpolated_color = imageLoad(interpolated, p);

		if (interpolated_color.w <= FI_EPSILON) return;

		vec2 uv = (vec2(p) + 0.5) / vec2(size);
		vec4 sum = vec4(0.0);
		ivec2 mip_size = size;

		for (int mip = 0; mip < min(10, fi.color_pyramid_mips); mip++) {
			mip_size /= 2;
			vec4 c = inpainting_level(uv, mip, mip_size);

			if (c.w > 0.0) sum += vec4(c.rgb / c.w, 1.0) * pow(1.0 - float(mip) / 10.0, 3.0) * c.w;
		}

		vec3 inpainted = sum.w > 0.0 ? sum.rgb / sum.w : interpolated_color.rgb;
		imageStore(interpolated, p, vec4(mix(interpolated_color.rgb, inpainted, interpolated_color.w), 1.0));
	}
]]

local function storage_texture(name, width, height, format, mips)
	local texture = Texture.New{
		width = width,
		height = height,
		format = format,
		mip_map_levels = mips or 1,
		image = {
			usage = {"storage", "sampled", "transfer_dst"},
			properties = "device_local",
		},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			mipmap_mode = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	texture:SetDebugName("frame generation " .. name)
	return texture
end

local function pyramid(name, width, height)
	width, height = math.max(1, math.floor(width / 2)), math.max(1, math.floor(height / 2))
	local mips = 1

	while math.max(math.floor(width / 2 ^ mips), math.floor(height / 2 ^ mips)) >= 1 do
		mips = mips + 1
	end

	local texture = storage_texture(name, width, height, "r16g16b16a16_sfloat", mips)
	local views = {}

	for mip = 0, mips - 1 do
		views[mip + 1] = texture:GetImage():CreateView{
			format = "r16g16b16a16_sfloat",
			base_mip_level = mip,
			level_count = 1,
			aspect = "color",
		}
	end

	return texture, views
end

local function ensure_resources(scene)
	local render_size = render3d.GetRenderSize()
	local display = scene:GetSize()

	if
		resources.render_width == render_size.x and
		resources.render_height == render_size.y and
		resources.display_width == display.x and
		resources.display_height == display.y
	then
		return
	end

	render.GetDevice():WaitIdle()

	for _, value in pairs(resources) do
		if type(value) == "table" and value.Remove then value:Remove() end
	end

	table.clear(resources)
	local rw, rh, dw, dh = render_size.x, render_size.y, display.x, display.y
	resources.render_width, resources.render_height = rw, rh
	resources.display_width, resources.display_height = dw, dh
	resources.dilated_depth = storage_texture("dilated depth", rw, rh, "r32_sfloat")
	resources.dilated_motion = storage_texture("dilated motion", rw, rh, "r16g16_sfloat")
	resources.prev_depth = storage_texture("previous depth", rw, rh, "r32_uint")
	resources.interp_depth = storage_texture("interpolated depth", rw, rh, "r32_uint")
	resources.game_x = storage_texture("game field x", rw, rh, "r32_uint")
	resources.game_y = storage_texture("game field y", rw, rh, "r32_uint")
	resources.disocclusion = storage_texture("disocclusion", rw, rh, "r16g16_sfloat")
	resources.game_pyramid, resources.game_pyramid_views = pyramid("game pyramid", rw, rh)
	resources.interpolated = storage_texture("interpolated", dw, dh, "r16g16b16a16_sfloat")
	resources.color_pyramid, resources.color_pyramid_views = pyramid("color pyramid", dw, dh)
	resources.history = storage_texture("history", dw, dh, scene:GetFormat())
	state.history_valid = false
end

local function barrier(cmd)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
end

local function dispatch(cmd, name, slot, images, width, height)
	local pipeline = compute[name]

	for binding, image in ipairs(images) do
		pipeline:UpdateDescriptorSet("storage_image", slot, binding - 1, 0, image.GetView and image:GetView() or image)
	end

	pipeline:UploadConstants()
	pipeline.pipeline:DispatchForSize(cmd, width, height, 1, slot, pipeline.dynamic_offsets)
	barrier(cmd)
end

local function build_pyramid(cmd, name, slot, views, first_images)
	local images = {}

	for i, image in ipairs(first_images) do
		images[i] = image
	end

	for mip = 1, #views do
		state.mode = mip == 1 and 0 or 1
		state.mip = mip - 1
		images[#first_images + 1] = views[math.max(mip - 1, 1)]
		images[#first_images + 2] = views[mip]
		local width = math.max(1, math.floor(resources[name .. "_width"] / 2 ^ mip))
		local height = math.max(1, math.floor(resources[name .. "_height"] / 2 ^ mip))
		dispatch(cmd, name, slot + mip, images, width, height)
	end

	state.mode, state.mip = 0, 0
end

local function interpolate(cmd, scene)
	get_compute("clear", 5, CLEAR_DECLARATIONS, CLEAR_SHADER)
	get_compute("dilate", 3, DILATE_DECLARATIONS, DILATE_SHADER)
	get_compute("interp_depth", 3, INTERP_DEPTH_DECLARATIONS, INTERP_DEPTH_SHADER)
	get_compute("game_field", 4, GAME_FIELD_DECLARATIONS, GAME_FIELD_SHADER)
	get_compute("game_pyramid", 4, GAME_PYRAMID_DECLARATIONS, GAME_PYRAMID_SHADER)
	get_compute("disocclusion", 6, DISOCCLUSION_DECLARATIONS, DISOCCLUSION_SHADER)
	get_compute("interpolation", 3, INTERPOLATION_DECLARATIONS, INTERPOLATION_SHADER)
	get_compute("color_pyramid", 3, COLOR_PYRAMID_DECLARATIONS, COLOR_PYRAMID_SHADER)
	get_compute("inpainting", 1, INPAINTING_DECLARATIONS, INPAINTING_SHADER)
	local r = resources
	local base = ((render.GetCurrentFrame() or 1) - 1) % MAX_FRAMES * SLOTS_PER_FRAME + 1
	local rw, rh, dw, dh = r.render_width, r.render_height, r.display_width, r.display_height
	r.game_pyramid_width, r.game_pyramid_height = rw, rh
	r.color_pyramid_width, r.color_pyramid_height = dw, dh

	for _, texture in ipairs{
		r.dilated_depth,
		r.dilated_motion,
		r.prev_depth,
		r.interp_depth,
		r.game_x,
		r.game_y,
		r.disocclusion,
		r.game_pyramid,
		r.interpolated,
		r.color_pyramid,
	} do
		render.TransitionResourceToComputeStorage(texture, {cmd = cmd, srcStage = "all_commands", srcAccess = "memory_read"})
	end

	render.TransitionResourceToShaderRead(scene, {cmd = cmd, srcStage = "all_commands"})
	render.TransitionResourceToShaderRead(r.history, {cmd = cmd, srcStage = "all_commands"})
	render.TransitionResourceToShaderRead(gbuffer_layout.GetDepthTexture(), {cmd = cmd, srcStage = "all_commands"})

	if render3d.velocity_enabled:Get() then
		render.TransitionResourceToShaderRead(gbuffer_layout.GetTexture("velocity"), {cmd = cmd, srcStage = "all_commands"})
	end

	state.mode, state.mip = 0, 0
	dispatch(
		cmd,
		"clear",
		base,
		{r.prev_depth, r.interp_depth, r.game_x, r.game_y, r.disocclusion},
		rw,
		rh
	)
	dispatch(cmd, "dilate", base, {r.dilated_depth, r.dilated_motion, r.prev_depth}, rw, rh)
	dispatch(
		cmd,
		"interp_depth",
		base,
		{r.dilated_depth, r.dilated_motion, r.interp_depth},
		rw,
		rh
	)
	dispatch(
		cmd,
		"game_field",
		base,
		{r.dilated_depth, r.dilated_motion, r.game_x, r.game_y},
		rw,
		rh
	)
	build_pyramid(cmd, "game_pyramid", base, r.game_pyramid_views, {r.game_x, r.game_y})
	-- the pyramid is read through the bindless set, whose descriptors expect a shader read layout
	render.TransitionResourceToShaderRead(r.game_pyramid, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
	dispatch(
		cmd,
		"disocclusion",
		base,
		{
			r.dilated_depth,
			r.prev_depth,
			r.interp_depth,
			r.game_x,
			r.game_y,
			r.disocclusion,
		},
		rw,
		rh
	)
	render.TransitionResourceToShaderRead(r.disocclusion, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
	dispatch(cmd, "interpolation", base, {r.game_x, r.game_y, r.interpolated}, dw, dh)
	build_pyramid(cmd, "color_pyramid", base + 16, r.color_pyramid_views, {r.interpolated})
	render.TransitionResourceToShaderRead(r.color_pyramid, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
	dispatch(cmd, "inpainting", base, {r.interpolated}, dw, dh)
	render.TransitionResourceToShaderRead(r.interpolated, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
end

local function get_compose_pipeline(format)
	if compose_pipelines[format] then return compose_pipelines[format] end

	compose_pipelines[format] = EasyPipeline.New{
		name = "frame_generation_compose",
		dont_create_framebuffers = true,
		ColorFormat = {{format, {"color", "rgba"}}},
		RasterizationSamples = "1",
		Blend = false,
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		fragment = {
			push_constants = {
				{
					name = "compose_data",
					block = {
						{"scene_tex", "int"},
						{"ui_tex", "int"},
					},
					write = function(self, block)
						block.scene_tex = self:GetTextureIndex(state.compose_source)
						block.ui_tex = self:GetTextureIndex(state.ui)
						return block
					end,
				},
			},
			shader = [[
				void main() {
					ivec2 pixel = ivec2(gl_FragCoord.xy);
					vec3 scene = texelFetch(TEXTURE(compose_data.scene_tex), pixel, 0).rgb;
					vec4 ui = texelFetch(TEXTURE(compose_data.ui_tex), pixel, 0);
					set_color(vec4(scene * (1.0 - ui.a) + ui.rgb, 1.0));
				}
			]],
		},
	}
	return compose_pipelines[format]
end

local function compose(cmd, target, source)
	local size = target:GetSize()
	state.compose_source = source
	render.TransitionResourceTo(
		target:GetImage(),
		"color_attachment_optimal",
		{
			cmd = cmd,
			srcStage = "all_commands",
			srcAccess = "none",
			dstStage = "color_attachment_output",
			dstAccess = "color_attachment_write",
		}
	)
	cmd:BeginRendering{
		color_image_view = target:GetView(),
		w = size.x,
		h = size.y,
		load_op = "dont_care",
	}
	get_compose_pipeline(target:GetFormat()):Draw(cmd)
	cmd:EndRendering()
end

function frame_generation.Compose(cmd, ui, generated, real)
	local scene = render3d.pipelines.blit_compute:GetFramebuffer():GetAttachment(1)
	ensure_resources(scene)
	state.scene = scene
	state.ui = ui
	local present_generated = state.history_valid and not state.camera_cut

	if present_generated then
		state.frames_since_reset = state.frames_since_reset + 1
	else
		state.frames_since_reset = 0
	end

	if present_generated then
		gpu_timing.BeginScope(cmd, "frame_generation")
		interpolate(cmd, scene)
		gpu_timing.EndScope(cmd, "frame_generation")
	end

	render.TransitionResourceToShaderRead(scene, {cmd = cmd, srcStage = "all_commands"})
	render.TransitionResourceToShaderRead(ui, {cmd = cmd, srcStage = "color_attachment_output"})

	if present_generated then compose(cmd, generated, resources.interpolated) end

	compose(cmd, real, scene)
	render.TransitionResourceTo(
		scene:GetImage(),
		"transfer_src_optimal",
		{cmd = cmd, srcStage = "all_commands", dstStage = "transfer"}
	)
	render.TransitionResourceTo(
		resources.history:GetImage(),
		"transfer_dst_optimal",
		{cmd = cmd, srcStage = "all_commands", dstStage = "transfer"}
	)
	local size = scene:GetSize()
	cmd:CopyImageToImage{
		src_image = scene:GetImage(),
		dst_image = resources.history:GetImage(),
		width = size.x,
		height = size.y,
	}
	state.history_valid = true
	state.scene = nil
	state.ui = nil
	return present_generated
end

-- the frame's matrices, taken before render3d replaces its previous camera with this frame's at the end of Draw
event.AddListener("PreRenderPass", "frame_generation", function()
	if not render.target:GetFramePacer() or not render3d.IsReady() then return end

	local camera = render3d.GetCamera()
	local projection = camera:BuildProjectionMatrix()
	local inverse_projection = projection:GetInverse(state.inv_projection)
	local clip_to_world = inverse_projection:GetMultiplied(camera:BuildViewMatrix():GetInverse())
	local previous = render3d.GetPreviousViewMatrix():GetMultiplied(render3d.GetPreviousProjectionMatrix())
	clip_to_world:GetMultiplied(previous, state.reproject)
	state.view_scale = camera:GetScale()
	local tan_y = math.tan(camera:GetFOV() / 2)
	local viewport = camera:GetViewport()
	local tan_x = tan_y * viewport.w / viewport.h
	state.kfov = math.sqrt(1 + tan_x * tan_x + tan_y * tan_y)
	state.camera_cut = render3d.IsCameraCut()
end)

-- the last generated frame and the two rendered frames it sits between, before the ui is composited
function frame_generation.GetDebugTextures()
	return resources.history, resources.interpolated
end

function frame_generation.IsEnabled()
	return render.target:GetFramePacer() ~= nil
end

pvars.StartGroup("Rendering", "Frame generation", {store = false})
local enabled = pvars.Setup2{
	key = "r_frame_generation",
	default = false,
	help = "present a frame generated between every two rendered ones (fsr3's frame interpolation), paced to the middle of the rendered frame time by a present thread, which doubles the presented frame rate at the cost of half a rendered frame of latency. the 2d ui is drawn once per rendered frame on its own layer and composited over both",
	callback = function(value)
		if not render3d.IsReady() then return end

		state.history_valid = false
		render.target:SetFrameGeneration(value and frame_generation.Compose or nil)
	end,
}
pvars.EndGroup()

event.AddListener("Render3DInitialized", "frame_generation", function()
	if enabled:Get() then
		render.target:SetFrameGeneration(frame_generation.Compose)
	end
end)

return frame_generation
