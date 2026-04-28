local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local Column = import("../elements/column.lua")
local Text = import("../elements/text.lua")
local Panel = import("goluwa/ecs/panel.lua")

local function draw_background(self)
	local transform = self.transform
	local size = transform.Size + transform.DrawSizeOffset
	local radius = self.gui_element:GetBorderRadius()
	render2d.SetTexture()
	render2d.SetColor(self.surface_color:Unpack())

	if radius > 0 then
		gfx.DrawRoundedRect(0, 0, size.x, size.y, radius)
	else
		render2d.DrawRect(0, 0, size.x, size.y)
	end
end

local function dock_label(text, color)
	return Text{
		Text = text,
		Color = color or Color(1, 1, 1, 1),
		IgnoreMouseInput = true,
		layout = {
			GrowWidth = 1,
		},
	}
end

local function dock_piece(label, dock, size, color, children)
	return Panel.New{
		transform = {
			Size = size,
		},
		layout = {
			Dock = dock,
			Direction = "y",
			Padding = Rect(10, 8, 10, 8),
			AlignmentX = "center",
			AlignmentY = "center",
		},
		gui_element = {
			BorderRadius = 6,
		},
		surface_color = color,
		OnDraw = draw_background,
	}(children or {
		dock_label(label),
	})
end

local function dock_surface(size, children)
	return Panel.New{
		transform = {
			Size = size,
		},
		layout = {
			Direction = "y",
			Padding = Rect(12, 12, 12, 12),
			MinSize = size,
			MaxSize = size,
		},
		gui_element = {
			BorderRadius = 8,
		},
		surface_color = Color(0.08, 0.09, 0.12, 1),
		OnDraw = draw_background,
	}(children)
end

local function basic_dock_demo()
	return dock_surface(
		Vec2(520, 280),
		{
			dock_piece("top", "top", Vec2(120, 40), Color(0.82, 0.33, 0.29, 1)),
			dock_piece("bottom", "bottom", Vec2(120, 34), Color(0.72, 0.29, 0.26, 1)),
			dock_piece("left", "left", Vec2(90, 60), Color(0.19, 0.55, 0.84, 1)),
			dock_piece("right", "right", Vec2(84, 60), Color(0.27, 0.47, 0.82, 1)),
			dock_piece(
				"fill",
				"fill",
				Vec2(180, 120),
				Color(0.15, 0.65, 0.48, 1),
				{
					dock_label("fill"),
					dock_label("remaining rect", Color(0.85, 0.95, 0.9, 1)),
				}
			),
		}
	)
end

local function nested_dock_demo()
	return dock_surface(
		Vec2(520, 300),
		{
			dock_piece("top", "top", Vec2(120, 36), Color(0.71, 0.33, 0.27, 1)),
			dock_piece(
				"workspace",
				"fill",
				Vec2(220, 150),
				Color(0.14, 0.16, 0.2, 1),
				{
					dock_piece("inspector", "right", Vec2(100, 60), Color(0.47, 0.36, 0.79, 1)),
					dock_piece("toolbar", "top", Vec2(120, 34), Color(0.8, 0.57, 0.18, 1)),
					dock_piece(
						"canvas",
						"fill",
						Vec2(120, 80),
						Color(0.16, 0.64, 0.58, 1),
						{
							dock_label("nested fill"),
							dock_label("top + right consumed first", Color(0.86, 0.95, 0.92, 1)),
						}
					),
				}
			),
		}
	)
end

return {
	Name = "dock",
	Create = function()
		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 14,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "String dock enums now live on child layouts: top, bottom, left, right, fill. The parent layout switches to remaining-rect docking automatically when any child opts in.",
				Wrap = true,
				WrapToParent = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Text{
				Text = "Basic dock",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			basic_dock_demo(),
			Text{
				Text = "Nested dock inside fill",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			nested_dock_demo(),
		}
	end,
}
