local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local DEMO_SIZE = Vec2(320, 200)
local CONFIRM_SIZE = Vec2(320, 160)
return {
	Name = "windows",
	Section = "Overlays",
	Order = 2,
	View = react.Component(
		||-> do
			local windows, set_windows = react.UseState({})
			local confirm, set_confirm = react.UseState(nil)
			local counter = react.UseRef(0)

			local function open_window()
				counter.current = counter.current + 1
				local id = counter.current
				local position = (Panel.World.transform:GetSize() - DEMO_SIZE) / 2 + Vec2(24, 24) * (id % 6)
				set_windows(
					|current|-> do
						local next_windows = list.copy(current)
						next_windows[#next_windows + 1] = {id = id, position = position}
						return next_windows
					end
				)
			end

			return kit.Page{
				Title = "Windows",
				Description = "Floating, draggable and resizable windows. Children added to a window land in its padded content area.",
			}{
				kit.Section{
					Title = "Open windows",
					Description = "The windows are rendered through a Portal into the world panel, closing one removes it from the state.",
				}{
					kit.Group{
						ui.Button{Text = "Open a window", OnClick = open_window},
						ui.Button{
							Text = "Open with custom OnClose",
							Mode = "outline",
							OnClick = ||->set_confirm((Panel.World.transform:GetSize() - CONFIRM_SIZE) / 2),
						},
					},
				},
				react.Portal{Target = Panel.World}{
					list.map(
						windows,
						|window|->ui.Window{
							Key = window.id,
							Title = "WINDOW " .. window.id,
							Size = DEMO_SIZE,
							Position = window.position,
							MinSize = Vec2(200, 120),
							OnClose = ||->set_windows(|current|->list.filter(current, |other|->other.id ~= window.id)),
						}{
							ui.Text{
								Text = "Drag the title bar to move this window and drag its edges to resize it. Clicking a window brings it to the front.",
								Wrap = true,
								IgnoreMouseInput = true,
								layout = {GrowWidth = 1},
							},
						}
					),
					confirm and
					ui.Window{
						Key = "confirm",
						Title = "CONFIRM",
						Size = CONFIRM_SIZE,
						Position = confirm,
						OnClose = ||->set_confirm(nil),
					}{
						ui.Text{
							Text = "OnClose receives the window. Remove it, hide it or ask for confirmation.",
							Wrap = true,
							IgnoreMouseInput = true,
							layout = {GrowWidth = 1},
						},
					},
				},
			}
		end
	),
}
