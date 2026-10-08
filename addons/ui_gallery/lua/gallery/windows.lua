local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local count = 0

local function open_window(button)
	count = count + 1
	local size = Vec2(320, 200)
	local offset = Vec2(24, 24) * (count % 6)
	Panel.World:Ensure(
		Window{
			Key = "GalleryDemoWindow" .. count,
			Title = "WINDOW " .. count,
			Size = size,
			Position = (Panel.World.transform:GetSize() - size) / 2 + offset,
			MinSize = Vec2(200, 120),
		}{
			Text{
				Text = "Drag the title bar to move this window and drag its edges to resize it. Clicking a window brings it to the front.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1},
			},
		}
	)
end

local function open_custom_close(button)
	local size = Vec2(320, 160)
	Panel.World:Ensure(
		Window{
			Key = "GalleryConfirmWindow",
			Title = "CONFIRM",
			Size = size,
			Position = (Panel.World.transform:GetSize() - size) / 2,
			OnClose = function(window)
				window:Remove()
			end,
		}{
			Text{
				Text = "OnClose receives the window. Remove it, hide it or ask for confirmation.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1},
			},
		}
	)
end

return {
	Name = "windows",
	Section = "Overlays",
	Order = 2,
	Create = function()
		return kit.Page{
			Title = "Windows",
			Description = "Floating, draggable and resizable windows. Children added to a window land in its padded content area.",
		}{
			kit.Section{
				Title = "Open windows",
				Description = "Key makes a window unique: Panel.World:Ensure(window) reuses an existing one.",
			}{
				kit.Group{
					Button{Text = "Open a window", OnClick = open_window},
					Button{
						Text = "Open with custom OnClose",
						Mode = "outline",
						OnClick = open_custom_close,
					},
				},
			},
		}
	end,
}
