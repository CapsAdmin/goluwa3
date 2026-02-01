local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local lsx = require("ecs.lsx_ecs")

local Frame = runfile("lua/ui/elements/frame.lua")
local MenuButton = runfile("lua/ui/elements/menu_button.lua")
local ContextMenu = runfile("lua/ui/elements/context_menu.lua")
local MenuSpacer = runfile("lua/ui/elements/menu_spacer.lua")

return function(props)
	local active_menu, set_active_menu = lsx:UseState(nil)
	local menu_pos, set_menu_pos = lsx:UseState(Vec2())

	local function ToggleMenu(name, ref)
		if active_menu == name then
			set_active_menu(nil)
		else
			set_active_menu(name)
			if ref.current then
				local x, y = ref.current.transform_2d:GetWorldRectFast()
				local size = ref.current.transform_2d.Size
				set_menu_pos(Vec2(x, y + size.y + 5))
			end
		end
	end

	local game_ref = lsx:UseRef(nil)
	local config_ref = lsx:UseRef(nil)

	return lsx:Panel(
		{
			Name = "MenuOverlay",
			Size = Vec2(render2d.GetSize()),
			Color = Color(0, 0, 0, 0.7), -- Dark-ish overlay
			Frame({
				Name = "TopBar",
				Layout = {"GmodTop"},
				Padding = Rect(5, 5, 5, 5),
				Resizable = false,
				DragEnabled = false,
				lsx:Panel({
					Layout = {"SizeToChildren", "CenterSimple"},
					Stack = true,
					StackRight = true,
					MenuButton({
						Text = "GAME",
						ref = game_ref,
						Active = active_menu == "GAME",
						OnClick = function() ToggleMenu("GAME", game_ref) end,
					}),
					MenuButton({
						Text = "CONFIG",
						ref = config_ref,
						Active = active_menu == "CONFIG",
						OnClick = function() ToggleMenu("CONFIG", config_ref) end,
					}),
					MenuButton({Text = "CHEAT"}),
					MenuButton({Text = "NETPLAY"}),
					MenuButton({Text = "MISC"}),
				})
			}),
			ContextMenu({
				Visible = active_menu == "GAME",
				Position = menu_pos,
				OnClose = function() set_active_menu(nil) end,
				MenuButton({Text = "New Game"}),
				MenuButton({Text = "Load Game"}),
				MenuSpacer({Vertical = true}),
				MenuButton({Text = "Exit"}),
			}),
			ContextMenu({
				Visible = active_menu == "CONFIG",
				Position = menu_pos,
				OnClose = function() set_active_menu(nil) end,
				MenuButton({Text = "Video"}),
				MenuButton({Text = "Audio"}),
				MenuButton({Text = "Input"}),
			}),
		}
	)
end
