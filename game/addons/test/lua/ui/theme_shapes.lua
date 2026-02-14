local event = require("event")
local render2d = require("render2d.render2d")
local Texture = require("render.texture")
local gfx = require("render2d.gfx")
local Color = require("structs.color")
local window = require("window")
local system = require("system")
local fonts = require("render2d.fonts")
local gradient_linear = require("render.textures.gradient_linear")
local glow_linear = require("render.textures.glow_linear")
local glow_point = require("render.textures.glow_point")
local Vec2 = require("structs.vec2")
local theme = library()

function theme.DrawDiamond(x, y, size)
	render2d.PushMatrix()
	render2d.Translatef(x, y)
	render2d.Rotate(math.rad(45))
	render2d.DrawRectf(-size / 2, -size / 2, size, size)
	render2d.PopMatrix()
end

function theme.DrawDiamond2(x, y, size)
	local s = size
	theme.DrawDiamond(x, y, s / 3)
	render2d.PushOutlineWidth(1)
	theme.DrawDiamond(x, y, s)
	render2d.PopOutlineWidth()
end

function theme.DrawPill1(x, y, w, h)
	x = x - 15
	w = w + 30
	render2d.PushBorderRadius(h)
	render2d.DrawRect(x, y, w, h)
	render2d.SetBorderRadius(h / 2)
	render2d.PushOutlineWidth(1)
	render2d.PushBlendMode("additive")
	render2d.PushAlphaMultiplier(1)
	render2d.DrawRect(x, y, w, h)
	render2d.PopAlphaMultiplier()
	render2d.PopBlendMode()
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
	local s = 5
	local offset = 1
	theme.DrawDiamond2(x, y + h / 2, s)
	theme.DrawDiamond2(x + w, y + h / 2, s)
end

function theme.DrawBadge(x, y, w, h)
	x = x - 15
	w = w + 30
	render2d.PushTexture(gradient_linear)
	render2d.PushUV()
	render2d.SetUV2(-0.1, 0, 0.75, 1)
	render2d.PushBorderRadius(h)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopUV()
	render2d.PopTexture()
	render2d.PushColor(1, 1, 1, 1)
	local s = 8
	local offset = -s
	theme.DrawDiamond2(x - offset, y + h / 2, s)
	render2d.PopColor()
end

function theme.DrawArrow(x, y, size)
	local f = size / 2
	render2d.PushBorderRadius(f * 3, f * 2, f * 2, f * 3)
	render2d.PushMatrix()
	render2d.Translatef(x - size / 3, y - size / 3)
	render2d.Scalef(1.6, 0.75)
	render2d.DrawRectf(0, 0, size * 1, size)
	render2d.PopMatrix()
	render2d.PopBorderRadius()
	theme.DrawDiamond(x, y + 0.5, size / 2)
end

function theme.DrawLine(x1, y1, x2, y2, thickness)
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	local s = thickness * 2
	theme.DrawDiamond(x1, y1, s)
	theme.DrawDiamond(x2, y2, s)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRect(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

function theme.DrawLine2(x1, y1, x2, y2, thickness)
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	local s = thickness * 4
	render2d.PushMatrix()
	render2d.Translatef(x1, y1 + 1)
	render2d.Rotate(math.pi)
	theme.DrawArrow(0, 0, s)
	render2d.PopMatrix()
	theme.DrawArrow(x2, y2, s)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRect(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

do
	local create_glow_line = require("render.textures.glow_line")
	local glow_line = create_glow_line(1, 9, 0.2) -- 1px thick line, 10px fade on each side
	function theme.DrawGlowLine(x1, y1, x2, y2, thickness)
		thickness = thickness or 1
		local angle = math.atan2(y2 - y1, x2 - x1)
		local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
		render2d.PushMatrix()
		render2d.Translatef(x1, y1)
		render2d.Rotate(angle)
		render2d.Translatef(0, -glow_line:GetHeight() / 2)
		render2d.SetTexture(glow_line)
		render2d.PushBlendMode("additive")
		render2d.DrawRectf(0, -thickness / 10, length, glow_line:GetHeight())
		render2d.PopBlendMode()
		render2d.PopMatrix()
	end
end

do
	local gradient_classic = Texture.New(
		{
			width = 16,
			height = 16,
			format = "r8g8b8a8_unorm",
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	)
	local start = Color.FromHex("#060086")
	local stop = Color.FromHex("#04013e")
	gradient_classic:Shade(
		[[
			float dist = distance(uv, vec2(0.5));
				return vec4(mix(vec3(]] .. start.r .. ", " .. start.g .. ", " .. start.b .. "), vec3(" .. stop.r .. ", " .. stop.g .. ", " .. stop.b .. [[), -uv.y + 1.0), 1.0);
		]]
	)
	local create_metal_frame = require("render.textures.metal_frame")
	local metal_frame = create_metal_frame({
		base_color = Color.FromHex("#8f8b92"),
	})

	function theme.DrawClassicFrame(x, y, w, h)
		render2d.PushBorderRadius(h * 0.2)
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetTexture(gradient_classic)
		render2d.DrawRect(x, y, w, h)
		render2d.PopBorderRadius()

		do
			render2d.PushOutlineWidth(5)
			render2d.PushBlur(10)
			render2d.SetColor(0, 0, 0, 0.5)
			render2d.SetTexture(nil)
			render2d.DrawRect(x, y, w, h)
			render2d.PopBlur()
			render2d.PopOutlineWidth()
		end

		x = x - 3
		y = y - 3
		w = w + 6
		h = h + 6

		do
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetNinePatchTable(metal_frame.nine_patch)
			render2d.SetTexture(metal_frame)
			render2d.DrawRect(x, y, w, h)
			render2d.ClearNinePatch()
			render2d.SetTexture(nil)
		end
	end
end

do
	local start = Color.FromHex("#060086")
	local stop = Color.FromHex("#04013e")
	local create_metal_frame = require("render.textures.metal_frame")
	local metal_frame = create_metal_frame(
		{
			base_color = Color.FromHex("#8f8b92"),
			frame_inner = 0.02,
			frame_outer = 0.002,
			corner_radius = 0.02,
		}
	)

	function theme.DrawWhiteFrame(x, y, w, h)
		render2d.PushBorderRadius(h * 0.2)
		render2d.SetColor(1, 1, 1, 0.5)
		render2d.SetTexture(nil)
		render2d.DrawRect(x, y, w, h)
		x = x + 1
		y = y + 1
		w = w - 2
		h = h - 2

		do
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetNinePatchTable(metal_frame.nine_patch)
			render2d.SetTexture(metal_frame)
			render2d.DrawRect(x, y, w, h)
			render2d.ClearNinePatch()
			render2d.SetTexture(nil)
			render2d.PushOutlineWidth(1)
			render2d.DrawRect(x + 1, y + 1, w - 2, h - 2)
			render2d.PopOutlineWidth()
		end

		render2d.PopBorderRadius()
	end
end

do
	local blur_color = Color.FromHex("#2374DD")
	theme.HeadingFont = fonts.New(
		{
			Path = "/home/caps/Downloads/Exo_2/static/Exo2-Bold.ttf",
			Size = 30,
			Padding = 20,
			SeparateEffects = true,
			Effects = {
				{
					Type = "shadow",
					Dir = -1.5,
					Color = Color.FromHex("#0c1721"),
					BlurRadius = 0.25,
					BlurPasses = 1,
				},
				{
					Type = "shadow",
					Dir = 0,
					Color = blur_color,
					BlurRadius = 3,
					BlurPasses = 3,
					AlphaPow = 0.6,
				},
			},
		}
	)
end

function theme.DrawCircle(x, y, size, width)
	render2d.PushBorderRadius(size)
	render2d.PushOutlineWidth(width or 1)
	render2d.DrawRect(x - size, y - size, size * 2, size * 2)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
end

function theme.DrawSimpleLine(x1, y1, x2, y2, thickness)
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRectf(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

function theme.DrawMagicCircle(x, y, size)
	render2d.PushBlur(size * 0.05)
	theme.DrawCircle(x, y, size, 4)
	theme.DrawCircle(x, y, size * 1.5)
	theme.DrawCircle(x, y, size * 1.7)
	theme.DrawCircle(x, y, size * 3)
	render2d.PopBlur()

	for i = 1, 8 do
		local angle = (i / 8) * math.pi * 2
		local length = size * 1.35
		local x1 = x + math.cos(angle) * length
		local y1 = y + math.sin(angle) * length
		theme.DrawDiamond(x1, y1, 3)
	end

	for i = 1, 16 do
		local angle = (i / 16) * math.pi * 2
		local length = size * 1.35
		local x1 = x + math.cos(angle) * length
		local y1 = y + math.sin(angle) * length
		local x2 = x + math.cos(angle) * length * 1.5
		local y2 = y + math.sin(angle) * length * 1.5
		render2d.SetTexture(glow_linear)
		theme.DrawGlowLine(x1, y1, x2, y2, 1)
	end
end

function theme.DrawGlow(x, y, size)
	render2d.PushTexture(glow_point)
	render2d.PushAlphaMultiplier(0.5)
	render2d.DrawRectf(x - size, y - size, size * 2, size * 2)
	render2d.PopAlphaMultiplier()
	render2d.PopTexture()
end

function theme.DrawProgressBar(x, y, w, h, progress, color)
	-- Background Frame
	render2d.SetColor(0.2, 0.2, 0.3, 0.4)
	render2d.DrawRect(x, y, w, h)
	-- Top/Bottom glow lines
	render2d.PushBlendMode("additive")
	render2d.SetColor(0.3, 0.4, 0.6, 0.5)
	theme.DrawGlowLine(x, y, x + w, y, 2)
	theme.DrawGlowLine(x, y + h, x + w, y + h, 2)
	-- Vertical dividers every 10%
	render2d.SetColor(1, 1, 1, 0.1)
	local div_w = w / 10

	for i = 1, 9 do
		local dx = x + div_w * i
		render2d.DrawRect(dx, y, 1, h)
	end

	render2d.PopBlendMode()

	-- Fill
	if progress > 0 then
		local fill_w = w * progress
		local center_y = y + h / 2
		local tip_x = x + fill_w
		-- Main bar gradient
		render2d.PushTexture(gradient_linear)

		if color then
			render2d.SetColor(color.r, color.g, color.b, (color.a or 1) * 0.8)
		else
			render2d.SetColor(0.4, 0.7, 1, 0.8)
		end

		-- Rotate gradient for a slash effect? Maybe just linear for now
		render2d.DrawRect(x, y, fill_w, h)
		render2d.PopTexture()
		-- Additive glow layer over the bar
		render2d.PushBlendMode("additive")
		-- Highlight top edge of the filled part
		render2d.SetColor(1, 1, 1, 0.6)
		render2d.DrawRect(x, y, fill_w, 2)

		-- Tip decoration (Diamond / Sci-Fi marker)
		-- Color for the tip
		if color then
			render2d.SetColor(color.r, color.g, color.b, 1)
		else
			render2d.SetColor(0.6, 0.9, 1, 1)
		end

		-- Small sharp diamond at the tip
		theme.DrawDiamond(tip_x, center_y, h * 0.8)

		-- Larger faint halo diamond
		if color then
			render2d.SetColor(color.r, color.g, color.b, 0.3)
		else
			render2d.SetColor(0.6, 0.9, 1, 0.3)
		end

		theme.DrawDiamond(tip_x, center_y, h * 1.8)
		-- Vertical glow line at the very tip to mark position clearly
		render2d.SetTexture(glow_linear)
		render2d.SetColor(1, 1, 1, 1)
		render2d.PushMatrix()
		render2d.Translate(tip_x, center_y)
		render2d.Rotate(math.rad(90))
		-- Draw centered vertical line
		render2d.DrawRect(-h, -1.5, h * 2, 3)
		render2d.PopMatrix()
		render2d.PopBlendMode()
		render2d.SetTexture(nil)
	end
end

do
	local glow_color = Color.FromHex("#5ea6e9")
	local gradient = Texture.New(
		{
			width = 16,
			height = 16,
			format = "r8g8b8a8_unorm",
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	)
	local start = Color.FromHex("#004687ff")
	local stop = Color.FromHex("#04013e00")
	gradient:Shade(
		[[
			float dist = distance(uv, vec2(0.5));
				return mix(vec4(]] .. start.r .. ", " .. start.g .. ", " .. start.b .. ", " .. start.a .. [[), vec4(]] .. stop.r .. ", " .. stop.g .. ", " .. stop.b .. ", " .. stop.a .. [[), -uv.y + 1.0 + uv.x*0.3);
		]]
	)

	function theme.DrawModernFrame(x, y, w, h, intensity)
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetTexture(gradient)
		render2d.DrawRect(x, y, w, h)
	end

	function theme.DrawModernFramePost(x, y, w, h, intensity)
		render2d.SetTexture(nil)
		x = x - 1
		y = y - 1
		w = w + 2
		h = h + 2
		render2d.SetColor(glow_color.r, glow_color.g, glow_color.b, 0.75 + intensity * 0.4)
		render2d.SetBlendMode("additive")
		local glow_size = 40 * intensity
		local diamond_size = 6 + 2 * intensity
		theme.DrawDiamond2(x, y, diamond_size)
		theme.DrawGlow(x, y, glow_size)
		theme.DrawDiamond2(x + w, y, diamond_size)
		theme.DrawGlow(x + w, y, glow_size)
		theme.DrawDiamond2(x, y + h, diamond_size)
		theme.DrawGlow(x, y + h, glow_size)
		theme.DrawDiamond2(x + w, y + h, diamond_size)
		theme.DrawGlow(x + w, y + h, glow_size)
		render2d.SetTexture(glow_linear)
		local extent_h = -200 * 0.25 * intensity
		local extent_w = -200 * 0.25 * intensity
		render2d.SetBlendMode("alpha")
		theme.DrawGlowLine(x + extent_w, y, x + w - extent_w, y, 1)
		theme.DrawGlowLine(x + extent_w, y + h, x + w - extent_w, y + h, 1)
		theme.DrawGlowLine(x, y + extent_h, x, y + h - extent_h, 1)
		theme.DrawGlowLine(x + w, y + extent_h, x + w, y + h - extent_h, 1)
		render2d.SetTexture(nil)
	end
end

function theme.DrawMuseum()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(nil)
	local x, y = 500, 200 --gfx.GetMousePosition()
	local w, h = 600, 30
	theme.HeadingFont:DrawText("Custom Font Rendering", x, y - 40)
	theme.DrawClassicFrame(x, y, 60, 40)
	x = x + 80
	theme.DrawModernFrame(x, y, 100, 60, 1)
	x = x + 120
	theme.DrawModernFrame(x, y, 100, 60, 0)
	x = x + 120
	theme.DrawWhiteFrame(x, y, 60, 40)
	x = x - 120 - 80 - 120
	y = y + 80
	render2d.SetColor(0, 0, 0, 1)
	theme.DrawPill1(x, y, w, h)
	y = y + 50
	theme.DrawBadge(x, y, w, h)
	y = y + 50
	theme.DrawDiamond(x, y, 20)
	x = x + 50
	render2d.PushOutlineWidth(1)
	theme.DrawDiamond(x, y, 20)
	render2d.PopOutlineWidth()
	render2d.SetColor(1, 1, 1, 1)
	x = x + 50
	theme.DrawArrow(x, y, 40)
	x = x - 100
	y = y + 50
	render2d.SetTexture(nil)
	theme.DrawLine(x + 20, y, x + w - 40, y, 3)
	y = y + 20
	theme.DrawLine2(x + 20, y, x + w - 40, y, 3)
	y = y + 20
	theme.DrawDiamond2(x, y, 10)
	y = y + 20
	render2d.SetColor(1, 1, 1, 1)
	y = y + 20
	theme.DrawMagicCircle(x - 100, y, 30)
	y = y + 20
	theme.DrawGlowLine(x, y, x + w - 40, y, 1)
end

if HOTRELOAD then
	event.AddListener("Draw2D", "theme_museum", function()
		theme.DrawMuseum()
	end)
end

return theme
