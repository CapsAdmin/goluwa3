local event = require("event")
local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local gfx = require("render2d.gfx")
local fonts = require("render2d.fonts")
local system = require("system")
local window = require("window")
local font_small = fonts.LoadFont(fonts.GetSystemDefaultFont(), 14)
local font_medium = fonts.LoadFont(fonts.GetSystemDefaultFont(), 24)
local font_large = fonts.LoadFont(fonts.GetSystemDefaultFont(), 48)
local font_sdf = fonts.LoadFont(fonts.GetSystemDefaultFont(), 64)
font_sdf:SetSDF(true)
local wrap_text = "The quick brown fox jumps over the lazy dog. This is a very long string that should be wrapped according to the dynamic width of the box. Notice how the layout adjusts as the box size changes over time."

local function draw_debug_text(font, text, x, y, align_x, align_y)
	local w, h = font:GetTextSize(text)
	-- Draw background/debug rect
	render2d.SetColor(1, 0, 0, 0.2)
	render2d.SetTexture(nil)
	local box_x, box_y = x, y

	if type(align_x) == "number" then
		box_x = x - (w * align_x)
	elseif align_x == "center" then
		box_x = x - (w / 2)
	elseif align_x == "right" then
		box_x = x - w
	end

	if type(align_y) == "number" then
		box_y = y - (h * align_y)
	elseif align_y == "baseline" then
		box_y = y - font:GetAscent()
	elseif align_y == "center" then
		box_y = y - (h / 2)
	elseif align_y == "bottom" then
		box_y = y - h
	end

	render2d.DrawRect(box_x, box_y, w, h)
	-- Draw text
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText(text, x, y, nil, align_x, align_y)
end

event.AddListener("Draw2D", "text_demo", function()
	local time = system.GetTime()
	local win_w, win_h = window.GetSize():Unpack()
	-- Background
	render2d.SetColor(0.1, 0.1, 0.1, 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(0, 0, win_w, win_h)
	local x = 50
	local y = 50
	-- Basic scaling
	draw_debug_text(font_small, "Small Font (14px)", x, y)
	y = y + 30
	draw_debug_text(font_medium, "Medium Font (24px)", x, y)
	y = y + 50
	draw_debug_text(font_large, "Large Font (48px)", x, y)
	y = y + 80
	-- Alignment demo
	local align_y_pos = y + 50
	render2d.SetColor(0.5, 0.5, 0.5, 0.5)
	render2d.DrawRect(win_w / 2, align_y_pos - 100, 1, 200) -- vertical guide
	render2d.DrawRect(0, align_y_pos, win_w, 1) -- horizontal guide
	draw_debug_text(font_medium, "Left", win_w / 2, align_y_pos, "left", "baseline")
	draw_debug_text(font_medium, "Center", win_w / 2, align_y_pos + 40, "center", "baseline")
	draw_debug_text(font_medium, "Right", win_w / 2, align_y_pos + 80, "right", "baseline")
	-- Wrapping demo
	y = align_y_pos + 150
	local wrap_width = 300 + math.sin(time) * 200
	local mixed_text = "Mixed Unicode Wrapping: " .. wrap_text .. " こんにちわ、システムが正常に動作しています。"
	local wrapped = font_small:WrapString(mixed_text, wrap_width)
	-- Draw wrap boundary
	render2d.SetColor(0.3, 0.3, 0.3, 0.5)
	render2d.DrawRect(x, y, wrap_width, 2)
	draw_debug_text(font_small, wrapped, x, y + 10)
	-- Measurement info
	local space_w, _ = font_medium:GetTextSize(" ")
	local tab_w, _ = font_medium:GetTextSize("\t")
	local nl_w, nl_h = font_medium:GetTextSize("\n") -- Note: \n width is 0 usually
	local info_text = string.format(
		"Font Size: %d\n" .. "Wrap Width: %.2f\n" .. "Ascent: %.2f\n" .. "Descent: %.2f\n" .. "Line Height: %.2f\n" .. "Space Width: %.2f\n" .. "Tab Width: %.2f",
		font_medium:GetSize(),
		wrap_width,
		font_medium:GetAscent(),
		font_medium:GetDescent(),
		font_medium:GetLineHeight(),
		space_w,
		tab_w
	)
	font_small:DrawText(info_text, win_w - 200, 40)
	-- Tab demo
	local tab_text = "Tabs:\n1\tOne\n10\tTen\n100\tHundred"
	font_small:DrawText(tab_text, win_w - 200, 200)
	-- Visual breakdown of special char sizes
	local special_y = 280
	local label_font = font_small
	local value_font = font_medium

	local function draw_size_vis(label, str, x, y)
		local w, h = value_font:GetTextSize(str)
		label_font:DrawText(label, x, y)
		-- Draw the char with a visible box
		render2d.SetColor(0.2, 0.5, 1, 0.3)
		render2d.DrawRect(x + 80, y, w, h)
		render2d.SetColor(1, 1, 1, 1)
		value_font:DrawText(str, x + 80, y)
		label_font:DrawText(string.format("Width: %.1f", w), x + 130, y + 5)
	end

	draw_size_vis("Space:", " ", win_w - 200, special_y)
	draw_size_vis("Tab:", "\t", win_w - 200, special_y + 30)
	-- Newline height visual (using | to show height)
	local lh = value_font:GetLineHeight()
	label_font:DrawText("NL Height:", win_w - 200, special_y + 60)
	render2d.SetColor(0.2, 1, 0.5, 0.3)
	render2d.DrawRect(win_w - 120, special_y + 60, 10, lh)
	label_font:DrawText(string.format("%.1f", lh), win_w - 105, special_y + 65)
	-- Unicode demo
	local unicode_text = "Unicode Support:\n" .. "Japanese: こんにちは世界\n" .. "Emoji: 🚀 🎮 🎵 🔥\n" .. "Symbols: ± ∑ √ ∞ ≈\n" .. "European: àéîöù ñ ç"
	font_medium:DrawText(unicode_text, win_w - 400, 350)
end)

-- Effects example (Static)
local font_shaded = fonts.LoadFont(fonts.GetSystemDefaultFont(), 48)
font_shaded:SetShadingInfo(
	{
		{
			source = [[
            vec4 col = texture(self, uv);
            // Simple rainbow effect based on UV
            col.rgb *= vec3(uv.x, uv.y, 1.0 - uv.x);
            return col;
        ]],
			vars = {},
		},
	}
)

event.AddListener("Draw2D", "text_effects_demo", function()
	local win_w, win_h = window.GetSize():Unpack()
	font_shaded:DrawText("Legacy Supersampled Shader", 50, win_h - 150)
end)

event.AddListener("Draw2D", "text_sdf_demo", function()
	local time = system.GetTime()
	local win_w, win_h = window.GetSize():Unpack()
	local y_pos = win_h - 400
	font_medium:DrawText("Dynamic SDF Rendering (New):", 50, y_pos)
	y_pos = y_pos + 60
	-- 1. DROP SHADOW DEMO
	font_sdf:SetSDFShadowColor(Color(0, 0, 0, 0.8))
	font_sdf:SetSDFShadowOffset(Vec2(4, 4))
	font_sdf:SetSDFFeather(1)
	font_sdf:SetSDFThreshold(0.5)
	font_sdf:SetSDFGradientColor(Color(0, 0, 0, 0)) -- Disable gradient
	render2d.SetColor(1, 1, 1, 1)
	font_sdf:DrawText("SDF Drop Shadow", 50, y_pos)
	y_pos = y_pos + 80
	-- 2. GRADIENT + GLOW DEMO
	local r = 0.5 + 0.5 * math.sin(time * 2)
	local g = 0.5 + 0.5 * math.sin(time * 2 + 2)
	local b = 0.5 + 0.5 * math.sin(time * 2 + 4)
	font_sdf:SetSDFGradientColor(Color(r, g, b, 1))
	font_sdf:SetSDFShadowColor(Color(r, g, b, 0.4))
	font_sdf:SetSDFShadowOffset(Vec2(0, 0))
	font_sdf:SetSDFFeather(5 + math.sin(time * 3) * 3) -- Softness animation
	render2d.SetColor(1, 1, 1, 1)
	font_sdf:DrawText("SDF Gradient & Glow", 50, y_pos)
	y_pos = y_pos + 80
	-- 3. THICKNESS (THRESHOLD) ANIMATION
	font_sdf:SetSDFFeather(1)
	font_sdf:SetSDFGradientColor(Color(1, 0.8, 0.2, 1)) -- Gold gradient
	font_sdf:SetSDFShadowColor(Color(0, 0, 0, 0.5))
	font_sdf:SetSDFShadowOffset(Vec2(2, 2))
	local thickness = 0.5 + math.sin(time * 4) * 0.15
	font_sdf:SetSDFThreshold(thickness)
	render2d.SetColor(1, 0.5, 0, 1)
	font_sdf:DrawText("Variable Thickness Pulsing", 50, y_pos)
end)
