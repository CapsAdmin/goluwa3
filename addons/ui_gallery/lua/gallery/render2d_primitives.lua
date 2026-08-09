local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local CANVAS = 160
local GAP = 12
local PADDING = 20
local gradient_tex = render2d.CreateGradient{
	mode = "linear",
	angle = 45,
	stops = {
		{pos = 0, color = Color(0.95, 0.42, 0.28, 1)},
		{pos = 0.5, color = Color(0.86, 0.8, 0.34, 1)},
		{pos = 1, color = Color(0.28, 0.72, 1.0, 1)},
	},
}

local function bg(self)
	local size = self.transform.Size + self.transform.DrawSizeOffset
	render2d.SetTexture()
	render2d.SetColor(0.05, 0.06, 0.08, 1)
	render2d.DrawRect(0, 0, size.x, size.y)
end

local function draw_grid(self)
	local size = self.transform.Size + self.transform.DrawSizeOffset
	render2d.SetColor(1, 1, 1, 0.03)

	for x = 0, size.x, 20 do
		render2d.DrawLine(x, 0, x, size.y, 0.5)
	end

	for y = 0, size.y, 20 do
		render2d.DrawLine(0, y, size.x, y, 0.5)
	end
end

local function build_tile(label, description, draw_fn)
	return Panel.New{
		transform = true,
		rect = true,
		layout = {
			FitWidth = true,
			FitHeight = true,
			MinSize = Vec2(188, 220),
		},
	}{
		Column{
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				ChildGap = 10,
			},
		}{
			Panel.New{
				transform = true,
				rect = true,
				OnDraw = function(self)
					local size = self.transform.Size + self.transform.DrawSizeOffset
					bg(self)
					draw_grid(self)
					render2d.SetTexture()
					render2d.PushMatrix()
					render2d.Translatef(size.x * 0.5, size.y * 0.5)
					render2d.PushBorderRadius(0)
					render2d.PushOutlineWidth(0)
					render2d.PushBlur(0)
					render2d.SetBlendPreset("alpha")
					draw_fn(size)
					render2d.PopBlur()
					render2d.PopOutlineWidth()
					render2d.PopBorderRadius()
					render2d.PopMatrix()
				end,
				layout = {
					Size = Vec2(CANVAS, CANVAS),
					MinSize = Vec2(CANVAS, CANVAS),
					MaxSize = Vec2(CANVAS, CANVAS),
				},
			},
			Text{
				Text = label,
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = description,
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
					MaxSize = Vec2(220, 220),
				},
			},
		},
	}
end

local function definitions()
	return {
		{
			label = "Filled Rect",
			description = "Solid rectangle with the default alpha blend mode.",
			draw = function(size)
				render2d.SetColor(0.95, 0.42, 0.28, 1)
				render2d.DrawRect(-48, -36, 96, 72)
			end,
		},
		{
			label = "Rounded Rect",
			description = "Same rect with uniform border radius for soft corners.",
			draw = function(size)
				render2d.SetColor(0.28, 0.72, 1.0, 1)
				render2d.PushBorderRadius(18)
				render2d.DrawRect(-48, -36, 96, 72)
				render2d.PopBorderRadius()
			end,
		},
		{
			label = "Asymmetric Radius",
			description = "Each corner gets its own radius value.",
			draw = function(size)
				render2d.SetColor(0.86, 0.8, 0.34, 1)
				render2d.PushBorderRadius(4, 24, 12, 32)
				render2d.DrawRect(-48, -36, 96, 72)
				render2d.PopBorderRadius()
			end,
		},
		{
			label = "Outlined Rect",
			description = "Stroke-only rectangle using SetOutlineWidth.",
			draw = function(size)
				render2d.SetColor(0.64, 0.36, 0.96, 1)
				render2d.PushOutlineWidth(-3)
				render2d.DrawRect(-48, -36, 96, 72)
				render2d.PopOutlineWidth()
			end,
		},
		{
			label = "Filled Circle",
			description = "Drawn as a rect with equal border radius on all corners.",
			draw = function(size)
				render2d.SetColor(0.4, 0.9, 0.78, 1)
				render2d.PushBorderRadius(36)
				render2d.DrawRect(-36, -36, 72, 72)
				render2d.PopBorderRadius()
			end,
		},
		{
			label = "Circle Outline",
			description = "Multiple circles with increasing stroke widths.",
			draw = function(size)
				for i = 3, 1, -1 do
					render2d.SetColor(0.95, 0.62, 0.18, 0.3 + i * 0.2)
					render2d.PushOutlineWidth(i * -2.5)
					render2d.PushBorderRadius(28)
					render2d.DrawRect(-28, -28, 56, 56)
					render2d.PopBorderRadius()
					render2d.PopOutlineWidth()
				end
			end,
		},
		{
			label = "Line",
			description = "Diagonal line drawn via DrawLine with custom width.",
			draw = function(size)
				render2d.SetColor(1, 1, 1, 0.9)
				render2d.SetTexture()
				render2d.DrawLine(-60, -50, 60, 50, 3)
			end,
		},
		{
			label = "Rotated Rect",
			description = "Rect with rotation via the a parameter of DrawRect.",
			draw = function(size)
				local t = system.GetElapsedTime()
				render2d.SetColor(0.28, 0.72, 1.0, 1)
				render2d.PushBorderRadius(6)
				render2d.DrawRect(-36, -24, 72, 48, t * 0.6)
				render2d.PopBorderRadius()
			end,
		},
		{
			label = "Additive Blend",
			description = "Overlapping circles with additive blending for glow.",
			draw = function(size)
				local t = system.GetElapsedTime()
				render2d.SetBlendPreset("additive")

				for i = 1, 5 do
					local a = t * 1.2 + i * 1.1
					local cx = math.sin(a) * 28
					local cy = math.cos(a * 0.7) * 22
					render2d.SetColor(0.2, 0.6, 1.0, 0.35)
					render2d.PushBorderRadius(18)
					render2d.DrawRect(cx - 18, cy - 18, 36, 36)
					render2d.PopBorderRadius()
				end

				render2d.SetBlendPreset("alpha")
			end,
		},
		{
			label = "Multiply Blend",
			description = "Overlapping shapes with multiply blend for darkening.",
			draw = function(size)
				render2d.SetBlendPreset("multiply")
				render2d.SetColor(1, 0.3, 0.3, 0.7)
				render2d.PushBorderRadius(20)
				render2d.DrawRect(-36, -28, 72, 56)
				render2d.PopBorderRadius()
				render2d.SetColor(0.3, 0.3, 1, 0.7)
				render2d.PushBorderRadius(20)
				render2d.DrawRect(-28, -32, 56, 64)
				render2d.PopBorderRadius()
				render2d.SetBlendPreset("alpha")
			end,
		},
		{
			label = "Blur",
			description = "Rect with blur applied via SetBlur for a soft glow effect.",
			draw = function(size)
				render2d.SetColor(0.95, 0.42, 0.28, 0.8)
				render2d.PushBlur(12, 12)
				render2d.PushBorderRadius(20)
				render2d.DrawRect(-40, -30, 80, 60)
				render2d.PopBorderRadius()
				render2d.PopBlur()
				render2d.SetColor(1, 1, 1, 0.9)
				render2d.PushOutlineWidth(-2)
				render2d.PushBorderRadius(20)
				render2d.DrawRect(-40, -30, 80, 60)
				render2d.PopBorderRadius()
				render2d.PopOutlineWidth()
			end,
		},
		{
			label = "Clipping",
			description = "PushClipRect / PopClip to mask a rotated shape.",
			draw = function(size)
				local t = system.GetElapsedTime()
				render2d.PushClipRect(-30, -50, 60, 100)
				render2d.SetColor(0.86, 0.8, 0.34, 1)
				render2d.DrawRect(-50, -50, 100, 100, t * 0.5)
				render2d.PopClip()
			end,
		},
		{
			label = "Scissor",
			description = "SetScissor restricts drawing to a rectangular region.",
			draw = function(size)
				local t = system.GetElapsedTime()
				render2d.PushScissor(-40, -20, 80, 40)
				render2d.SetColor(0.4, 0.9, 0.78, 1)
				render2d.DrawRect(-60, -60, 120, 120, t * 0.3)
				render2d.PopScissor()
			end,
		},
		{
			label = "Stacked Transforms",
			description = "PushMatrix / PopMatrix to compose nested translations.",
			draw = function(size)
				local t = system.GetElapsedTime()
				render2d.SetColor(0.64, 0.36, 0.96, 1)
				render2d.PushMatrix()
				render2d.Translatef(math.sin(t) * 20, 0)
				render2d.PushBorderRadius(8)
				render2d.DrawRect(-24, -24, 48, 48)
				render2d.PopBorderRadius()
				render2d.PopMatrix()
				render2d.SetColor(0.28, 0.72, 1.0, 1)
				render2d.PushMatrix()
				render2d.Translatef(math.cos(t) * 20, 0)
				render2d.PushBorderRadius(8)
				render2d.DrawRect(-24, -24, 48, 48)
				render2d.PopBorderRadius()
				render2d.PopMatrix()
			end,
		},
		{
			label = "Gradient Fill",
			description = "DrawRect with a gradient texture bound via SetSDFGradientTexture.",
			draw = function(size)
				render2d.PushSDFGradientTexture(gradient_tex)
				render2d.SetColor(1, 1, 1, 1)
				render2d.PushBorderRadius(16)
				render2d.DrawRect(-50, -36, 100, 72)
				render2d.PopBorderRadius()
				render2d.PopSDFGradientTexture()
			end,
		},
		{
			label = "Nine-Patch",
			description = "SetNinePatch stretches only the center, keeping corners fixed.",
			draw = function(size)
				local t = system.GetElapsedTime()
				render2d.SetNinePatch{
					x_stretch = {{10, 10}, {40, 60}},
					y_stretch = {{10, 10}, {30, 50}},
				}
				render2d.SetColor(0.4, 0.9, 0.78, 1)
				render2d.DrawRect(-50, -36, 100, 72)
				render2d.ClearNinePatch()
			end,
		},
		{
			label = "Depth Test",
			description = "Two overlapping rects with depth write to show z-ordering.",
			draw = function(size)
				local t = system.GetElapsedTime()
				render2d.SetDepthMode("less", true)
				render2d.SetColor(0.95, 0.42, 0.28, 0.7)
				render2d.PushBorderRadius(12)
				render2d.DrawRect(-40, -30, 80, 60, t * 0.4)
				render2d.PopBorderRadius()
				render2d.SetColor(0.28, 0.72, 1.0, 0.7)
				render2d.PushBorderRadius(12)
				render2d.DrawRect(-20, -20, 80, 60, -t * 0.3)
				render2d.PopBorderRadius()
				render2d.SetDepthMode("none", false)
			end,
		},
		{
			label = "Stencil Mask",
			description = "PushStencilMask / PopStencilMask to write and test stencil levels.",
			draw = function(size)
				local t = system.GetElapsedTime()
				render2d.SetColor(0.86, 0.8, 0.34, 1)
				render2d.PushStencilMask()
				render2d.PushBorderRadius(30)
				render2d.DrawRect(-30, -30, 60, 60)
				render2d.PopBorderRadius()
				render2d.BeginStencilTest()
				render2d.SetColor(0.4, 0.9, 0.78, 1)
				render2d.DrawRect(-50, -10, 100, 20)
				render2d.PopStencilMask()
				render2d.SetColor(0.64, 0.36, 0.96, 1)
				render2d.PushBorderRadius(8)
				render2d.DrawRect(-40, -36, 80, 72)
				render2d.PopBorderRadius()
			end,
		},
	}
end

return {
	Name = "render2d primitives",
	Create = function()
		local defs = definitions()
		local rows = {}

		for i = 1, #defs, 3 do
			local children = {}

			for j = i, math.min(i + 2, #defs) do
				children[#children + 1] = build_tile(defs[j].label, defs[j].description, defs[j].draw)
			end

			rows[#rows + 1] = Row{
				layout = {
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
					AlignmentY = "start",
					ChildGap = GAP,
				},
			}(children)
		end

		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 14,
				Padding = Rect(PADDING, PADDING, PADDING, PADDING),
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Grid of render2d primitives. Each cell demonstrates one function or effect — rects, circles, lines, blend modes, clipping, stencil, depth, gradients, and nine-patch stretching.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Column{
				layout = {
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
					ChildGap = GAP,
				},
			}(rows),
		}
	end,
}
