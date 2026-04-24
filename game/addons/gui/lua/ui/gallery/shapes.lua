local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Column = import("../elements/column.lua")
local Frame = import("../elements/frame.lua")
local Row = import("../elements/row.lua")
local Text = import("../elements/text.lua")
local Panel = import("goluwa/ecs/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local system = import("goluwa/system.lua")

local function draw_demo_surface(size)
	render2d.SetTexture(nil)
	render2d.SetColor(0.06, 0.07, 0.09, 1)
	render2d.DrawRect(0, 0, size.x, size.y)
	render2d.SetColor(1, 1, 1, 0.04)
	render2d.DrawRect(12, math.floor(size.y * 0.5), size.x - 24, 1)
	render2d.DrawRect(math.floor(size.x * 0.5), 12, 1, size.y - 24)
	render2d.SetColor(1, 1, 1, 0.03)
	gfx.DrawOutlinedRect(12, 12, size.x - 24, size.y - 24, 1, 12)
end

local function build_shape_tile(label, draw_shape)
	return Frame{
		Padding = Rect() + 12,
		layout = {
			FitWidth = true,
			FitHeight = true,
			MinSize = Vec2(176, 184),
		},
	}{
		Column{
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "center",
				ChildGap = 10,
			},
		}{
			Panel.New{
				transform = true,
				rect = true,
				layout = {
					Size = Vec2(140, 120),
					MinSize = Vec2(140, 120),
					MaxSize = Vec2(140, 120),
				},
				OnDraw = function(self)
					local size = self.transform.Size + self.transform.DrawSizeOffset
					draw_demo_surface(size)
					draw_shape(size)
				end,
			},
			Text{
				Text = label,
				AlignX = "center",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
		},
	}
end

local function build_tiles()
	local function filled_circle(size)
		local radius = math.min(size.x, size.y) * 0.24
		render2d.SetColor(0.96, 0.53, 0.22, 1)
		gfx.DrawFilledCircle(size.x * 0.5, size.y * 0.5, radius)
		render2d.SetColor(1, 1, 1, 0.18)
		gfx.DrawCircle(size.x * 0.5, size.y * 0.5, radius + 5, 2, 48)
	end

	local function ring(size)
		local pulse = (math.sin(system.GetElapsedTime() * 2.2) + 1) * 0.5
		local radius = 20 + pulse * 16
		render2d.SetColor(0.28, 0.74, 1, 1)
		gfx.DrawCircle(size.x * 0.5, size.y * 0.5, radius, 6, 56)
		render2d.SetColor(0.28, 0.74, 1, 0.18)
		gfx.DrawFilledCircle(size.x * 0.5, size.y * 0.5, radius - 8)
	end

	local function rounded_rect(size)
		render2d.SetColor(0.22, 0.82, 0.56, 1)
		gfx.DrawRoundedRect(26, 22, size.x - 52, size.y - 44, 20)
		render2d.SetColor(1, 1, 1, 0.12)
		render2d.DrawRect(38, 34, size.x - 76, 16)
	end

	local function diamond(size)
		local edge = 54
		render2d.SetTexture(nil)
		render2d.SetColor(0.98, 0.3, 0.53, 1)
		render2d.DrawRect(size.x * 0.5, size.y * 0.5, edge, edge, math.rad(45), edge * 0.5, edge * 0.5)
		render2d.SetColor(1, 1, 1, 0.18)
		render2d.DrawRect(
			size.x * 0.5,
			size.y * 0.5,
			edge - 18,
			edge - 18,
			math.rad(45),
			(edge - 18) * 0.5,
			(edge - 18) * 0.5
		)
	end

	local function triangle(size)
		local cx = size.x * 0.5
		local cy = size.y * 0.54
		local half = 36
		render2d.SetColor(1, 0.84, 0.36, 1)
		gfx.DrawLine(cx, cy - 34, cx - half, cy + 28, 4)
		gfx.DrawLine(cx - half, cy + 28, cx + half, cy + 28, 4)
		gfx.DrawLine(cx + half, cy + 28, cx, cy - 34, 4)
	end

	local function line_fan(size)
		local t = system.GetElapsedTime()
		local cx = size.x * 0.5
		local cy = size.y * 0.5
		local radius = 34

		for i = 0, 5 do
			local angle = t * 0.7 + i * (math.pi / 3)
			local x = cx + math.cos(angle) * radius
			local y = cy + math.sin(angle) * radius
			local hue = i / 6
			render2d.SetColor(0.45 + hue * 0.5, 0.85 - hue * 0.35, 1 - hue * 0.45, 1)
			gfx.DrawLine(cx, cy, x, y, 3)
		end

		render2d.SetColor(1, 1, 1, 1)
		gfx.DrawFilledCircle(cx, cy, 6)
	end

	return {
		build_shape_tile("Filled Circle", filled_circle),
		build_shape_tile("Ring", ring),
		build_shape_tile("Rounded Rectangle", rounded_rect),
		build_shape_tile("Diamond", diamond),
		build_shape_tile("Triangle Outline", triangle),
		build_shape_tile("Line Fan", line_fan),
	}
end

return {
	Name = "shapes",
	Create = function()
		local tiles = build_tiles()
		local rows = {}

		for i = 1, #tiles, 3 do
			local children = {}

			for j = i, math.min(i + 2, #tiles) do
				children[#children + 1] = tiles[j]
			end

			rows[#rows + 1] = Row{
				layout = {
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
					AlignmentY = "start",
					ChildGap = 12,
				},
			}(children)
		end

		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 14,
				Padding = Rect(20, 20, 20, 20),
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Basic shape drawing with the UI runtime helpers. Each tile is a simple panel using render2d and gfx primitives.",
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
					ChildGap = 12,
				},
			}(rows),
		}
	end,
}
