local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Texture = import("goluwa/render/texture.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local create_metal_frame = import("goluwa/render/textures/metal_frame.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Button = import("../elements/button.lua")
local Column = import("../elements/column.lua")
local Frame = import("../elements/frame.lua")
local PropertyEditor = import("../elements/property_editor.lua")
local Row = import("../elements/row.lua")
local ScrollablePanel = import("../elements/scrollable_panel.lua")
local Splitter = import("../elements/splitter.lua")
local Text = import("../elements/text.lua")
local BLEND_FACTOR_OPTIONS = {
	"zero",
	"one",
	"src_color",
	"one_minus_src_color",
	"dst_color",
	"one_minus_dst_color",
	"src_alpha",
	"one_minus_src_alpha",
	"dst_alpha",
	"one_minus_dst_alpha",
	"constant_color",
	"one_minus_constant_color",
	"constant_alpha",
	"one_minus_constant_alpha",
	"src_alpha_saturate",
}
local BLEND_OP_OPTIONS = {"add", "subtract", "reverse_subtract", "min", "max"}
local BLEND_PRESET_OPTIONS = {
	"alpha",
	"additive",
	"multiply",
	"premultiplied",
	"screen",
	"subtract",
	"none",
}
local DEPTH_MODE_OPTIONS = {
	"none",
	"less",
	"lequal",
	"equal",
	"gequal",
	"greater",
	"notequal",
	"always",
}
local STENCIL_MODE_OPTIONS = {
	"none",
	"write",
	"mask_write",
	"mask_test",
	"mask_decrement",
	"test",
	"test_inverse",
}
local RECT_BATCH_MODE_OPTIONS = {"immediate", "replay", "instanced"}
local SUBPIXEL_MODE_OPTIONS = {"none", "rgb", "bgr", "vrgb", "vbgr", "rwgb"}
local SAMPLE_UV_MODE_OPTIONS = {
	{Text = "0: default", Value = 0},
	{Text = "1: direct sample UV", Value = 1},
	{Text = "2: invert SDF sign", Value = 2},
	{Text = "3: direct + invert", Value = 3},
}
local SWIZZLE_MODE_OPTIONS = {
	{Text = "0: rgba", Value = 0},
	{Text = "1: rrr1", Value = 1},
	{Text = "2: ggg1", Value = 2},
	{Text = "3: bbb1", Value = 3},
	{Text = "4: aaa1", Value = 4},
	{Text = "5: rgb1", Value = 5},
}
local TEXTURE_SOURCE_OPTIONS = {
	{Text = "None", Value = "none"},
	{Text = "Pattern", Value = "pattern"},
	{Text = "Channels", Value = "channels"},
	{Text = "SDF Circle", Value = "sdf_circle"},
	{Text = "Metal Frame", Value = "metal_frame"},
}
local GRADIENT_SOURCE_OPTIONS = {
	{Text = "Warm", Value = "warm"},
	{Text = "Cool", Value = "cool"},
	{Text = "Radial", Value = "radial"},
}
local NINE_PATCH_OPTIONS = {
	{Text = "Off", Value = "none"},
	{Text = "Manual", Value = "manual"},
	{Text = "Texture Table", Value = "texture"},
}
local warm_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = -8,
	stops = {
		{pos = 0.0, color = Color(1.0, 0.48, 0.18, 1.0)},
		{pos = 0.5, color = Color(1.0, 0.78, 0.22, 1.0)},
		{pos = 1.0, color = Color(1.0, 0.95, 0.56, 1.0)},
	},
}
local cool_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = 90,
	stops = {
		{pos = 0.0, color = Color(0.14, 0.82, 1.0, 1.0)},
		{pos = 0.45, color = Color(0.18, 0.4, 1.0, 1.0)},
		{pos = 1.0, color = Color(0.46, 0.2, 1.0, 1.0)},
	},
}
local radial_gradient = render2d.CreateGradient{
	mode = "radial",
	stops = {
		{pos = 0.0, color = Color(1.0, 1.0, 1.0, 1.0)},
		{pos = 0.55, color = Color(0.64, 0.86, 1.0, 1.0)},
		{pos = 1.0, color = Color(0.12, 0.2, 0.34, 1.0)},
	},
}
local pattern_texture = Texture.New{
	width = 96,
	height = 96,
	format = "r8g8b8a8_unorm",
	mip_map_levels = 1,
	sampler = {
		min_filter = "nearest",
		mag_filter = "nearest",
		wrap_s = "repeat",
		wrap_t = "repeat",
	},
}
pattern_texture:Shade([[
	vec2 grid = floor(uv * 8.0);
	float checker = mod(grid.x + grid.y, 2.0);
	vec3 base = mix(vec3(0.11, 0.15, 0.26), vec3(0.76, 0.87, 1.0), checker);
	float stripe = smoothstep(0.15, 0.85, abs(sin((uv.x * 2.0 + uv.y) * 18.0)));
	base = mix(base, vec3(1.0, 0.45, 0.24), stripe * 0.45);
	return vec4(base, 1.0);
]])
local channel_texture = Texture.New{
	width = 128,
	height = 128,
	format = "r8g8b8a8_unorm",
	mip_map_levels = 1,
	sampler = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "repeat",
		wrap_t = "repeat",
	},
}
channel_texture:Shade([[
	float grid = step(0.5, fract(uv.x * 10.0)) * step(0.5, fract(uv.y * 10.0));
	float alpha_checker = mix(0.28, 1.0, mod(floor(uv.x * 8.0) + floor(uv.y * 8.0), 2.0));
	return vec4(uv.x, uv.y, 1.0 - uv.x * 0.75, mix(alpha_checker, 1.0, grid));
]])
local sdf_circle_texture = Texture.New{
	width = 128,
	height = 128,
	format = "r8g8b8a8_unorm",
	mip_map_levels = 1,
	sampler = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "clamp_to_edge",
		wrap_t = "clamp_to_edge",
	},
}
sdf_circle_texture:Shade([[
	vec2 p = uv - 0.5;
	float dist = length(p);
	float radius = 0.28;
	float spread = 0.18;
	float sdf = clamp(0.5 + ((radius - dist) / spread) * 0.5, 0.0, 1.0);
	float alpha = smoothstep(radius + 0.06, radius - 0.06, dist);
	return vec4(sdf, alpha, 1.0 - sdf, alpha);
]])
local metal_frame_texture = create_metal_frame{
	width = 256,
	height = 256,
	base_color = {r = 0.72, g = 0.76, b = 0.8},
	frame_outer = 0.025,
	frame_inner = 0.11,
	bevel = 0.03,
	corner_radius = 0.1,
	profile_strength = 1.8,
	long_curve = 0.18,
	specular_power = 72,
	specular_strength = 0.95,
	ambient = 0.28,
}

local function set_text(panel, value)
	if panel and panel:IsValid() then panel.text:SetText(value or "") end
end

local function copy_color(value)
	return Color(
		value.r or value[1] or 1,
		value.g or value[2] or 1,
		value.b or value[3] or 1,
		value.a or value[4] or 1
	)
end

local function format_color(color)
	return string.format("(%.2f, %.2f, %.2f, %.2f)", color.r, color.g, color.b, color.a)
end

local function with_rect_batch_mode(mode, callback)
	local old_mode = render2d.GetRectBatchMode()
	local ok, err
	render2d.SetRectBatchMode(mode)
	ok, err = xpcall(callback, debug.traceback)
	render2d.SetRectBatchMode(old_mode)

	if not ok then error(err, 0) end
end

local function resolve_texture(source)
	if source == "pattern" then return pattern_texture end

	if source == "channels" then return channel_texture end

	if source == "sdf_circle" then return sdf_circle_texture end

	if source == "metal_frame" then return metal_frame_texture end

	return nil
end

local function resolve_gradient(source)
	if source == "cool" then return cool_gradient end

	if source == "radial" then return radial_gradient end

	return warm_gradient
end

local function build_color_write_mask(state)
	local mask = {}

	if state.color_write_r then mask[#mask + 1] = "r" end

	if state.color_write_g then mask[#mask + 1] = "g" end

	if state.color_write_b then mask[#mask + 1] = "b" end

	if state.color_write_a then mask[#mask + 1] = "a" end

	return mask
end

local function build_custom_blend_state(state)
	return {
		blend = state.blend_enabled,
		src_color_blend_factor = state.src_color_blend_factor,
		dst_color_blend_factor = state.dst_color_blend_factor,
		color_blend_op = state.color_blend_op,
		src_alpha_blend_factor = state.src_alpha_blend_factor,
		dst_alpha_blend_factor = state.dst_alpha_blend_factor,
		alpha_blend_op = state.alpha_blend_op,
		color_write_mask = build_color_write_mask(state),
	}
end

local function build_summary(state)
	local blend = state.blend_use_custom and
		(
			string.format(
				"custom (%s -> %s, %s)",
				state.src_color_blend_factor,
				state.dst_color_blend_factor,
				state.color_blend_op
			)
		) or
		state.blend_preset
	local uv_line = state.uv_enabled and
		string.format(
			"uv=(%.1f, %.1f, %.1f, %.1f) / source=(%.1f, %.1f)",
			state.uv_x,
			state.uv_y,
			state.uv_w,
			state.uv_h,
			state.uv_sx,
			state.uv_sy
		) or
		"uv=off"
	local nine_patch = state.nine_patch_mode == "manual" and
		string.format(
			"manual %.1f %.1f %.1f %.1f",
			state.nine_patch_x1,
			state.nine_patch_y1,
			state.nine_patch_x2,
			state.nine_patch_y2
		) or
		state.nine_patch_mode
	return table.concat(
		{
			string.format(
				"rect=(%.1f, %.1f, %.1f, %.1f) rot=%.1fdeg z=%.1f",
				state.x,
				state.y,
				state.w,
				state.h,
				state.rotation_deg,
				state.rect_z
			),
			"color=" .. format_color(state.color) .. " alpha_mult=" .. string.format("%.2f", state.alpha_multiplier),
			"texture=" .. tostring(state.texture_source) .. " gradient=" .. (
				state.gradient_enabled and
				state.gradient_source or
				"off"
			),
			uv_line,
			string.format(
				"radius=(%.1f, %.1f, %.1f, %.1f) outline=%.2f blur=(%.1f, %.1f)",
				state.radius_tl,
				state.radius_tr,
				state.radius_br,
				state.radius_bl,
				state.outline_width,
				state.blur_x,
				state.blur_y
			),
			string.format(
				"sdf=%s threshold=%.2f texel_range=%.1f subpixel=%s/%.3f swizzle=%s sample_uv=%s",
				tostring(state.sdf_mode),
				state.sdf_threshold,
				state.sdf_texel_range,
				state.subpixel_mode,
				state.subpixel_amount,
				tostring(state.swizzle_mode),
				tostring(state.sample_uv_mode)
			),
			"blend=" .. blend,
			string.format(
				"depth=%s write=%s stencil=%s ref=%d",
				state.depth_mode,
				tostring(state.depth_write),
				state.stencil_mode,
				state.stencil_ref
			),
			state.scissor_enabled and
			string.format(
				"scissor=(%.1f, %.1f, %.1f, %.1f)",
				state.scissor_x,
				state.scissor_y,
				state.scissor_w,
				state.scissor_h
			) or
			"scissor=off",
			"nine_patch=" .. nine_patch .. " batch=" .. state.rect_batch_mode,
		},
		"\n"
	)
end

local function make_default_state()
	return {
		x = 76,
		y = 56,
		w = 250,
		h = 164,
		rotation_deg = -7,
		origin_x = 0,
		origin_y = 0,
		float_coords = true,
		rect_z = 6,
		rect_batch_mode = "instanced",
		color = Color(1, 1, 1, 1),
		alpha_multiplier = 1,
		texture_source = "pattern",
		gradient_enabled = true,
		gradient_source = "warm",
		uv_enabled = true,
		uv_x = 0,
		uv_y = 0,
		uv_w = 96,
		uv_h = 96,
		uv_sx = 96,
		uv_sy = 96,
		sample_uv_mode = 0,
		swizzle_mode = 0,
		radius_tl = 26,
		radius_tr = 10,
		radius_br = 34,
		radius_bl = 12,
		outline_width = 2,
		blur_x = 0,
		blur_y = 0,
		sdf_mode = false,
		sdf_threshold = 0.5,
		sdf_texel_range = 18,
		subpixel_mode = "none",
		subpixel_amount = 1 / 3,
		nine_patch_mode = "none",
		nine_patch_x1 = 24,
		nine_patch_y1 = 24,
		nine_patch_x2 = 24,
		nine_patch_y2 = 24,
		blend_use_custom = false,
		blend_preset = "alpha",
		blend_enabled = true,
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one_minus_src_alpha",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
		color_write_r = true,
		color_write_g = true,
		color_write_b = true,
		color_write_a = true,
		depth_mode = "none",
		depth_write = false,
		stencil_mode = "none",
		stencil_ref = 1,
		scissor_enabled = false,
		scissor_x = 44,
		scissor_y = 40,
		scissor_w = 280,
		scissor_h = 194,
	}
end

local function draw_checkerboard(w, h)
	local cell = 24

	for row = 0, math.ceil(h / cell) do
		for col = 0, math.ceil(w / cell) do
			local shade = ((row + col) % 2 == 0) and 0.09 or 0.12
			render2d.SetColor(shade, shade + 0.01, shade + 0.02, 1)
			render2d.DrawRect(col * cell, row * cell, cell, cell)
		end
	end

	render2d.SetColor(1, 1, 1, 0.035)

	for x = 0, math.floor(w / cell) do
		render2d.DrawRect(x * cell, 0, 1, h)
	end

	for y = 0, math.floor(h / cell) do
		render2d.DrawRect(0, y * cell, w, 1)
	end
end

local function draw_preview_shell(w, h)
	render2d.SetTexture(nil)
	render2d.SetColor(0.04, 0.05, 0.08, 1)
	render2d.DrawRect(0, 0, w, h)
	draw_checkerboard(w, h)
	render2d.SetColor(1, 1, 1, 0.045)
	render2d.PushOutlineWidth(1)
	render2d.PushBorderRadius(18)
	render2d.DrawRect(12, 12, w - 24, h - 24)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.SetColor(0.1, 0.14, 0.22, 1)
	render2d.PushBorderRadius(18)
	render2d.DrawRect(24, 24, w - 48, h - 48)
	render2d.PopBorderRadius()
	render2d.SetColor(1, 1, 1, 0.03)
	render2d.DrawRect(w * 0.5, 24, 1, h - 48)
	render2d.DrawRect(24, h * 0.5, w - 48, 1)
end

local function draw_mask_shape(x, y, w, h)
	render2d.PushBorderRadius(18)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PushBorderRadius(10)
	render2d.DrawRect(x + w * 0.36, y - 12, w * 0.28, 28)
	render2d.PopBorderRadius()
end

local function draw_reference_depth_plate()
	local old_depth_mode, old_depth_write = render2d.GetDepthMode()
	render2d.SetDepthMode("always", true)
	render2d.PushMatrix()
	render2d.Translatef(0, 0, 0)
	render2d.SetColor(0.96, 0.36, 0.22, 0.3)
	render2d.PushBorderRadius(14)
	render2d.DrawRect(118, 84, 114, 112)
	render2d.PopBorderRadius()
	render2d.SetColor(1, 1, 1, 0.12)
	render2d.PushOutlineWidth(1)
	render2d.PushBorderRadius(14)
	render2d.DrawRect(118, 84, 114, 112)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopMatrix()
	render2d.SetDepthMode(old_depth_mode, old_depth_write)
end

local function draw_scissor_overlay(state)
	render2d.SetColor(0.28, 0.84, 1.0, 0.16)
	render2d.DrawRect(state.scissor_x, state.scissor_y, state.scissor_w, state.scissor_h)
	render2d.SetColor(0.28, 0.84, 1.0, 0.6)
	render2d.PushOutlineWidth(1)
	render2d.DrawRect(state.scissor_x, state.scissor_y, state.scissor_w, state.scissor_h)
	render2d.PopOutlineWidth()
end

local function draw_rect_with_state(state)
	local old_depth_mode, old_depth_write = render2d.GetDepthMode()
	local old_stencil_mode, old_stencil_ref = render2d.GetStencilMode()
	local blend_state = state.blend_use_custom and build_custom_blend_state(state) or state.blend_preset
	local texture = resolve_texture(state.texture_source)
	local gradient = state.gradient_enabled and resolve_gradient(state.gradient_source) or nil
	local draw_rect = state.float_coords and render2d.DrawRectf or render2d.DrawRect
	local clear_nine_patch = false

	if type(blend_state) == "table" then
		render2d.PushBlendMode(blend_state, true)
	else
		render2d.PushBlendMode(blend_state)
	end

	render2d.SetDepthMode(state.depth_mode, state.depth_write)
	render2d.SetStencilMode(state.stencil_mode, state.stencil_ref)
	render2d.PushTexture(texture)
	render2d.PushSDFGradientTexture(gradient)
	render2d.PushColor(state.color.r, state.color.g, state.color.b, state.color.a)
	render2d.PushAlphaMultiplier(state.alpha_multiplier)
	render2d.PushSampleUVMode(state.sample_uv_mode)

	if state.sdf_mode then
		render2d.PushSDFMode(true)
	else
		render2d.PushSwizzleMode(state.swizzle_mode)
	end

	render2d.PushSDFThreshold(state.sdf_threshold)
	render2d.PushSDFTexelRange(state.sdf_texel_range)
	render2d.PushSubpixelMode(state.subpixel_mode)
	render2d.PushSubpixelAmount(state.subpixel_amount)
	render2d.PushBlur(state.blur_x, state.blur_y)
	render2d.PushBorderRadius(state.radius_tl, state.radius_tr, state.radius_br, state.radius_bl)
	render2d.PushOutlineWidth(state.outline_width)

	if state.uv_enabled then
		render2d.PushUV(state.uv_x, state.uv_y, state.uv_w, state.uv_h, state.uv_sx, state.uv_sy)
	end

	if state.nine_patch_mode == "texture" and texture and texture.nine_patch then
		render2d.SetNinePatchTable(texture.nine_patch)
		clear_nine_patch = true
	elseif state.nine_patch_mode == "manual" then
		render2d.SetNinePatch(state.nine_patch_x1, state.nine_patch_y1, state.nine_patch_x2, state.nine_patch_y2)
		clear_nine_patch = true
	end

	render2d.PushMatrix()
	render2d.Translatef(0, 0, state.rect_z)
	draw_rect(
		state.x,
		state.y,
		state.w,
		state.h,
		math.rad(state.rotation_deg),
		state.origin_x,
		state.origin_y
	)
	render2d.PopMatrix()

	if clear_nine_patch then render2d.ClearNinePatch() end

	if state.uv_enabled then render2d.PopUV() end

	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
	render2d.PopBlur()
	render2d.PopSubpixelAmount()
	render2d.PopSubpixelMode()
	render2d.PopSDFTexelRange()
	render2d.PopSDFThreshold()

	if state.sdf_mode then
		render2d.PopSDFMode()
	else
		render2d.PopSwizzleMode()
	end

	render2d.PopSampleUVMode()
	render2d.PopAlphaMultiplier()
	render2d.PopColor()
	render2d.PopSDFGradientTexture()
	render2d.PopTexture()
	render2d.SetStencilMode(old_stencil_mode, old_stencil_ref)
	render2d.SetDepthMode(old_depth_mode, old_depth_write)
	render2d.PopBlendMode()
end

local function draw_stencil_visualization(state)
	local mode = state.stencil_mode
	local ref = state.stencil_ref
	local mask_x = state.x + state.w * 0.12
	local mask_y = state.y + state.h * 0.14
	local mask_w = state.w * 0.62
	local mask_h = state.h * 0.58
	render2d.ClearStencil(0)
	render2d.SetStencilMode("none", ref)
	render2d.SetColor(0.35, 0.84, 1.0, 0.08)
	draw_mask_shape(mask_x, mask_y, mask_w, mask_h)
	render2d.SetColor(0.35, 0.84, 1.0, 0.32)
	render2d.PushOutlineWidth(1)
	draw_mask_shape(mask_x, mask_y, mask_w, mask_h)
	render2d.PopOutlineWidth()

	if mode ~= "none" and mode ~= "write" then
		render2d.SetStencilMode("write", ref)
		render2d.SetColor(1, 1, 1, 1)
		draw_mask_shape(mask_x, mask_y, mask_w, mask_h)
	end

	draw_rect_with_state(state)

	if mode == "write" then
		render2d.SetStencilMode("test", ref)
		render2d.SetColor(1, 1, 1, 0.24)
		render2d.PushSDFGradientTexture(cool_gradient)
		render2d.DrawRect(state.x + 8, state.y + 8, state.w - 16, state.h - 16)
		render2d.PopSDFGradientTexture()
	elseif mode == "mask_write" then
		render2d.SetStencilMode("test", ref + 1)
		render2d.SetColor(1.0, 0.58, 0.24, 0.42)
		render2d.DrawRect(state.x + 8, state.y + 8, state.w - 16, state.h - 16)
	elseif mode == "mask_decrement" then
		render2d.SetStencilMode("test", math.max(ref - 1, 0))
		render2d.SetColor(0.24, 0.95, 0.58, 0.34)
		render2d.DrawRect(state.x + 8, state.y + 8, state.w - 16, state.h - 16)
	end

	render2d.SetStencilMode("none", ref)
end

local function draw_preview(panel, state)
	local size = panel.transform.Size + panel.transform.DrawSizeOffset
	local old_depth_mode, old_depth_write = render2d.GetDepthMode()
	local old_stencil_mode, old_stencil_ref = render2d.GetStencilMode()
	local scissor_pushed = false

	with_rect_batch_mode(state.rect_batch_mode, function()
		render2d.SetDepthMode("none", false)
		render2d.SetStencilMode("none", 1)
		draw_preview_shell(size.x, size.y)
		draw_reference_depth_plate()

		if state.scissor_enabled then
			local x1, y1, x2, y2 = panel.transform:GetWorldBounds(state.scissor_x, state.scissor_y, state.scissor_w, state.scissor_h)
			local scissor_x = math.floor(x1)
			local scissor_y = math.floor(y1)
			local scissor_w = math.max(0, math.ceil(x2 - x1))
			local scissor_h = math.max(0, math.ceil(y2 - y1))
			render2d.PushScissor(scissor_x, scissor_y, scissor_w, scissor_h)
			scissor_pushed = true
		end

		if state.stencil_mode == "none" then
			draw_rect_with_state(state)
		else
			draw_stencil_visualization(state)
		end

		if scissor_pushed then
			render2d.PopScissor()
			scissor_pushed = false
			draw_scissor_overlay(state)
		end
	end)

	render2d.SetStencilMode(old_stencil_mode, old_stencil_ref)
	render2d.SetDepthMode(old_depth_mode, old_depth_write)
end

local function build_items(state, refresh_preview, refresh_editor)
	local function on_field(key, transform, also_refresh_editor)
		return function(_, value)
			state[key] = transform and transform(value) or value
			refresh_preview()

			if also_refresh_editor then refresh_editor() end
		end
	end

	return {
		{
			Key = "geometry",
			Text = "Geometry",
			Expanded = true,
			Description = "Local rect placement and draw mode selection.",
			Children = {
				{
					Key = "geometry/x",
					Text = "X",
					Type = "number",
					Value = state.x,
					Min = 0,
					Max = 420,
					Precision = 1,
					OnChange = on_field("x"),
				},
				{
					Key = "geometry/y",
					Text = "Y",
					Type = "number",
					Value = state.y,
					Min = 0,
					Max = 320,
					Precision = 1,
					OnChange = on_field("y"),
				},
				{
					Key = "geometry/w",
					Text = "Width",
					Type = "number",
					Value = state.w,
					Min = 24,
					Max = 360,
					Precision = 1,
					OnChange = on_field("w"),
				},
				{
					Key = "geometry/h",
					Text = "Height",
					Type = "number",
					Value = state.h,
					Min = 24,
					Max = 260,
					Precision = 1,
					OnChange = on_field("h"),
				},
				{
					Key = "geometry/rotation",
					Text = "Rotation",
					Type = "number",
					Value = state.rotation_deg,
					Min = -180,
					Max = 180,
					Precision = 1,
					Description = "Degrees passed into DrawRect/DrawRectf.",
					OnChange = on_field("rotation_deg"),
				},
				{
					Key = "geometry/origin_x",
					Text = "Origin X",
					Type = "number",
					Value = state.origin_x,
					Min = -200,
					Max = 200,
					Precision = 1,
					OnChange = on_field("origin_x"),
				},
				{
					Key = "geometry/origin_y",
					Text = "Origin Y",
					Type = "number",
					Value = state.origin_y,
					Min = -200,
					Max = 200,
					Precision = 1,
					OnChange = on_field("origin_y"),
				},
				{
					Key = "geometry/float_coords",
					Text = "Use DrawRectf",
					Type = "boolean",
					Value = state.float_coords,
					Description = "Switches between DrawRect and DrawRectf.",
					OnChange = on_field("float_coords"),
				},
				{
					Key = "geometry/rect_z",
					Text = "Rect Z",
					Type = "number",
					Value = state.rect_z,
					Min = -32,
					Max = 32,
					Precision = 1,
					Description = "Translated onto the z axis before the rect draw to exercise depth mode.",
					OnChange = on_field("rect_z"),
				},
				{
					Key = "geometry/rect_batch_mode",
					Text = "Rect Batch Mode",
					Type = "enum",
					Value = state.rect_batch_mode,
					Options = RECT_BATCH_MODE_OPTIONS,
					Description = "Uses immediate, replay, or instanced rect submission inside the preview panel.",
					OnChange = on_field("rect_batch_mode"),
				},
			},
		},
		{
			Key = "fill",
			Text = "Fill",
			Expanded = true,
			Description = "Core color, texture, and gradient inputs.",
			Children = {
				{
					Key = "fill/color",
					Text = "Color",
					Type = "color",
					Value = state.color,
					Min = Color(0, 0, 0, 0),
					Max = Color(1, 1, 1, 1),
					Precision = 2,
					Description = "Global color multiplier applied to the rect draw.",
					OnChange = on_field("color", copy_color),
				},
				{
					Key = "fill/alpha_multiplier",
					Text = "Alpha Multiplier",
					Type = "number",
					Value = state.alpha_multiplier,
					Min = 0,
					Max = 3,
					Precision = 2,
					OnChange = on_field("alpha_multiplier"),
				},
				{
					Key = "fill/texture_source",
					Text = "Texture",
					Type = "enum",
					Value = state.texture_source,
					Options = TEXTURE_SOURCE_OPTIONS,
					Description = "Texture passed through render2d.SetTexture.",
					OnChange = on_field("texture_source"),
				},
				{
					Key = "fill/gradient_enabled",
					Text = "Gradient Texture",
					Type = "boolean",
					Value = state.gradient_enabled,
					Description = "Toggles render2d.SetSDFGradientTexture for the draw.",
					OnChange = on_field("gradient_enabled"),
				},
				{
					Key = "fill/gradient_source",
					Text = "Gradient Source",
					Type = "enum",
					Value = state.gradient_source,
					Options = GRADIENT_SOURCE_OPTIONS,
					OnChange = on_field("gradient_source"),
				},
			},
		},
		{
			Key = "sampling",
			Text = "UV and Sampling",
			Expanded = true,
			Description = "UV transform, sample flags, swizzle, and nine-patch mapping.",
			Children = {
				{
					Key = "sampling/uv_enabled",
					Text = "Use UV Transform",
					Type = "boolean",
					Value = state.uv_enabled,
					OnChange = on_field("uv_enabled"),
				},
				{
					Key = "sampling/uv_x",
					Text = "UV X",
					Type = "number",
					Value = state.uv_x,
					Min = -512,
					Max = 512,
					Precision = 1,
					OnChange = on_field("uv_x"),
				},
				{
					Key = "sampling/uv_y",
					Text = "UV Y",
					Type = "number",
					Value = state.uv_y,
					Min = -512,
					Max = 512,
					Precision = 1,
					OnChange = on_field("uv_y"),
				},
				{
					Key = "sampling/uv_w",
					Text = "UV W",
					Type = "number",
					Value = state.uv_w,
					Min = 1,
					Max = 512,
					Precision = 1,
					OnChange = on_field("uv_w"),
				},
				{
					Key = "sampling/uv_h",
					Text = "UV H",
					Type = "number",
					Value = state.uv_h,
					Min = 1,
					Max = 512,
					Precision = 1,
					OnChange = on_field("uv_h"),
				},
				{
					Key = "sampling/uv_sx",
					Text = "Source W",
					Type = "number",
					Value = state.uv_sx,
					Min = 1,
					Max = 512,
					Precision = 1,
					OnChange = on_field("uv_sx"),
				},
				{
					Key = "sampling/uv_sy",
					Text = "Source H",
					Type = "number",
					Value = state.uv_sy,
					Min = 1,
					Max = 512,
					Precision = 1,
					OnChange = on_field("uv_sy"),
				},
				{
					Key = "sampling/sample_uv_mode",
					Text = "Sample UV Mode",
					Type = "enum",
					Value = state.sample_uv_mode,
					Options = SAMPLE_UV_MODE_OPTIONS,
					Description = "Bitfield used by texture SDF sampling paths.",
					OnChange = on_field("sample_uv_mode"),
				},
				{
					Key = "sampling/swizzle_mode",
					Text = "Swizzle Mode",
					Type = "enum",
					Value = state.swizzle_mode,
					Options = SWIZZLE_MODE_OPTIONS,
					Description = "Ignored while SDF mode is enabled.",
					OnChange = on_field("swizzle_mode"),
				},
				{
					Key = "sampling/nine_patch_mode",
					Text = "Nine Patch",
					Type = "enum",
					Value = state.nine_patch_mode,
					Options = NINE_PATCH_OPTIONS,
					Description = "Uses either a manual single patch or the source texture's nine_patch table.",
					OnChange = on_field("nine_patch_mode"),
				},
				{
					Key = "sampling/nine_patch_x1",
					Text = "Patch X1",
					Type = "number",
					Value = state.nine_patch_x1,
					Min = 0,
					Max = 128,
					Precision = 1,
					OnChange = on_field("nine_patch_x1"),
				},
				{
					Key = "sampling/nine_patch_y1",
					Text = "Patch Y1",
					Type = "number",
					Value = state.nine_patch_y1,
					Min = 0,
					Max = 128,
					Precision = 1,
					OnChange = on_field("nine_patch_y1"),
				},
				{
					Key = "sampling/nine_patch_x2",
					Text = "Patch X2",
					Type = "number",
					Value = state.nine_patch_x2,
					Min = 0,
					Max = 128,
					Precision = 1,
					OnChange = on_field("nine_patch_x2"),
				},
				{
					Key = "sampling/nine_patch_y2",
					Text = "Patch Y2",
					Type = "number",
					Value = state.nine_patch_y2,
					Min = 0,
					Max = 128,
					Precision = 1,
					OnChange = on_field("nine_patch_y2"),
				},
			},
		},
		{
			Key = "shape",
			Text = "Shape and SDF",
			Expanded = true,
			Description = "Rounded corners, outline, blur, and SDF tuning.",
			Children = {
				{
					Key = "shape/radius_tl",
					Text = "Radius TL",
					Type = "number",
					Value = state.radius_tl,
					Min = 0,
					Max = 128,
					Precision = 1,
					OnChange = on_field("radius_tl"),
				},
				{
					Key = "shape/radius_tr",
					Text = "Radius TR",
					Type = "number",
					Value = state.radius_tr,
					Min = 0,
					Max = 128,
					Precision = 1,
					OnChange = on_field("radius_tr"),
				},
				{
					Key = "shape/radius_br",
					Text = "Radius BR",
					Type = "number",
					Value = state.radius_br,
					Min = 0,
					Max = 128,
					Precision = 1,
					OnChange = on_field("radius_br"),
				},
				{
					Key = "shape/radius_bl",
					Text = "Radius BL",
					Type = "number",
					Value = state.radius_bl,
					Min = 0,
					Max = 128,
					Precision = 1,
					OnChange = on_field("radius_bl"),
				},
				{
					Key = "shape/outline_width",
					Text = "Outline Width",
					Type = "number",
					Value = state.outline_width,
					Min = 0,
					Max = 24,
					Precision = 2,
					OnChange = on_field("outline_width"),
				},
				{
					Key = "shape/blur_x",
					Text = "Blur X",
					Type = "number",
					Value = state.blur_x,
					Min = 0,
					Max = 64,
					Precision = 1,
					OnChange = on_field("blur_x"),
				},
				{
					Key = "shape/blur_y",
					Text = "Blur Y",
					Type = "number",
					Value = state.blur_y,
					Min = 0,
					Max = 64,
					Precision = 1,
					OnChange = on_field("blur_y"),
				},
				{
					Key = "shape/sdf_mode",
					Text = "SDF Mode",
					Type = "boolean",
					Value = state.sdf_mode,
					Description = "Maps to render2d.SetSDFMode and drives texture-SDF sampling when a texture is present.",
					OnChange = on_field("sdf_mode"),
				},
				{
					Key = "shape/sdf_threshold",
					Text = "SDF Threshold",
					Type = "number",
					Value = state.sdf_threshold,
					Min = 0,
					Max = 1,
					Precision = 2,
					OnChange = on_field("sdf_threshold"),
				},
				{
					Key = "shape/sdf_texel_range",
					Text = "SDF Texel Range",
					Type = "number",
					Value = state.sdf_texel_range,
					Min = 1,
					Max = 64,
					Precision = 1,
					OnChange = on_field("sdf_texel_range"),
				},
				{
					Key = "shape/subpixel_mode",
					Text = "Subpixel Mode",
					Type = "enum",
					Value = state.subpixel_mode,
					Options = SUBPIXEL_MODE_OPTIONS,
					OnChange = on_field("subpixel_mode"),
				},
				{
					Key = "shape/subpixel_amount",
					Text = "Subpixel Amount",
					Type = "number",
					Value = state.subpixel_amount,
					Min = 0,
					Max = 1,
					Precision = 3,
					OnChange = on_field("subpixel_amount"),
				},
			},
		},
		{
			Key = "blend",
			Text = "Blend",
			Expanded = true,
			Description = "Preset blend modes plus the full custom render2d blend state table.",
			Children = {
				{
					Key = "blend/use_custom",
					Text = "Use Custom Blend",
					Type = "boolean",
					Value = state.blend_use_custom,
					Description = "When enabled, the preview uses a full SetBlendMode state table instead of a preset name.",
					OnChange = on_field("blend_use_custom"),
				},
				{
					Key = "blend/preset",
					Text = "Preset",
					Type = "enum",
					Value = state.blend_preset,
					Options = BLEND_PRESET_OPTIONS,
					OnChange = on_field("blend_preset"),
				},
				{
					Key = "blend/enabled",
					Text = "Blend Enabled",
					Type = "boolean",
					Value = state.blend_enabled,
					OnChange = on_field("blend_enabled"),
				},
				{
					Key = "blend/src_color",
					Text = "Src Color",
					Type = "enum",
					Value = state.src_color_blend_factor,
					Options = BLEND_FACTOR_OPTIONS,
					OnChange = on_field("src_color_blend_factor"),
				},
				{
					Key = "blend/dst_color",
					Text = "Dst Color",
					Type = "enum",
					Value = state.dst_color_blend_factor,
					Options = BLEND_FACTOR_OPTIONS,
					OnChange = on_field("dst_color_blend_factor"),
				},
				{
					Key = "blend/color_op",
					Text = "Color Op",
					Type = "enum",
					Value = state.color_blend_op,
					Options = BLEND_OP_OPTIONS,
					OnChange = on_field("color_blend_op"),
				},
				{
					Key = "blend/src_alpha",
					Text = "Src Alpha",
					Type = "enum",
					Value = state.src_alpha_blend_factor,
					Options = BLEND_FACTOR_OPTIONS,
					OnChange = on_field("src_alpha_blend_factor"),
				},
				{
					Key = "blend/dst_alpha",
					Text = "Dst Alpha",
					Type = "enum",
					Value = state.dst_alpha_blend_factor,
					Options = BLEND_FACTOR_OPTIONS,
					OnChange = on_field("dst_alpha_blend_factor"),
				},
				{
					Key = "blend/alpha_op",
					Text = "Alpha Op",
					Type = "enum",
					Value = state.alpha_blend_op,
					Options = BLEND_OP_OPTIONS,
					OnChange = on_field("alpha_blend_op"),
				},
				{
					Key = "blend/write_r",
					Text = "Write R",
					Type = "boolean",
					Value = state.color_write_r,
					OnChange = on_field("color_write_r"),
				},
				{
					Key = "blend/write_g",
					Text = "Write G",
					Type = "boolean",
					Value = state.color_write_g,
					OnChange = on_field("color_write_g"),
				},
				{
					Key = "blend/write_b",
					Text = "Write B",
					Type = "boolean",
					Value = state.color_write_b,
					OnChange = on_field("color_write_b"),
				},
				{
					Key = "blend/write_a",
					Text = "Write A",
					Type = "boolean",
					Value = state.color_write_a,
					OnChange = on_field("color_write_a"),
				},
			},
		},
		{
			Key = "pipeline",
			Text = "Depth, Stencil and Clip",
			Expanded = true,
			Description = "The preview includes a depth-writing reference plate, stencil visualization, and an optional scissor overlay.",
			Children = {
				{
					Key = "pipeline/depth_mode",
					Text = "Depth Mode",
					Type = "enum",
					Value = state.depth_mode,
					Options = DEPTH_MODE_OPTIONS,
					OnChange = on_field("depth_mode"),
				},
				{
					Key = "pipeline/depth_write",
					Text = "Depth Write",
					Type = "boolean",
					Value = state.depth_write,
					OnChange = on_field("depth_write"),
				},
				{
					Key = "pipeline/stencil_mode",
					Text = "Stencil Mode",
					Type = "enum",
					Value = state.stencil_mode,
					Options = STENCIL_MODE_OPTIONS,
					Description = "Write-like modes are visualized by an extra overlay because those modes suppress color writes.",
					OnChange = on_field("stencil_mode"),
				},
				{
					Key = "pipeline/stencil_ref",
					Text = "Stencil Ref",
					Type = "number",
					Value = state.stencil_ref,
					Min = 1,
					Max = 8,
					Precision = 0,
					OnChange = on_field("stencil_ref", function(value)
						return math.max(1, math.floor((tonumber(value) or 1) + 0.5))
					end),
				},
				{
					Key = "pipeline/scissor_enabled",
					Text = "Scissor",
					Type = "boolean",
					Value = state.scissor_enabled,
					OnChange = on_field("scissor_enabled"),
				},
				{
					Key = "pipeline/scissor_x",
					Text = "Scissor X",
					Type = "number",
					Value = state.scissor_x,
					Min = 0,
					Max = 420,
					Precision = 1,
					OnChange = on_field("scissor_x"),
				},
				{
					Key = "pipeline/scissor_y",
					Text = "Scissor Y",
					Type = "number",
					Value = state.scissor_y,
					Min = 0,
					Max = 320,
					Precision = 1,
					OnChange = on_field("scissor_y"),
				},
				{
					Key = "pipeline/scissor_w",
					Text = "Scissor W",
					Type = "number",
					Value = state.scissor_w,
					Min = 1,
					Max = 420,
					Precision = 1,
					OnChange = on_field("scissor_w"),
				},
				{
					Key = "pipeline/scissor_h",
					Text = "Scissor H",
					Type = "number",
					Value = state.scissor_h,
					Min = 1,
					Max = 320,
					Precision = 1,
					OnChange = on_field("scissor_h"),
				},
			},
		},
		{
			Key = "actions",
			Text = "Actions",
			Expanded = true,
			Children = {
				{
					Key = "actions/reset",
					Text = "Reset Defaults",
					Type = "action",
					ButtonText = "Reset",
					Description = "Restore the page to its initial rect state.",
					OnAction = function()
						local defaults = make_default_state()

						for key, value in pairs(defaults) do
							state[key] = value
						end

						refresh_preview()
						refresh_editor()
					end,
				},
			},
		},
	}
end

return {
	Name = "render2d rect",
	Create = function()
		local state = make_default_state()
		local editor
		local summary_body
		local property_scroll

		local function refresh_preview()
			set_text(summary_body, build_summary(state))
		end

		local function refresh_editor()
			if editor and editor:IsValid() then
				editor:SetItems(build_items(state, refresh_preview, refresh_editor))
			end
		end

		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 10,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "render2d Rect",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "A property-driven rect preview that applies render2d state directly. The editor covers fill, UVs, swizzle, SDF, nine-patch, blend, depth, stencil, scissor, and rect batching so you can probe how a single DrawRect behaves under different state combinations.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
					AlignmentY = "center",
				},
			}{
				Button{
					Text = "Expand All",
					OnClick = function()
						if editor and editor:IsValid() then editor:ExpandAll() end
					end,
				},
				Button{
					Text = "Collapse All",
					Mode = "outline",
					OnClick = function()
						if editor and editor:IsValid() then editor:CollapseAll() end
					end,
				},
				Button{
					Text = "Reset Demo",
					Mode = "outline",
					OnClick = function()
						local defaults = make_default_state()

						for key, value in pairs(defaults) do
							state[key] = value
						end

						refresh_preview()
						refresh_editor()
					end,
				},
			},
			Splitter{
				InitialSize = 448,
				layout = {
					GrowWidth = 1,
					MinSize = Vec2(0, 620),
					MaxSize = Vec2(0, 620),
				},
			}{
				ScrollablePanel{
					Ref = function(self)
						property_scroll = self
					end,
					ScrollX = false,
					ScrollY = true,
					ScrollBarContentShiftMode = "auto_shift",
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
					},
				}{
					PropertyEditor{
						Ref = function(self)
							editor = self
							self:SetItems(build_items(state, refresh_preview, refresh_editor))
							self:SetSelectedKey("geometry/x")
						end,
						layout = {
							GrowHeight = 1,
							MinSize = Vec2(820, 0),
							MaxSize = Vec2(820, 0),
							FitWidth = false,
						},
					},
				},
				Column{
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						AlignmentX = "stretch",
						ChildGap = 10,
					},
				}{
					Frame{
						Padding = "S",
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
						},
					}{
						Column{
							layout = {
								GrowWidth = 1,
								GrowHeight = 1,
								AlignmentX = "stretch",
								ChildGap = 8,
							},
						}{
							Text{
								Text = "Preview",
								Font = "body_strong S",
								IgnoreMouseInput = true,
							},
							Text{
								Text = "The cyan guide is the scissor region when enabled. The orange plate in the middle writes depth at z=0 so depth mode changes have something to compare against. Stencil write-style modes add an overlay so the result stays visible even though those modes suppress color writes.",
								Wrap = true,
								IgnoreMouseInput = true,
								layout = {
									GrowWidth = 1,
								},
							},
							Panel.New{
								transform = true,
								rect = true,
								layout = {
									GrowWidth = 1,
									GrowHeight = 1,
									MinSize = Vec2(400, 340),
								},
								OnDraw = function(self)
									draw_preview(self, state)
								end,
							},
						},
					},
					Frame{
						Padding = "S",
						layout = {
							GrowWidth = 1,
							FitHeight = true,
						},
					}{
						Column{
							layout = {
								GrowWidth = 1,
								AlignmentX = "stretch",
								ChildGap = 6,
							},
						}{
							Text{
								Text = "Current State",
								Font = "body_strong S",
								IgnoreMouseInput = true,
							},
							Text{
								Ref = function(self)
									summary_body = self
									refresh_preview()
								end,
								Text = build_summary(state),
								Wrap = true,
								IgnoreMouseInput = true,
								layout = {
									GrowWidth = 1,
								},
							},
						},
					},
				},
			},
		}
	end,
}
