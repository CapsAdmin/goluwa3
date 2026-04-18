local ffi = require("ffi")
local utility = import("goluwa/utility.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local render = import("goluwa/render/render.lua")
local event = import("goluwa/event.lua")
local VertexBuffer = import("goluwa/render/vertex_buffer.lua")
local Mesh = import("goluwa/render/mesh.lua")
local Texture = import("goluwa/render/texture.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local FragmentConstants = ffi.typeof([[
	struct {
        float global_color[4];          
        float alpha_multiplier;  
        int texture_index;       
        float uv_offset[2];             
        float uv_scale[2];              
		int sample_uv_mode;
        int swizzle_mode;
        float blur[2];
        float border_radius[4];
        float outline_width;
        float rect_size[2];
        float sdf_threshold;
		float sdf_texel_range;
        int gradient_texture_index;
        int nine_patch_x_count;
        int nine_patch_y_count;
        float nine_patch_x_stretch[6];
        float nine_patch_y_stretch[6];
        float sdf_rect_size[2];
        int subpixel_mode;
        float subpixel_amount;
	}
]])
local fragment_constants = FragmentConstants()
local render2d = library()
local current_w, current_h = 0, 0
local current_lw, current_lh = 0, 0
local DEFAULT_BLEND_MODE = "alpha"
local DEFAULT_COLOR_WRITE_MASK = {"r", "g", "b", "a"}
local DEFAULT_DEPTH_MODE = "none"
local depth_mode_to_compare_op = {
	less = "less",
	lequal = "less_or_equal",
	equal = "equal",
	gequal = "greater_or_equal",
	greater = "greater",
	notequal = "not_equal",
	always = "always",
}

local function get_active_pipeline()
	return render2d.shader_override or render2d.pipeline
end

local function copy_array(tbl)
	if not tbl then return nil end

	local out = {}

	for i, v in ipairs(tbl) do
		out[i] = v
	end

	return out
end

local function get_valid_blend_mode_error(mode_name)
	local valid_modes = {}

	for k in pairs(render2d.blend_modes) do
		table.insert(valid_modes, k)
	end

	table.sort(valid_modes)
	return "Invalid blend mode: " .. tostring(mode_name) .. ". Valid modes: " .. table.concat(valid_modes, ", ")
end

local function normalize_blend_mode_state(state)
	local blend = state.blend

	if blend == nil then
		blend = state.src_color_blend_factor ~= nil or
			state.dst_color_blend_factor ~= nil or
			state.color_blend_op ~= nil or
			state.src_alpha_blend_factor ~= nil or
			state.dst_alpha_blend_factor ~= nil or
			state.alpha_blend_op ~= nil
	end

	return {
		blend = blend == true,
		src_color_blend_factor = state.src_color_blend_factor or "one",
		dst_color_blend_factor = state.dst_color_blend_factor or "zero",
		color_blend_op = state.color_blend_op or "add",
		src_alpha_blend_factor = state.src_alpha_blend_factor or "one",
		dst_alpha_blend_factor = state.dst_alpha_blend_factor or "zero",
		alpha_blend_op = state.alpha_blend_op or "add",
		color_write_mask = copy_array(state.color_write_mask or DEFAULT_COLOR_WRITE_MASK),
	}
end

local function get_blend_mode_state(mode)
	mode = mode or DEFAULT_BLEND_MODE

	if type(mode) == "table" then return normalize_blend_mode_state(mode) end

	local preset = render2d.blend_modes[mode]

	if not preset then error(get_valid_blend_mode_error(mode), 3) end

	return normalize_blend_mode_state(preset)
end

local function clone_blend_mode(mode)
	if type(mode) == "table" then return normalize_blend_mode_state(mode) end

	return mode
end

local function apply_blend_mode_state(pipeline, blend_mode, stencil_mode)
	pipeline:SetBlend(blend_mode.blend)
	pipeline:SetSrcColorBlendFactor(blend_mode.src_color_blend_factor)
	pipeline:SetDstColorBlendFactor(blend_mode.dst_color_blend_factor)
	pipeline:SetColorBlendOp(blend_mode.color_blend_op)
	pipeline:SetSrcAlphaBlendFactor(blend_mode.src_alpha_blend_factor)
	pipeline:SetDstAlphaBlendFactor(blend_mode.dst_alpha_blend_factor)
	pipeline:SetAlphaBlendOp(blend_mode.alpha_blend_op)
	pipeline:SetColorWriteMask(stencil_mode.color_write_mask or blend_mode.color_write_mask)
end

local function apply_stencil_state(pipeline, stencil_mode, stencil_ref)
	pipeline:SetStencilTest(stencil_mode.stencil_test)
	pipeline:SetFrontStencilFailOp(stencil_mode.front.fail_op)
	pipeline:SetFrontStencilPassOp(stencil_mode.front.pass_op)
	pipeline:SetFrontStencilDepthFailOp(stencil_mode.front.depth_fail_op)
	pipeline:SetFrontStencilCompareOp(stencil_mode.front.compare_op)
	pipeline:SetFrontStencilReference(stencil_ref)
	pipeline:SetFrontStencilCompareMask(0xFF)
	pipeline:SetFrontStencilWriteMask(0xFF)
	pipeline:SetBackStencilFailOp(stencil_mode.front.fail_op)
	pipeline:SetBackStencilPassOp(stencil_mode.front.pass_op)
	pipeline:SetBackStencilDepthFailOp(stencil_mode.front.depth_fail_op)
	pipeline:SetBackStencilCompareOp(stencil_mode.front.compare_op)
	pipeline:SetBackStencilReference(stencil_ref)
	pipeline:SetBackStencilCompareMask(0xFF)
	pipeline:SetBackStencilWriteMask(0xFF)
end

local function mark_pipeline_state_dirty()
	render2d.pipeline_state_dirty = true
end

local function sync_pipeline_state(force)
	local pipeline = get_active_pipeline()

	if not pipeline then return end

	if
		not force and
		not render2d.pipeline_state_dirty and
		render2d.synced_pipeline == pipeline
	then
		return
	end

	local blend_mode = render2d.current_blend_mode_state or
		get_blend_mode_state(render2d.current_blend_mode)
	local depth_mode_name, depth_write = render2d.GetDepthMode()
	depth_mode_name = depth_mode_name or DEFAULT_DEPTH_MODE
	depth_write = not not depth_write
	local stencil_mode_name, stencil_ref = render2d.GetStencilMode()
	stencil_mode_name = stencil_mode_name or "none"
	stencil_ref = stencil_ref or 1
	local stencil_mode = render2d.stencil_modes[stencil_mode_name]
	local depth_compare_op = depth_mode_to_compare_op[depth_mode_name] or "always"
	local cmd = render.GetCommandBuffer()
	apply_blend_mode_state(pipeline, blend_mode, stencil_mode)
	pipeline:SetDepthTest(depth_mode_name ~= DEFAULT_DEPTH_MODE)
	pipeline:SetDepthWrite(depth_write)
	pipeline:SetDepthCompareOp(depth_compare_op)
	apply_stencil_state(pipeline, stencil_mode, stencil_ref)
	pipeline:Bind(cmd, render.GetCurrentFrame())
	render2d.pipeline_state_dirty = false
	render2d.synced_pipeline = pipeline
end

-- Blend mode presets
render2d.blend_modes = {
	alpha = {
		blend = true,
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one_minus_src_alpha",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	additive = {
		blend = true,
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "one",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	multiply = {
		blend = true,
		src_color_blend_factor = "dst_color",
		dst_color_blend_factor = "zero",
		color_blend_op = "add",
		src_alpha_blend_factor = "dst_alpha",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	premultiplied = {
		blend = true,
		src_color_blend_factor = "one",
		dst_color_blend_factor = "one_minus_src_alpha",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "one_minus_src_alpha",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	screen = {
		blend = true,
		src_color_blend_factor = "one",
		dst_color_blend_factor = "one_minus_src_color",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "one_minus_src_alpha",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	subtract = {
		blend = true,
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one",
		color_blend_op = "reverse_subtract",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "one",
		alpha_blend_op = "reverse_subtract",
		color_write_mask = {"r", "g", "b", "a"},
	},
	none = {
		blend = false,
		src_color_blend_factor = "one",
		dst_color_blend_factor = "zero",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
}

function render2d.Initialize()
	if render2d.pipeline then return end

	local config = {
		name = "render2d",
		dont_create_framebuffers = true,
		RasterizationSamples = render.target:GetSamples(),
		ColorFormat = render.target:GetColorFormat(),
		vertex = {
			uniform_buffers = {
				{
					block = {
						{
							"projection_view_world",
							"mat4",
							function(self, block, key)
								render2d.GetMatrix():CopyToFloatPointer(block[key])
							end,
						},
					},
				},
			},
			attributes = {
				{"pos", "vec3", "r32g32b32_sfloat"},
				{"uv", "vec2", "r32g32_sfloat"},
				{"sample_uv", "vec2", "r32g32_sfloat"},
				{"color", "vec4", "r32g32b32a32_sfloat"},
			},
			shader = [[
				void main() {
					gl_Position = U.projection_view_world * vec4(in_pos, 1.0);
					out_uv = in_uv;
					out_sample_uv = in_sample_uv;
					out_color = in_color;
				}
			]],
		},
		fragment = {
			uniform_buffers = {
				{
					block = {
						{
							"global_color",
							"vec4",
							function(self, block, key)
								ffi.copy(block[key], fragment_constants.global_color, 16)
							end,
						},
						{
							"alpha_multiplier",
							"float",
							function(self, block, key)
								block[key] = fragment_constants.alpha_multiplier
							end,
						},
						{
							"texture_index",
							"int",
							function(self, block, key)
								block[key] = render2d.current_texture and self:GetTextureIndex(render2d.current_texture) or -1
							end,
						},
						{
							"uv_offset",
							"vec2",
							function(self, block, key)
								ffi.copy(block[key], fragment_constants.uv_offset, 8)
							end,
						},
						{
							"uv_scale",
							"vec2",
							function(self, block, key)
								ffi.copy(block[key], fragment_constants.uv_scale, 8)
							end,
						},
						{
							"sample_uv_mode",
							"int",
							function(self, block, key)
								block[key] = fragment_constants.sample_uv_mode
							end,
						},
						{
							"swizzle_mode",
							"int",
							function(self, block, key)
								block[key] = fragment_constants.swizzle_mode
							end,
						},
						{
							"blur",
							"vec2",
							function(self, block, key)
								ffi.copy(block[key], fragment_constants.blur, 8)
							end,
						},
						{
							"border_radius",
							"vec4",
							function(self, block, key)
								ffi.copy(block[key], fragment_constants.border_radius, 16)
							end,
						},
						{
							"outline_width",
							"float",
							function(self, block, key)
								block[key] = fragment_constants.outline_width
							end,
						},
						{
							"rect_size",
							"vec2",
							function(self, block, key)
								block[key][0] = current_w
								block[key][1] = current_h
							end,
						},
						{
							"sdf_threshold",
							"float",
							function(self, block, key)
								block[key] = fragment_constants.sdf_threshold
							end,
						},
						{
							"sdf_texel_range",
							"float",
							function(self, block, key)
								block[key] = fragment_constants.sdf_texel_range
							end,
						},
						{
							"gradient_texture_index",
							"int",
							function(self, block, key)
								block[key] = render2d.current_gradient_texture and
									self:GetTextureIndex(render2d.current_gradient_texture) or
									-1
							end,
						},
						{
							"nine_patch_x_count",
							"int",
							function(self, block, key)
								block[key] = fragment_constants.nine_patch_x_count
							end,
						},
						{
							"nine_patch_y_count",
							"int",
							function(self, block, key)
								block[key] = fragment_constants.nine_patch_y_count
							end,
						},
						{
							"nine_patch_x_stretch",
							"float",
							function(self, block, key)
								ffi.copy(block[key], fragment_constants.nine_patch_x_stretch, 4 * 6)
							end,
							6,
						},
						{
							"nine_patch_y_stretch",
							"float",
							function(self, block, key)
								ffi.copy(block[key], fragment_constants.nine_patch_y_stretch, 4 * 6)
							end,
							6,
						},
						{
							"sdf_rect_size",
							"vec2",
							function(self, block, key)
								block[key][0] = current_lw
								block[key][1] = current_lh
							end,
						},
						{
							"subpixel_mode",
							"int",
							function(self, block, key)
								block[key] = fragment_constants.subpixel_mode
							end,
						},
						{
							"subpixel_amount",
							"float",
							function(self, block, key)
								block[key] = fragment_constants.subpixel_amount
							end,
						},
					},
				},
			},
			shader = [[
				float map_nine_patch(float x, float tw, float sw, float stretch[6], int count) 
				{
					if (count == 0 || tw <= 0.0 || sw <= 0.0) return x / sw;
					
					float fixed_total = sw;
					float stretch_total_src = 0.0;
					for (int i = 0; i < 3; i++) {
						if (i >= count) break;
						float s = stretch[i*2];
						float e = stretch[i*2+1];
						stretch_total_src += (e - s);
					}
					fixed_total -= stretch_total_src;
					
					float stretch_total_tgt = max(0.0, tw - fixed_total);
					float k = (stretch_total_src > 0.0) ? (stretch_total_tgt / stretch_total_src) : 0.0;
					
					float curr_src = 0.0;
					float curr_tgt = 0.0;
					
					for (int i = 0; i < 3; i++) {
						if (i >= count) break;
						float s = stretch[i*2];
						float e = stretch[i*2+1];
						
						float fixed_size = s - curr_src;
						if (x < curr_tgt + fixed_size) {
							return (curr_src + (x - curr_tgt)) / sw;
						}
						curr_src += fixed_size;
						curr_tgt += fixed_size;
						
						float stretch_size_src = e - s;
						float stretch_size_tgt = stretch_size_src * k;
						if (x < curr_tgt + stretch_size_tgt) {
							float ratio = (k > 0.0) ? ((x - curr_tgt) / k) : 0.0;
							return (curr_src + ratio) / sw;
						}
						curr_src += stretch_size_src;
						curr_tgt += stretch_size_tgt;
					}
					
					return (curr_src + (x - curr_tgt)) / sw;
				}

				float sd_rect(vec2 coords, vec2 quad_size, vec2 logical_size, vec4 radius) {
					vec2 p = (coords - 0.5) * quad_size;
					vec2 b = logical_size * 0.5;
					float rad;
					if (p.x < 0.0 && p.y < 0.0) rad = radius.x;
					else if (p.x > 0.0 && p.y < 0.0) rad = radius.y;
					else if (p.x > 0.0 && p.y > 0.0) rad = radius.z;
					else rad = radius.w;

					float min_dim = min(logical_size.x, logical_size.y);
					float half_dim = min_dim * 0.5;
					float inset = min(rad, half_dim);
					vec2 q = abs(p) - b + inset;

					if (q.x <= 0.0 || q.y <= 0.0) {
						return max(q.x, q.y) - inset;
					} else {
						if (inset < 0.001) return length(q);
						float norm_rad = rad / max(half_dim, 0.0001);
						float exp_p = clamp(2.0 / norm_rad, 0.1, 200.0);
						vec2 np = q / inset;
						float lp = pow(pow(np.x, exp_p) + pow(np.y, exp_p), 1.0 / exp_p);
						return (lp - 1.0) * inset;
					}
				}

				float sample_tex_sdf_raw(int texture_index, vec2 sdf_uv) {
					return texture(TEXTURE(texture_index), sdf_uv).r;
				}

				float tex_sdf_screen_px_range(int texture_index, vec2 sdf_uv, float sdf_texel_range) {
					vec2 tex_size = vec2(textureSize(TEXTURE(texture_index), 0));
					vec2 uv_dx = dFdx(sdf_uv);
					vec2 uv_dy = dFdy(sdf_uv);
					vec2 screen_tex_size = vec2(1.0) / max(abs(uv_dx) + abs(uv_dy), vec2(0.0001));
					vec2 unit_range = vec2(max(sdf_texel_range, 1.0)) / max(tex_size, vec2(1.0));
					return max(0.5 * dot(unit_range, screen_tex_size)*1.5, 1.0);
				}

				float sample_tex_sdf_filtered(int texture_index, vec2 sdf_uv) {
					vec2 uv_dx = dFdx(sdf_uv);
					vec2 uv_dy = dFdy(sdf_uv);
					float center = sample_tex_sdf_raw(texture_index, sdf_uv);
					float sx0 = sample_tex_sdf_raw(texture_index, sdf_uv - uv_dx * 0.25);
					float sx1 = sample_tex_sdf_raw(texture_index, sdf_uv + uv_dx * 0.25);
					float sy0 = sample_tex_sdf_raw(texture_index, sdf_uv - uv_dy * 0.25);
					float sy1 = sample_tex_sdf_raw(texture_index, sdf_uv + uv_dy * 0.25);
					return center * 0.7 + (sx0 + sx1 + sy0 + sy1) * 0.075;
				}

				float tex_sdf_distance(int texture_index, float sdf_threshold, float sdf_texel_range, vec2 sdf_uv) {
					float dist = sample_tex_sdf_filtered(texture_index, sdf_uv);
					return (sdf_threshold - dist) * tex_sdf_screen_px_range(texture_index, sdf_uv, sdf_texel_range);
				}

				bool has_rect_sdf_enabled() {
					return U.sdf_rect_size.x > 0.0 && U.sdf_rect_size.y > 0.0;
				}

				bool has_texture_sdf_enabled() {
					return U.texture_index >= 0 && U.swizzle_mode == 10;
				}

				vec4 apply_swizzle(vec4 tex) {
					if (U.swizzle_mode == 1) return vec4(tex.rrr, 1.0);
					if (U.swizzle_mode == 2) return vec4(tex.ggg, 1.0);
					if (U.swizzle_mode == 3) return vec4(tex.bbb, 1.0);
					if (U.swizzle_mode == 4) return vec4(tex.aaa, 1.0);
					if (U.swizzle_mode == 5) return vec4(tex.rgb, 1.0);
					return tex;
				}

				vec2 resolve_fragment_uv(vec2 coords) {
					vec2 uv = coords;

					if (U.texture_index >= 0 && (U.nine_patch_x_count > 0 || U.nine_patch_y_count > 0)) {
						vec2 tex_size = vec2(textureSize(TEXTURE(U.texture_index), 0));
						vec2 p_logical = (coords - 0.5) * U.rect_size + U.sdf_rect_size * 0.5;

						if (U.nine_patch_x_count > 0) {
							uv.x = map_nine_patch(p_logical.x, U.sdf_rect_size.x, tex_size.x, U.nine_patch_x_stretch, U.nine_patch_x_count);
						}

						if (U.nine_patch_y_count > 0) {
							uv.y = map_nine_patch(p_logical.y, U.sdf_rect_size.y, tex_size.y, U.nine_patch_y_stretch, U.nine_patch_y_count);
						}
					}

					return uv;
				}

				vec4 sample_fragment_color(vec2 uv, bool is_sdf_tex) {
					vec4 color = in_color * U.global_color;

					if (U.texture_index >= 0 && !is_sdf_tex) {
						vec4 tex = texture(TEXTURE(U.texture_index), uv * U.uv_scale + U.uv_offset);
						color *= apply_swizzle(tex);
					}

					return color;
				}

				float compute_fragment_distance(vec2 coords, vec2 uv, bool has_rect_sdf, bool has_tex_sdf) {
					float d = 1e10;

					if (has_rect_sdf) {
						d = sd_rect(coords, U.rect_size, U.sdf_rect_size, U.border_radius);
					}

					if (has_tex_sdf) {
						bool use_direct_sample_uv = (U.sample_uv_mode & 1) != 0;
						bool invert_tex_sdf = (U.sample_uv_mode & 2) != 0;
						vec2 sdf_uv = use_direct_sample_uv ? in_sample_uv : (in_sample_uv * U.uv_scale + U.uv_offset);
						float d_tex = tex_sdf_distance(U.texture_index, U.sdf_threshold, U.sdf_texel_range, sdf_uv);

						if (invert_tex_sdf) d_tex = -d_tex;

						d = has_rect_sdf ? max(d, d_tex) : d_tex;
					}

					return d;
				}

				vec4 apply_fragment_gradient(vec2 coords, vec4 color) {
					if (U.gradient_texture_index >= 0) {
						float gy = coords.y;

						if (U.sdf_rect_size.y > 0.0) {
							gy = (coords.y - 0.5) * (U.rect_size.y / U.sdf_rect_size.y) + 0.5;
						}

						gy = clamp(gy, 0.0, 1.0);
						color *= texture(TEXTURE(U.gradient_texture_index), vec2(gy, 0.5));
					}

					return color;
				}

				float compute_sdf_alpha(float d, bool has_tex_sdf, bool has_rect_sdf) {
					if (has_tex_sdf && !has_rect_sdf) {
						float bias = -0.015;
						float gamma = 1.1;
						float softness = max(1.0, max(U.blur.x, U.blur.y) * 1.75);
						float alpha = (U.outline_width > 0.0) ?
							(clamp((d + bias) / softness + 0.5, 0.0, 1.0) - clamp(((d + U.outline_width) + bias) / softness + 0.5, 0.0, 1.0)) :
							clamp((d + bias) / softness + 0.5, 0.0, 1.0);
						return pow(max(alpha, 0.0), gamma);
					}

					float smoothing = max(U.blur.x, U.blur.y);
					smoothing = max(0.75, smoothing);
					return (U.outline_width > 0.0) ?
						(smoothstep(smoothing, -smoothing, d) - smoothstep(smoothing, -smoothing, d + U.outline_width)) :
						smoothstep(smoothing, -smoothing, d);
				}

				vec3 compute_sdf_alpha(vec3 d, bool has_tex_sdf, bool has_rect_sdf) {
					if (has_tex_sdf && !has_rect_sdf) {
						float bias = -0.015;
						float gamma = 1.1;
						float softness = max(1.0, max(U.blur.x, U.blur.y) * 1.75);
						vec3 alpha = (U.outline_width > 0.0) ?
							(clamp((d + bias) / softness + 0.5, 0.0, 1.0) - clamp(((d + U.outline_width) + bias) / softness + 0.5, 0.0, 1.0)) :
							clamp((d + bias) / softness + 0.5, 0.0, 1.0);
						return pow(max(alpha, vec3(0.0)), vec3(gamma));
					}

					float smoothing = max(U.blur.x, U.blur.y);
					smoothing = max(0.7, smoothing);
					return (U.outline_width > 0.0) ?
						(smoothstep(smoothing, -smoothing, d) - smoothstep(smoothing, -smoothing, d + U.outline_width)) :
						smoothstep(smoothing, -smoothing, d);
				}

				float compute_blur_alpha(vec2 coords) {
					vec2 p = (coords - 0.5) * U.rect_size;
					vec2 b = max(vec2(0.0), (U.rect_size - U.blur * 2.0) * 0.5);
					vec2 q = abs(p) - b;
					float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
					float max_blur = max(U.blur.x, U.blur.y);
					return smoothstep(max_blur, 0.0, dist);
				}

				vec4 shade_fragment(vec2 coords, out vec4 color, out float d) {
					bool has_rect_sdf = has_rect_sdf_enabled();
					bool has_tex_sdf = has_texture_sdf_enabled();
					bool has_sdf = has_rect_sdf || has_tex_sdf;
					vec2 uv = resolve_fragment_uv(coords);
					color = sample_fragment_color(uv, has_tex_sdf);
					d = compute_fragment_distance(coords, uv, has_rect_sdf, has_tex_sdf);
					vec4 shaded = color;

					if (has_sdf) {
						shaded = apply_fragment_gradient(coords, color);
						shaded.a *= compute_sdf_alpha(d, has_tex_sdf, has_rect_sdf);
					}

					if ((U.blur.x > 0.0 || U.blur.y > 0.0) && U.sdf_rect_size.x <= 0.0) {
						shaded.a *= compute_blur_alpha(coords);
					}

					shaded.a *= U.alpha_multiplier;
					return shaded;
				}

				void main() 
				{
					bool has_rect_sdf = has_rect_sdf_enabled();
					bool has_tex_sdf = has_texture_sdf_enabled();
					bool has_sdf = has_rect_sdf || has_tex_sdf;
					vec4 color;
					float d;
					out_color = shade_fragment(in_uv, color, d);

					if (U.subpixel_mode != 0 && has_sdf) {
						vec3 sub_d = vec3(d);
						vec4 sample_color;
						float sample_d;
						float shift = U.subpixel_amount;

						if (U.subpixel_mode == 1 || U.subpixel_mode == 2) {
							shade_fragment(in_uv + vec2(-shift, 0.0), sample_color, sample_d);
							sub_d.x = sample_d;
							shade_fragment(in_uv + vec2(shift, 0.0), sample_color, sample_d);
							sub_d.z = sample_d;

							if (U.subpixel_mode == 2) sub_d = sub_d.zyx;
						} else if (U.subpixel_mode == 3 || U.subpixel_mode == 4) {
							shade_fragment(in_uv + vec2(0.0, -shift), sample_color, sample_d);
							sub_d.x = sample_d;
							shade_fragment(in_uv + vec2(0.0, shift), sample_color, sample_d);
							sub_d.z = sample_d;

							if (U.subpixel_mode == 4) sub_d = sub_d.zyx;
						} else if (U.subpixel_mode == 5) {
							float d0;
							float d1;
							float d2;
							float d3;
							shade_fragment(in_uv + vec2(-1.5 * shift, 0.0), sample_color, d0);
							shade_fragment(in_uv + vec2(-0.5 * shift, 0.0), sample_color, d1);
							shade_fragment(in_uv + vec2(0.5 * shift, 0.0), sample_color, d2);
							shade_fragment(in_uv + vec2(1.5 * shift, 0.0), sample_color, d3);
							sub_d = mix(vec3(d0, d2, d3), vec3(d1), 0.5);
						}

						vec3 sub_alpha = compute_sdf_alpha(sub_d, has_tex_sdf, has_rect_sdf);

						if (dot(color.rgb, vec3(1.0)) < 0.5) {
							out_color.rgb = vec3(1.0) - sub_alpha * (vec3(1.0) - color.rgb);
							out_color.a = 1.0;
						} else {
							out_color.rgb = color.rgb * sub_alpha;
							out_color.a = color.a * max(max(sub_alpha.r, sub_alpha.g), sub_alpha.b);
						}
					}
				}
			]],
		},
		CullMode = "none",
		Blend = true,
		SrcColorBlendFactor = "src_alpha",
		DstColorBlendFactor = "one_minus_src_alpha",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "zero",
		AlphaBlendOp = "add",
		ColorWriteMask = {"r", "g", "b", "a"},
		DepthTest = false,
		DepthWrite = true,
		StencilTest = false,
		FrontStencilFailOp = "keep",
		FrontStencilPassOp = "keep",
		FrontStencilDepthFailOp = "keep",
		FrontStencilCompareOp = "always",
		BackStencilFailOp = "keep",
		BackStencilPassOp = "keep",
		BackStencilDepthFailOp = "keep",
		BackStencilCompareOp = "always",
	}
	render2d.pipeline = EasyPipeline.New(config)

	render2d.pipeline:SetTextureSamplerConfigResolver(function()
		return render.GetSamplerFilterConfig()
	end)

	render2d.ResetState()
	render2d.rect_mesh = render2d.CreateMesh(
		{
			{
				pos = Vec3(0, 1, 0),
				uv = Vec2(0, 0),
				sample_uv = Vec2(0, 0),
				color = Color(1, 1, 1, 1),
			},
			{
				pos = Vec3(0, 0, 0),
				uv = Vec2(0, 1),
				sample_uv = Vec2(0, 1),
				color = Color(1, 1, 1, 1),
			},
			{
				pos = Vec3(1, 1, 0),
				uv = Vec2(1, 0),
				sample_uv = Vec2(1, 0),
				color = Color(1, 1, 1, 1),
			},
			{
				pos = Vec3(1, 0, 0),
				uv = Vec2(1, 1),
				sample_uv = Vec2(1, 1),
				color = Color(1, 1, 1, 1),
			},
		},
		{0, 1, 2, 2, 1, 3}
	)
	render2d.triangle_mesh = render2d.CreateMesh{
		{
			pos = Vec3(-0.5, -0.5, 0),
			uv = Vec2(0, 0),
			sample_uv = Vec2(0, 0),
			color = Color(1, 1, 1, 1),
		},
		{
			pos = Vec3(0.5, 0.5, 0),
			uv = Vec2(1, 1),
			sample_uv = Vec2(1, 1),
			color = Color(1, 1, 1, 1),
		},
		{
			pos = Vec3(-0.5, 0.5, 0),
			uv = Vec2(0, 1),
			sample_uv = Vec2(0, 1),
			color = Color(1, 1, 1, 1),
		},
	}
end

function render2d.ResetState()
	render2d.SetTexture()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(1)
	render2d.SetUV()
	render2d.SetSwizzleMode(0)
	render2d.SetBlur(0)
	render2d.SetBorderRadius(0, 0, 0, 0)
	render2d.SetOutlineWidth(0)
	fragment_constants.sample_uv_mode = 0
	fragment_constants.sdf_threshold = 0
	fragment_constants.sdf_texel_range = 1
	fragment_constants.gradient_texture_index = -1
	fragment_constants.nine_patch_x_count = 0
	fragment_constants.nine_patch_y_count = 0

	for i = 0, 5 do
		fragment_constants.nine_patch_x_stretch[i] = 0
		fragment_constants.nine_patch_y_stretch[i] = 0
	end

	render2d.SetSDFThreshold(0.5)
	render2d.SetSubpixelMode("none")
	render2d.SetSubpixelAmount(1 / 3)
	render2d.UpdateScreenSize(render.GetRenderImageSize():Unpack())
	render2d.SetBlendMode("alpha", true)

	if render2d.SetDepthMode then
		render2d.SetDepthMode(DEFAULT_DEPTH_MODE, false)
	end

	if render2d.SetStencilMode then render2d.SetStencilMode("none") end
end

do
	do
		function render2d.SetColor(r, g, b, a)
			fragment_constants.global_color[0] = r
			fragment_constants.global_color[1] = g
			fragment_constants.global_color[2] = b

			if a then fragment_constants.global_color[3] = a end
		end

		function render2d.GetColor()
			return fragment_constants.global_color[0],
			fragment_constants.global_color[1],
			fragment_constants.global_color[2],
			fragment_constants.global_color[3]
		end

		utility.MakePushPopFunction(render2d, "Color")
	end

	do
		function render2d.SetSwizzleMode(mode)
			if mode then fragment_constants.swizzle_mode = mode end
		end

		function render2d.GetSwizzleMode()
			return fragment_constants.swizzle_mode
		end

		utility.MakePushPopFunction(render2d, "SwizzleMode")
	end

	do
		do
			function render2d.SetSDFMode(mode)
				if mode ~= 0 then
					fragment_constants.swizzle_mode = 10
				elseif fragment_constants.swizzle_mode == 10 then
					fragment_constants.swizzle_mode = 0
				end
			end

			function render2d.GetSDFMode()
				return fragment_constants.swizzle_mode == 10 and 1 or 0
			end

			utility.MakePushPopFunction(render2d, "SDFMode")
		end

		do
			function render2d.SetSDFThreshold(threshold)
				fragment_constants.sdf_threshold = threshold
			end

			function render2d.GetSDFThreshold()
				return fragment_constants.sdf_threshold
			end

			utility.MakePushPopFunction(render2d, "SDFThreshold")

			function render2d.SetSDFTexelRange(range)
				fragment_constants.sdf_texel_range = range or 1
			end

			function render2d.GetSDFTexelRange()
				return fragment_constants.sdf_texel_range
			end

			utility.MakePushPopFunction(render2d, "SDFTexelRange")
			render2d.subpixel_modes = {
				none = 0,
				rgb = 1,
				bgr = 2,
				vrgb = 3,
				vbgr = 4,
				rwgb = 5,
			}

			function render2d.SetSubpixelMode(mode)
				if type(mode) == "string" then
					local m = render2d.subpixel_modes[mode:lower()]

					if not m then error("invalid subpixel mode: " .. mode) end

					mode = m
				end

				fragment_constants.subpixel_mode = mode
			end

			function render2d.GetSubpixelMode()
				for k, v in pairs(render2d.subpixel_modes) do
					if v == fragment_constants.subpixel_mode then return k end
				end

				return fragment_constants.subpixel_mode
			end

			utility.MakePushPopFunction(render2d, "SubpixelMode")

			function render2d.SetSubpixelAmount(amount)
				fragment_constants.subpixel_amount = amount
			end

			function render2d.GetSubpixelAmount()
				return fragment_constants.subpixel_amount
			end

			utility.MakePushPopFunction(render2d, "SubpixelAmount")
		end

		do
			function render2d.SetBlur(x, y)
				fragment_constants.blur[0] = x or 0
				fragment_constants.blur[1] = y or x or 0
			end

			function render2d.GetBlur()
				return fragment_constants.blur[0], fragment_constants.blur[1]
			end

			utility.MakePushPopFunction(render2d, "Blur")
		end

		do
			function render2d.SetSDFGradientTexture(tex)
				render2d.current_gradient_texture = tex
			end

			function render2d.GetSDFGradientTexture()
				return render2d.current_gradient_texture
			end

			utility.MakePushPopFunction(render2d, "SDFGradientTexture")
		end
	end

	do
		function render2d.SetBorderRadius(tl, tr, br, bl)
			if type(tl) == "table" then
				tr = tl[2]
				br = tl[3]
				bl = tl[4]
				tl = tl[1]
			end

			fragment_constants.border_radius[0] = tl or 0
			fragment_constants.border_radius[1] = tr or tl or 0
			fragment_constants.border_radius[2] = br or tl or 0
			fragment_constants.border_radius[3] = bl or tl or 0
		end

		function render2d.GetBorderRadius()
			return fragment_constants.border_radius[0],
			fragment_constants.border_radius[1],
			fragment_constants.border_radius[2],
			fragment_constants.border_radius[3]
		end

		utility.MakePushPopFunction(render2d, "BorderRadius")
	end

	do
		function render2d.SetOutlineWidth(width)
			fragment_constants.outline_width = width or 0
		end

		function render2d.GetOutlineWidth()
			return fragment_constants.outline_width
		end

		utility.MakePushPopFunction(render2d, "OutlineWidth")
	end

	do
		function render2d.ClearNinePatch()
			fragment_constants.nine_patch_x_count = 0
			fragment_constants.nine_patch_y_count = 0
		end

		function render2d.SetNinePatchTable(tbl)
			render2d.ClearNinePatch()

			if tbl.x_stretch then
				local count = math.max(#tbl.x_stretch, #tbl.y_stretch)
				count = math.min(count, 3)

				for i = 1, count do
					local x = tbl.x_stretch[i] or {0, 0}
					local y = tbl.y_stretch[i] or {0, 0}
					render2d.SetNinePatch(x[1], x[2], y[1], y[2], i - 1)
				end
			elseif tbl.stretch or tbl[1] then
				local s = tbl.stretch or tbl
				render2d.SetNinePatch(s[1] or 0, s[2] or 0, s[3] or 0, s[4] or 0, 0)
			end
		end

		function render2d.SetNinePatch(x1, y1, x2, y2, index)
			if type(x1) == "table" then
				render2d.SetNinePatchTable(x1.nine_patch or x1)
				return
			end

			if not x1 or not y1 or not x2 or not y2 then
				render2d.ClearNinePatch()
				return
			end

			index = index or 0
			fragment_constants.nine_patch_x_stretch[index * 2] = x1
			fragment_constants.nine_patch_x_stretch[index * 2 + 1] = y1
			fragment_constants.nine_patch_x_count = math.max(fragment_constants.nine_patch_x_count, index + 1)
			fragment_constants.nine_patch_y_stretch[index * 2] = x2
			fragment_constants.nine_patch_y_stretch[index * 2 + 1] = y2
			fragment_constants.nine_patch_y_count = math.max(fragment_constants.nine_patch_y_count, index + 1)
		end

		function render2d.GetNinePatch()
			return fragment_constants.nine_patch_x_stretch[0],
			fragment_constants.nine_patch_x_stretch[1],
			fragment_constants.nine_patch_y_stretch[0],
			fragment_constants.nine_patch_y_stretch[1]
		end
	end

	do
		function render2d.SetAlphaMultiplier(a)
			fragment_constants.alpha_multiplier = a
		end

		function render2d.GetAlphaMultiplier()
			return fragment_constants.alpha_multiplier
		end

		utility.MakePushPopFunction(render2d, "AlphaMultiplier")
	end

	do
		function render2d.SetTexture(tex)
			render2d.current_texture = tex
		end

		function render2d.GetTexture()
			return render2d.current_texture
		end

		utility.MakePushPopFunction(render2d, "Texture")
	end

	function render2d.SetBlendMode(mode_name, force, ...)
		local mode = mode_name
		local next_mode
		local next_state

		if type(mode_name) == "table" then
			force = force == true
			next_mode = normalize_blend_mode_state(mode_name)
			next_state = next_mode
		elseif select("#", ...) == 0 and (force == nil or type(force) == "boolean") then
			mode = mode_name or DEFAULT_BLEND_MODE

			if not render2d.blend_modes[mode] then
				error(get_valid_blend_mode_error(mode), 2)
			end

			next_mode = mode
			next_state = get_blend_mode_state(mode)
		else
			local dst_rgb, color_op, src_alpha, dst_alpha, alpha_op, raw_force = force, ...
			force = raw_force == true
			next_mode = normalize_blend_mode_state{
				blend = true,
				src_color_blend_factor = mode_name,
				dst_color_blend_factor = dst_rgb,
				color_blend_op = color_op,
				src_alpha_blend_factor = src_alpha or mode_name,
				dst_alpha_blend_factor = dst_alpha or dst_rgb,
				alpha_blend_op = alpha_op or color_op,
			}
			next_state = next_mode
		end

		render2d.current_blend_mode = next_mode
		render2d.current_blend_mode_state = next_state
		mark_pipeline_state_dirty()
	end

	function render2d.GetBlendMode()
		return clone_blend_mode(render2d.current_blend_mode)
	end

	do
		local stack = {}
		local i = 1

		function render2d.PushBlendMode(...)
			stack[i] = render2d.GetBlendMode()
			render2d.SetBlendMode(...)
			i = i + 1
		end

		function render2d.PopBlendMode()
			i = i - 1

			if i < 1 then error("stack underflow", 2) end

			render2d.SetBlendMode(stack[i], true)
		end
	end

	function render2d.CreateGradient(config)
		local width = config.width or 256
		local height = config.height or 1
		local mode = config.mode or "linear"
		local stops = config.stops or {}

		for i, stop in ipairs(stops) do
			stop.pos = stop.pos or i - 1
		end

		local tex = Texture.New{
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			mip_map_levels = 1,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
		local glsl

		if mode == "linear" then
			local angle = config.angle or 0 -- degrees
			local rad = math.rad(angle)
			local s, c = math.sin(rad), math.cos(rad)
			glsl = [[
				vec2 dir = vec2(]] .. s .. [[, ]] .. -c .. [[);
				float t = dot(uv - 0.5, dir) + 0.5;
			]]
		elseif mode == "radial" then
			glsl = [[
				float t = distance(uv, vec2(0.5)) * 2.0;
			]]
		end

		-- Build the color ramp from stops
		-- stops = { {pos=0, color=Color(1,0,0,1)}, {pos=1, color=Color(0,0,1,1)} }
		table.sort(stops, function(a, b)
			return a.pos < b.pos
		end)

		local ramp = ""

		if #stops == 0 then
			ramp = "return vec4(1.0);"
		elseif #stops == 1 then
			local c = stops[1].color
			ramp = "return vec4(" .. c.r .. "," .. c.g .. "," .. c.b .. "," .. c.a .. ");"
		else
			ramp = "vec4 res = vec4(0.0);\n"

			for i = 1, #stops - 1 do
				local s1 = stops[i]
				local s2 = stops[i + 1]
				local cond = (i == 1) and "t <= " .. s2.pos or "t > " .. s1.pos .. " && t <= " .. s2.pos

				if i == #stops - 1 then cond = "t > " .. s1.pos end

				ramp = ramp .. "if (" .. cond .. ") {\n"
				ramp = ramp .. "  float fac = clamp((t - " .. s1.pos .. ") / (" .. s2.pos .. " - " .. s1.pos .. "), 0.0, 1.0);\n"
				ramp = ramp .. "  res = mix(vec4(" .. s1.color.r .. "," .. s1.color.g .. "," .. s1.color.b .. "," .. s1.color.a .. "), vec4(" .. s2.color.r .. "," .. s2.color.g .. "," .. s2.color.b .. "," .. s2.color.a .. "), fac);\n"
				ramp = ramp .. "}\n"
			end

			ramp = ramp .. "return res;"
		end

		tex:Shade(glsl .. "\n" .. ramp)
		return tex
	end

	render2d.stencil_modes = {
		none = {
			stencil_test = false,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "always",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
		write = { -- Simply write the reference value everywhere
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "replace",
				depth_fail_op = "keep",
				compare_op = "always",
			},
			color_write_mask = {},
		},
		mask_write = { -- Increment level if it matches reference
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "increment_and_clamp",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {},
		},
		mask_test = { -- Pass if it matches reference
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
		mask_decrement = { -- Decrement level if it matches reference
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "decrement_and_clamp",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {},
		},
		test = {
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
		test_inverse = {
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "not_equal",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
	}

	do
		local current_mode = DEFAULT_DEPTH_MODE
		local current_write = false

		function render2d.SetDepthMode(mode_name, write)
			mode_name = mode_name or DEFAULT_DEPTH_MODE
			write = not not write

			if mode_name ~= DEFAULT_DEPTH_MODE and not depth_mode_to_compare_op[mode_name] then
				error("Invalid depth mode: " .. tostring(mode_name))
			end

			current_mode = mode_name
			current_write = write
			mark_pipeline_state_dirty()
		end

		function render2d.GetDepthMode()
			return current_mode, current_write
		end
	end

	do
		local current_mode = "none"
		local current_ref = 1
		render2d.stencil_level = 0

		function render2d.SetStencilMode(mode_name, ref)
			ref = ref or current_ref
			local mode = render2d.stencil_modes[mode_name]

			if not mode then error("Invalid stencil mode: " .. tostring(mode_name)) end

			current_mode = mode_name
			current_ref = ref
			mark_pipeline_state_dirty()
		end

		function render2d.GetStencilMode()
			return current_mode, current_ref
		end

		function render2d.GetStencilReference()
			return current_ref
		end

		function render2d.ClearStencil(val)
			if render.GetCommandBuffer() then
				local old_mode, old_ref = render2d.GetStencilMode()
				render2d.stencil_level = 0
				render2d.SetStencilMode("write", val or 0)
				local sw, sh = render2d.GetSize()
				render2d.PushMatrix()
				render2d.SetWorldMatrix(Matrix44())
				render2d.DrawRect(0, 0, sw, sh)
				render2d.PopMatrix()
				render2d.SetStencilMode(old_mode, old_ref)
			end
		end

		function render2d.PushStencilMask()
			render2d.PushStencilMode("mask_write", render2d.stencil_level)
			render2d.stencil_level = render2d.stencil_level + 1
		end

		function render2d.BeginStencilTest()
			render2d.SetStencilMode("mask_test", render2d.stencil_level)
		end

		function render2d.PopStencilMask()
			render2d.PopStencilMode()
			render2d.stencil_level = render2d.stencil_level - 1
		end

		utility.MakePushPopFunction(render2d, "StencilMode")
	end

	function render2d.SetBlendConstants(r, g, b, a)
		render.GetCommandBuffer():SetBlendConstants(r, g, b, a)
	end

	function render2d.SetScissor(x, y, w, h)
		if x < 0 then
			w = w + x
			x = 0
		end

		if y < 0 then
			h = h + y
			y = 0
		end

		w = math.max(w, 0)
		h = math.max(h, 0)
		render.GetCommandBuffer():SetScissor(x, y, w, h)
	end

	do
		local stack = {}

		function render2d.PushScissor(x, y, w, h)
			local current = stack[#stack]

			if current then
				local x2 = math.max(x, current.x)
				local y2 = math.max(y, current.y)
				local w2 = math.min(x + w, current.x + current.w) - x2
				local h2 = math.min(y + h, current.y + current.h) - y2
				x, y, w, h = x2, y2, math.max(0, w2), math.max(0, h2)
			end

			local data = {x = x, y = y, w = w, h = h}
			table.insert(stack, data)
			render2d.SetScissor(x, y, w, h)
		end

		function render2d.PopScissor()
			table.remove(stack)
			local current = stack[#stack]

			if current then
				render2d.SetScissor(current.x, current.y, current.w, current.h)
			else
				local sw, sh = render2d.GetSize()
				render2d.SetScissor(0, 0, sw or 0, sh or 0)
			end
		end
	end

	function render2d.UploadConstants(w, h, lw, lh)
		current_w, current_h = w or 0, h or 0
		current_lw, current_lh = lw or w or 0, lh or h or 0
		local pipeline = get_active_pipeline()

		if pipeline then pipeline:UploadConstants() end
	end
end

do -- mesh
	function render2d.CreateMesh(vertices, indices)
		return Mesh.New(render2d.pipeline:GetVertexAttributes(), vertices, indices)
	end

	render2d.last_bound_mesh = nil
	local last_cmd = nil

	local function ensure_draw_command()
		local cmd = render.GetCommandBuffer()
		sync_pipeline_state()
		return cmd
	end

	function render2d.BindMesh(mesh)
		local cmd = ensure_draw_command()

		if not cmd then return false end

		if last_cmd ~= cmd or render2d.last_bound_mesh ~= mesh then
			mesh:Bind(cmd, 0)
			render2d.last_bound_mesh = mesh
			last_cmd = cmd
		end

		return true
	end

	function render2d.DrawIndexedMesh(index_count, instance_count, first_index, vertex_offset, first_instance)
		local cmd = ensure_draw_command()

		if not cmd then return end

		cmd:DrawIndexed(
			index_count or index_buffer:GetIndexCount(),
			instance_count or 1,
			first_index or 0,
			vertex_offset or 0,
			first_instance or 0
		)
	end

	function render2d.DrawMesh(vertex_count, instance_count, first_vertex, first_instance)
		local cmd = ensure_draw_command()

		if not cmd then return end

		cmd:Draw(
			vertex_count or vertex_buffer:GetVertexCount(),
			instance_count or 1,
			first_vertex or 0,
			first_instance or 0
		)
	end
end

do -- uv
	local X, Y, W, H, SX, SY

	function render2d.SetUV(x, y, w, h, sx, sy)
		if not x then
			-- Reset to default (no transformation)
			fragment_constants.uv_offset[0] = 0
			fragment_constants.uv_offset[1] = 0
			fragment_constants.uv_scale[0] = 1
			fragment_constants.uv_scale[1] = 1
		else
			sx = sx or 1
			sy = sy or 1
			local y = -y - h
			-- Set UV offset and scale
			fragment_constants.uv_offset[0] = x / sx
			fragment_constants.uv_offset[1] = y / sy
			fragment_constants.uv_scale[0] = w / sx
			fragment_constants.uv_scale[1] = h / sy
		end

		X = x
		Y = y
		W = w
		H = h
		SX = sx
		SY = sy
	end

	function render2d.GetUV()
		return X, Y, W, H, SX, SY
	end

	function render2d.GetUVTransform()
		return fragment_constants.uv_offset[0],
		fragment_constants.uv_offset[1],
		fragment_constants.uv_scale[0],
		fragment_constants.uv_scale[1]
	end

	function render2d.SetSampleUVMode(mode)
		fragment_constants.sample_uv_mode = mode or 0
	end

	function render2d.GetSampleUVMode()
		return fragment_constants.sample_uv_mode
	end

	function render2d.SetUV2(u1, v1, u2, v2)
		-- Calculate offset and scale from UV coordinates
		fragment_constants.uv_offset[0] = u1
		fragment_constants.uv_offset[1] = v1
		fragment_constants.uv_scale[0] = u2 - u1
		fragment_constants.uv_scale[1] = v2 - v1
	end

	utility.MakePushPopFunction(render2d, "UV")
	utility.MakePushPopFunction(render2d, "SampleUVMode")
end

do -- camera
	local proj = Matrix44()
	local view = Matrix44()
	local world = Matrix44()
	local viewport = Rect(0, 0, 512, 512)
	local view_pos = Vec2(0, 0)
	local view_zoom = Vec2(1, 1)
	local view_angle = 0
	local world_matrix_stack = {Matrix44()}
	local world_matrix_stack_pos = 1
	local proj_view = Matrix44()

	local function update_proj_view()
		proj_view = view * proj
	end

	local function update_projection()
		proj:Identity()
		proj:Ortho(viewport.x, viewport.w, viewport.y, viewport.h, -16000, 16000)
		update_proj_view()
	end

	local function update_view()
		view:Identity()
		local x, y = viewport.w / 2, viewport.h / 2
		view:Translate(x, y, 0)
		view:Rotate(view_angle, 0, 0, 1)
		view:Translate(-x, -y, 0)
		view:Translate(view_pos.x, view_pos.y, 0)
		view:Translate(x, y, 0)
		view:Scale(view_zoom.x, view_zoom.y, 1)
		view:Translate(-x, -y, 0)
		update_proj_view()
	end

	function render2d.UpdateScreenSize(w, h)
		viewport.w = w
		viewport.h = h
		update_projection()
		update_view()
	end

	function render2d.GetMatrix()
		return world_matrix_stack[world_matrix_stack_pos] * proj_view
	end

	function render2d.GetProjectionViewMatrix()
		return proj_view
	end

	function render2d.GetSize()
		return viewport.w, viewport.h
	end

	do
		local ceil = math.ceil

		function render2d.Translate(x, y, z)
			world_matrix_stack[world_matrix_stack_pos]:Translate(ceil(x), ceil(y), z or 0)
		end

		function render2d.Scale(w, h, z)
			world_matrix_stack[world_matrix_stack_pos]:Scale(ceil(w), ceil(h or w), z or 1)
		end
	end

	function render2d.Translatef(x, y, z)
		world_matrix_stack[world_matrix_stack_pos]:Translate(x, y, z or 0)
	end

	function render2d.Rotate(a)
		world_matrix_stack[world_matrix_stack_pos]:Rotate(a, 0, 0, 1)
	end

	function render2d.Scalef(w, h, z)
		world_matrix_stack[world_matrix_stack_pos]:Scale(w, h or w, z or 1)
	end

	function render2d.Shear(x, y)
		world_matrix_stack[world_matrix_stack_pos]:Shear(x, y, 0)
	end

	function render2d.LoadIdentity()
		world_matrix_stack[world_matrix_stack_pos]:Identity()
	end

	function render2d.PushMatrix(x, y, w, h, a, dont_multiply)
		world_matrix_stack_pos = world_matrix_stack_pos + 1

		if dont_multiply then
			world_matrix_stack[world_matrix_stack_pos] = Matrix44()
		else
			world_matrix_stack[world_matrix_stack_pos] = world_matrix_stack[world_matrix_stack_pos - 1]:Copy()
		end

		if x and y then render2d.Translate(x, y) end

		if w and h then render2d.Scale(w, h) end

		if a then render2d.Rotate(a) end
	end

	function render2d.PopMatrix()
		if world_matrix_stack_pos > 1 then
			world_matrix_stack_pos = world_matrix_stack_pos - 1
		else
			error("Matrix stack underflow")
		end
	end

	function render2d.SetWorldMatrix(mat)
		world_matrix_stack[world_matrix_stack_pos] = mat:Copy()
	end

	function render2d.GetWorldMatrix()
		return world_matrix_stack[world_matrix_stack_pos]
	end
end

do
	local function get_margin()
		local content_m = fragment_constants.outline_width

		if fragment_constants.swizzle_mode == 10 or fragment_constants.swizzle_mode == 1 then
			content_m = content_m + math.max(fragment_constants.blur[0], fragment_constants.blur[1])
		end

		if fragment_constants.blur[0] > 0 or fragment_constants.blur[1] > 0 then
			content_m = math.max(content_m, fragment_constants.blur[0], fragment_constants.blur[1])
		end

		local m = content_m

		if m > 0 then m = m + 1 end

		return math.ceil(m)
	end

	local m = nil

	function render2d.GetMargin()
		return m or get_margin()
	end

	function render2d.SetMargin(new_m)
		m = new_m
	end

	function render2d.DrawRect(x, y, w, h, a, ox, oy, max_m)
		local m = render2d.GetMargin(w, h)

		if max_m then m = math.min(m, max_m) end

		render2d.BindMesh(render2d.rect_mesh)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x - m, y - m) end

		if a then render2d.Rotate(a) end

		if ox then render2d.Translate(-ox, -oy) end

		local qw, qh = w + m * 2, h + m * 2

		if w and h then render2d.Scale(qw, qh) end

		local old_off_x, old_off_y = fragment_constants.uv_offset[0], fragment_constants.uv_offset[1]
		local old_scale_x, old_scale_y = fragment_constants.uv_scale[0], fragment_constants.uv_scale[1]

		if m > 0 and w > 0 and h > 0 then
			fragment_constants.uv_scale[0] = old_scale_x * (qw / w)
			fragment_constants.uv_scale[1] = old_scale_y * (qh / h)
			fragment_constants.uv_offset[0] = old_off_x - (m / w) * old_scale_x
			fragment_constants.uv_offset[1] = old_off_y - (m / h) * old_scale_y
		end

		local cmd = render.GetCommandBuffer()
		render2d.UploadConstants(qw, qh, w, h)
		render2d.rect_mesh:DrawIndexed(cmd, 6)
		fragment_constants.uv_offset[0], fragment_constants.uv_offset[1] = old_off_x, old_off_y
		fragment_constants.uv_scale[0], fragment_constants.uv_scale[1] = old_scale_x, old_scale_y
		render2d.PopMatrix()
	end

	function render2d.DrawRectf(x, y, w, h, a, ox, oy, max_m)
		local m = render2d.GetMargin(w, h)

		if max_m then m = math.min(m, max_m) end

		render2d.BindMesh(render2d.rect_mesh)
		render2d.PushMatrix()

		if x and y then render2d.Translatef(x - m, y - m) end

		if a then render2d.Rotate(a) end

		if ox then render2d.Translatef(-ox, -oy) end

		local qw, qh = w + m * 2, h + m * 2

		if w and h then render2d.Scalef(qw, qh) end

		local old_off_x, old_off_y = fragment_constants.uv_offset[0], fragment_constants.uv_offset[1]
		local old_scale_x, old_scale_y = fragment_constants.uv_scale[0], fragment_constants.uv_scale[1]

		if m > 0 and w > 0 and h > 0 then
			fragment_constants.uv_scale[0] = old_scale_x * (qw / w)
			fragment_constants.uv_scale[1] = old_scale_y * (qh / h)
			fragment_constants.uv_offset[0] = old_off_x - (m / w) * old_scale_x
			fragment_constants.uv_offset[1] = old_off_y - (m / h) * old_scale_y
		end

		local cmd = render.GetCommandBuffer()
		render2d.UploadConstants(qw, qh, w, h)
		render2d.rect_mesh:DrawIndexed(cmd, 6)
		fragment_constants.uv_offset[0], fragment_constants.uv_offset[1] = old_off_x, old_off_y
		fragment_constants.uv_scale[0], fragment_constants.uv_scale[1] = old_scale_x, old_scale_y
		render2d.PopMatrix()
	end
end

do
	function render2d.DrawTriangle(x, y, w, h, a)
		render2d.BindMesh(render2d.triangle_mesh)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x, y) end

		if a then render2d.Rotate(a) end

		if w and h then render2d.Scale(w, h) end

		local cmd = render.GetCommandBuffer()
		render2d.UploadConstants(w, h)
		render2d.triangle_mesh:Draw(cmd, 3)
		render2d.PopMatrix()
	end
end

function render2d.BindPipeline()
	sync_pipeline_state(true)
	-- Reset mesh binding cache since command buffer state was reset
	render2d.last_bound_mesh = nil
end

function render2d.GetActivePipeline()
	return get_active_pipeline()
end

render2d.SetColor(1, 1, 1, 1)
render2d.SetAlphaMultiplier(1)
render2d.SetSwizzleMode(0)
render2d.current_blend_mode = "alpha"
render2d.current_blend_mode_state = get_blend_mode_state("alpha")
render2d.pipeline_state_dirty = true

event.AddListener("PostDraw", "draw_2d", function(dt)
	if not render2d.pipeline then return end -- not 2d initialized
	render2d.BindPipeline()
	event.Call("PreDraw2D", dt)
	event.Call("Draw2D", dt)
end)

event.AddListener("WindowFramebufferResized", "render2d", function(wnd, size)
	if render.target:IsValid() and render.target.config.offscreen then return end

	render2d.UpdateScreenSize(size.x, size.y)
end)

if HOTRELOAD then
	render2d.pipeline = nil
	render2d.Initialize()
end

return render2d
