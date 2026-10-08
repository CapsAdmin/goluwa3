local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function draw_dock_piece(piece)
	theme.active:DrawBox(piece.transform:GetSize(), {fill = piece.Token, radius = theme.active:GetRadius("S")})
end

local function dock_piece(label, dock, size, token, children)
	return Panel.New{
		Token = token,
		transform = {Size = size},
		layout = {
			Dock = dock,
			Direction = "y",
			Padding = "S",
			AlignmentX = "center",
			AlignmentY = "center",
		},
		visual = true,
		OnDraw = draw_dock_piece,
	}(
		children or
			{
				Text{Text = label, Color = "text_on_accent", IgnoreMouseInput = true},
			}
	)
end

local function dock_surface(size, children)
	return Panel.New{
		Token = "surface_alt",
		transform = {Size = size},
		layout = {
			Direction = "y",
			Padding = "S",
			MinSize = size,
			MaxSize = size,
		},
		visual = true,
		OnDraw = draw_dock_piece,
	}(children)
end

return {
	Name = "dock",
	Section = "Layout",
	Order = 2,
	Create = function()
		return kit.Page{
			Title = "Dock",
			Description = "Children opt in with layout.Dock = top | bottom | left | right | fill. Each one consumes an edge of the remaining rectangle, in child order.",
		}{
			kit.Section{
				Title = "Basic dock",
				Description = "Top and bottom are placed first, then left and right, and fill takes what is left.",
			}{
				kit.Group{
					dock_surface(
						Vec2(520, 260),
						{
							dock_piece("top", "top", Vec2(120, 40), "primary"),
							dock_piece("bottom", "bottom", Vec2(120, 36), "negative"),
							dock_piece("left", "left", Vec2(90, 60), "positive"),
							dock_piece("right", "right", Vec2(84, 60), "neutral"),
							dock_piece("fill", "fill", Vec2(180, 120), "border_strong"),
						}
					),
				},
			},
			kit.Section{Title = "Nested", Description = "A docked child can dock its own children."}{
				kit.Group{
					dock_surface(
						Vec2(520, 280),
						{
							dock_piece("top", "top", Vec2(120, 36), "primary"),
							dock_piece(
								"workspace",
								"fill",
								Vec2(220, 150),
								"surface",
								{
									dock_piece("inspector", "right", Vec2(100, 60), "neutral"),
									dock_piece("toolbar", "top", Vec2(120, 34), "positive"),
									dock_piece("canvas", "fill", Vec2(120, 80), "border_strong"),
								}
							),
						}
					),
				},
			},
		}
	end,
}
