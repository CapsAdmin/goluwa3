local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local Texture = import("goluwa/render/texture.lua")
local create_metal_frame = import("goluwa/render/textures/metal_frame.lua")
local Color = import("goluwa/structs/color.lua")
local title_font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 34}
local label_font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 17}
local note_font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 13}
local warm_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = 0,
	stops = {
		{pos = 0.0, color = Color(1.0, 0.52, 0.18, 1.0)},
		{pos = 1.0, color = Color(1.0, 0.88, 0.2, 1.0)},
	},
}
local cool_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = 90,
	stops = {
		{pos = 0.0, color = Color(0.2, 0.86, 1.0, 1.0)},
		{pos = 1.0, color = Color(0.22, 0.34, 1.0, 1.0)},
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
		vec3 base = mix(vec3(0.13, 0.16, 0.28), vec3(0.78, 0.86, 1.0), checker);
		float stripe = smoothstep(0.45, 0.55, abs(sin((uv.x + uv.y) * 18.0)));
		base = mix(base, vec3(1.0, 0.48, 0.24), stripe * 0.35);
		return vec4(base, 1.0);
]])
local metal_frame_texture = create_metal_frame{
	width = 256,
	height = 256,
	base_color = {r = 0.71, g = 0.74, b = 0.78},
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

local function with_rect_batch_mode(mode, callback)
	local old_mode = render2d.GetRectBatchMode()
	local ok, err
	render2d.SetRectBatchMode(mode)
	ok, err = xpcall(callback, debug.traceback)
	render2d.SetRectBatchMode(old_mode)

	if not ok then error(err, 0) end
end

local function draw_label(text, x, y, color)
	render2d.PushColor(color[1], color[2], color[3], color[4] or 1)

	with_rect_batch_mode("replay", function()
		label_font:DrawText(text, x, y)
	end)

	render2d.PopColor()
end

local function draw_note(text, x, y, color)
	render2d.PushColor(color[1], color[2], color[3], color[4] or 1)

	with_rect_batch_mode("replay", function()
		note_font:DrawText(text, x, y)
	end)

	render2d.PopColor()
end

local function draw_background(w, h)
	render2d.SetTexture(nil)
	render2d.PushColor(0.045, 0.05, 0.08, 1)
	render2d.DrawRect(0, 0, w, h)
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.055)
	render2d.PushSDFGradientTexture(cool_gradient)
	render2d.PushBorderRadius(30)
	render2d.DrawRect(28, 28, w - 56, h - 56)
	render2d.PopBorderRadius()
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
end

local function draw_card(x, y, w, h, title, note)
	render2d.PushColor(0.075, 0.09, 0.14, 0.95)
	render2d.PushBorderRadius(18)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.09)
	render2d.PushOutlineWidth(1)
	render2d.PushBorderRadius(18)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
	draw_label(title, x + 16, y + 14, {0.96, 0.97, 0.99, 1})
	draw_note(note, x + 16, y + 38, {0.66, 0.74, 0.84, 1})
end

local function draw_plain_state(x, y)
	render2d.PushColor(0.16, 0.64, 1.0, 1)
	render2d.DrawRect(x + 16, y + 74, 88, 70)
	render2d.PopColor()
	render2d.PushColor(1.0, 0.56, 0.24, 0.92)
	render2d.PushBorderRadius(18, 6, 24, 6)
	render2d.DrawRect(x + 114, y + 74, 112, 70)
	render2d.PopBorderRadius()
	render2d.PopColor()
end

local function draw_gradient_outline_state(x, y)
	render2d.PushColor(1, 1, 1, 1)
	render2d.PushSDFGradientTexture(warm_gradient)
	render2d.PushBorderRadius(22)
	render2d.DrawRect(x + 22, y + 78, 204, 66)
	render2d.PopBorderRadius()
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.16)
	render2d.PushOutlineWidth(2.5)
	render2d.PushBorderRadius(22)
	render2d.DrawRect(x + 22, y + 78, 204, 66)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
end

local function draw_blur_shadow_state(x, y, phase)
	render2d.PushColor(0.1, 0.68, 1.0, 0.65)
	render2d.PushBlur(26)
	render2d.PushBlendMode("additive")
	render2d.PushBorderRadius(30)
	render2d.DrawRect(x + 28 + math.cos(phase) * 8, y + 82, 188, 58)
	render2d.PopBorderRadius()
	render2d.PopBlendMode()
	render2d.PopBlur()
	render2d.PopColor()
	render2d.PushColor(0.18, 0.22, 0.34, 1)
	render2d.PushBorderRadius(30)
	render2d.DrawRect(x + 32, y + 90, 180, 44)
	render2d.PopBorderRadius()
	render2d.PopColor()
end

local function draw_texture_uv_state(x, y, phase)
	render2d.PushTexture(pattern_texture)
	render2d.PushColor(1, 1, 1, 1)
	render2d.PushBorderRadius(18)
	render2d.PushUV(0, 0, 96, 96, 96, 96)
	render2d.DrawRect(x + 16, y + 76, 92, 68)
	render2d.PopUV()
	render2d.PushUV(phase * 18, phase * 11, 48, 96, 96, 96)
	render2d.DrawRect(x + 122, y + 76, 104, 68)
	render2d.PopUV()
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PopTexture()
end

local function draw_scissor_state(x, y, phase)
	render2d.PushColor(0.11, 0.14, 0.2, 1)
	render2d.PushBorderRadius(16)
	render2d.DrawRect(x + 18, y + 74, 208, 72)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushScissor(x + 18, y + 74, 208, 72)
	render2d.PushColor(0.2, 0.82, 1.0, 0.65)
	render2d.PushBlur(12)
	render2d.DrawRect(x + 12 + math.sin(phase) * 40, y + 82, 120, 54)
	render2d.PopBlur()
	render2d.PopColor()
	render2d.PushColor(1.0, 0.45, 0.28, 0.9)
	render2d.PushBorderRadius(14)
	render2d.DrawRect(x + 96 + math.cos(phase * 0.7) * 30, y + 84, 94, 48)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PopScissor()
	render2d.PushColor(1, 1, 1, 0.08)
	render2d.PushOutlineWidth(1)
	render2d.PushBorderRadius(16)
	render2d.DrawRect(x + 18, y + 74, 208, 72)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
end

local function draw_sdf_state(x, y, phase)
	render2d.PushColor(1, 1, 1, 1)
	render2d.PushSDFMode(true)
	render2d.PushSDFTexelRange(18)
	render2d.PushSDFThreshold(0.55 + math.sin(phase * 1.3) * 0.08)
	render2d.PushBorderRadius(28)
	render2d.PushBlur(4)
	render2d.PushOutlineWidth(2.25)
	render2d.PushSDFGradientTexture(cool_gradient)
	render2d.DrawRect(x + 24, y + 76, 196, 68)
	render2d.PopSDFGradientTexture()
	render2d.PopOutlineWidth()
	render2d.PopBlur()
	render2d.PopBorderRadius()
	render2d.PopSDFThreshold()
	render2d.PopSDFTexelRange()
	render2d.PopSDFMode()
	render2d.PopColor()
end

local function draw_stencil_mask_shapes(base_x, base_y, phase)
	local offset = math.sin(phase * 0.7) * 6
	render2d.PushBorderRadius(18)
	render2d.DrawRect(base_x + 20 + offset, base_y + 5, 34, 32)
	render2d.PopBorderRadius()
	render2d.PushBorderRadius(8)
	render2d.DrawRect(base_x + 48, base_y + 12, 26, 18)
	render2d.PopBorderRadius()
end

local function draw_stencil_state(x, y, phase)
	local preview_x = x + 18
	local preview_y = y + 74
	local preview_w = 208
	local preview_h = 72
	local inner_y = preview_y + 18
	local pane_w = 92
	local pane_h = 42
	local pane_gap = 12
	local mask_x = preview_x + 8
	local result_x = mask_x + pane_w + pane_gap
	local pane_y = inner_y + 10
	render2d.PushColor(0.09, 0.11, 0.17, 1)
	render2d.PushBorderRadius(16)
	render2d.DrawRect(preview_x, preview_y, preview_w, preview_h)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.08)
	render2d.PushOutlineWidth(1)
	render2d.PushBorderRadius(16)
	render2d.DrawRect(preview_x, preview_y, preview_w, preview_h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
	draw_note("mask", mask_x + 26, inner_y - 2, {0.78, 0.84, 0.93, 1})
	draw_note("result", result_x + 22, inner_y - 2, {0.78, 0.84, 0.93, 1})
	render2d.PushColor(0.12, 0.15, 0.22, 1)
	render2d.PushBorderRadius(12)
	render2d.DrawRect(mask_x, pane_y, pane_w, pane_h)
	render2d.DrawRect(result_x, pane_y, pane_w, pane_h)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.08)
	render2d.PushOutlineWidth(1)
	render2d.PushBorderRadius(12)
	render2d.DrawRect(mask_x, pane_y, pane_w, pane_h)
	render2d.DrawRect(result_x, pane_y, pane_w, pane_h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
	render2d.PushColor(0.4, 0.84, 1.0, 0.22)
	draw_stencil_mask_shapes(mask_x, pane_y, phase)
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.18)
	render2d.PushOutlineWidth(1.25)
	draw_stencil_mask_shapes(mask_x, pane_y, phase)
	render2d.PopOutlineWidth()
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.08)
	render2d.PushSDFGradientTexture(cool_gradient)
	render2d.DrawRect(result_x + 3, pane_y + 3, pane_w - 6, pane_h - 6)
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
	render2d.PushColor(1.0, 0.52, 0.26, 0.18)
	render2d.PushBorderRadius(12)
	render2d.DrawRect(result_x - 6 + math.sin(phase) * 26, pane_y + 11, 62, 20)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushTexture(pattern_texture)
	render2d.PushColor(1, 1, 1, 0.16)
	render2d.PushUV(phase * 12, phase * 8, 96, 96, 96, 96)
	render2d.DrawRect(result_x + 34, pane_y + 6, 58, 28)
	render2d.PopUV()
	render2d.PopColor()
	render2d.PopTexture()
	render2d.ClearStencil(0)
	render2d.PushStencilMask()
	draw_stencil_mask_shapes(result_x, pane_y, phase)
	render2d.BeginStencilTest()
	render2d.PushColor(1, 1, 1, 1)
	render2d.PushSDFGradientTexture(cool_gradient)
	render2d.DrawRect(result_x + 3, pane_y + 3, pane_w - 6, pane_h - 6)
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
	render2d.PushColor(1.0, 0.52, 0.26, 0.9)
	render2d.PushBorderRadius(12)
	render2d.DrawRect(result_x - 6 + math.sin(phase) * 26, pane_y + 11, 62, 20)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushTexture(pattern_texture)
	render2d.PushColor(1, 1, 1, 0.82)
	render2d.PushUV(phase * 12, phase * 8, 96, 96, 96, 96)
	render2d.DrawRect(result_x + 34, pane_y + 6, 58, 28)
	render2d.PopUV()
	render2d.PopColor()
	render2d.PopTexture()
	render2d.SetStencilMode("test_inverse", 1)
	render2d.PushColor(0.03, 0.04, 0.06, 0.5)
	render2d.DrawRect(result_x, pane_y, pane_w, pane_h)
	render2d.PopColor()
	render2d.PopStencilMask()
	render2d.PushColor(1, 1, 1, 0.2)
	render2d.PushOutlineWidth(1.5)
	draw_stencil_mask_shapes(result_x, pane_y, phase)
	render2d.PopOutlineWidth()
	render2d.PopColor()
end

local function draw_ninepatch_state(x, y)
	render2d.PushColor(0.08, 0.1, 0.15, 0.9)
	render2d.PushBorderRadius(16)
	render2d.DrawRect(x + 24, y + 82, 196, 58)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushTexture(metal_frame_texture)
	render2d.PushColor(1, 1, 1, 1)
	render2d.SetNinePatchTable(metal_frame_texture.nine_patch)
	render2d.DrawRect(x + 18, y + 76, 208, 70)
	render2d.ClearNinePatch()
	render2d.PopColor()
	render2d.PopTexture()
	draw_note("generated metal frame keeps corners stable", x + 34, y + 104, {1, 1, 1, 0.72})
end

event.AddListener("Draw2D", "render2d_rect_state_showcase", function()
	local width = render.GetWidth()
	local height = render.GetHeight()
	local phase = os.clock() * 1.3
	local rect_batch_mode = math.floor(os.clock()) % 2 == 0 and "instanced" or "replay"
	local panel_w = 244
	local panel_h = 164
	local gap = 20
	local origin_x = math.max(36, math.floor((width - (panel_w * 3 + gap * 2)) * 0.5))
	local origin_y = 126

	with_rect_batch_mode(rect_batch_mode, function()
		draw_background(width, height)
	end)

	render2d.PushColor(0.98, 0.99, 1.0, 1)

	with_rect_batch_mode("replay", function()
		title_font:DrawText("render2d rect state showcase", origin_x, 38)
	end)

	render2d.PopColor()
	draw_note(
		"Each card isolates a rect-heavy state combination to use as a visual batching regression scene.",
		origin_x,
		78,
		{0.73, 0.8, 0.88, 1}
	)
	draw_note("mode: " .. rect_batch_mode, origin_x, 96, {0.58, 0.78, 0.95, 1})
	local cards = {
		{"plain + radius", "base color and asymmetric corners", draw_plain_state},
		{
			"gradient + outline",
			"gradient texture with outline width",
			draw_gradient_outline_state,
		},
		{
			"blur + additive",
			"glow and soft edge over a solid core",
			function(x, y)
				draw_blur_shadow_state(x, y, phase)
			end,
		},
		{
			"texture + uv",
			"same texture with different UV windows",
			function(x, y)
				draw_texture_uv_state(x, y, phase)
			end,
		},
		{
			"scissor clip",
			"animated content clipped to the panel",
			function(x, y)
				draw_scissor_state(x, y, phase)
			end,
		},
		{
			"sdf rect",
			"SDF threshold, blur, outline, and gradient",
			function(x, y)
				draw_sdf_state(x, y, phase)
			end,
		},
		{
			"stencil mask",
			"bright content is clipped by the outlined mask",
			function(x, y)
				draw_stencil_state(x, y, phase)
			end,
		},
		{"nine-patch", "stretch center while corners stay stable", draw_ninepatch_state},
	}

	for i, info in ipairs(cards) do
		local col = (i - 1) % 3
		local row = math.floor((i - 1) / 3)
		local x = origin_x + col * (panel_w + gap)
		local y = origin_y + row * (panel_h + gap)

		with_rect_batch_mode(rect_batch_mode, function()
			draw_card(x, y, panel_w, panel_h, info[1], info[2])
			info[3](x, y)
		end)
	end
end)
