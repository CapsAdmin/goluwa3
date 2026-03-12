local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local window = import("goluwa/window.lua")
local event = import("goluwa/event.lua")
local Panel = import("goluwa/ecs/panel.lua")
local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")
local theme = import("./theme.lua")
local Button = import("./elements/button.lua")
local MenuItem = import("./elements/context_menu_item.lua")
local MenuSpacer = import("./elements/menu_spacer.lua")
local ContextMenu = import("./elements/context_menu.lua")
local Frame = import("./elements/frame.lua")
local Row = import("./elements/row.lua")
local Gallery = import("./widgets/gallery.lua")
local world_panel = Panel.World
local menu = NULL
local visible = false
world_panel:RemoveChildren()

local function toggle()
	visible = not visible

	if menu:IsValid() then
		menu:Remove()

		if not visible then
			if window.current then window.current:SetMouseTrapped(true) end

			return
		end
	end

	if window.current then window.current:SetMouseTrapped(false) end

	local top_bar = Frame{
		layout = {
			GrowWidth = 1,
			FitHeight = true,
		},
		Padding = Rect() + theme.GetSize("XXS"),
	}{
		Row({}){
			Button{
				Text = "GAME",
				OnClick = function(ent)
					print("click?")
					local x, y = ent.transform:GetWorldMatrix():GetTranslation()
					y = y + ent.transform:GetHeight()
					world_panel:Ensure(
						ContextMenu{
							Key = "ActiveContextMenu",
							Position = Vec2(x, y),
							OnClose = function(ent)
								print("removing context menu")
								ent:Remove()
							end,
						}{
							MenuItem{
								Text = "LOAD",
								OnClick = function()
									world_panel:Ensure(Gallery({Key = "GalleryWindow"}))
								end,
							},
							MenuItem({Text = "RUN (ESCAPE)"}),
							MenuItem{Text = "RESET", Disabled = true},
							MenuSpacer(),
							MenuItem{Text = "SAVE STATE", Disabled = true},
							MenuItem{Text = "OPEN STATE", Disabled = true},
							MenuItem{Text = "PICK STATE", Disabled = true},
							MenuSpacer(),
							MenuItem{
								Text = "QUIT",
								OnClick = function()
									system.ShutDown()
								end,
							},
						}
					)
				end,
			},
			Button{
				Text = "CONFIG",
			},
			Button{
				Text = "CHEAT",
			},
			Button{
				Text = "NETPLAY",
			},
			Button{
				Text = "MISC",
			},
		},
	}
	menu = Panel.New{
		Name = "GameMenuPanel",
		OnSetProperty = theme.OnSetProperty,
		transform = {
			Size = world_panel.transform:GetSize(),
		},
		gui_element = {
			Color = Color(0, 0, 0, 0.5),
		},
		layout = {
			Direction = "y",
		},
		gui_element = true,
		mouse_input = true,
		clickable = true,
		animation = true,
	}{
		top_bar,
	}
	menu:AddGlobalEvent("WindowFramebufferResized")

	function menu:OnWindowFramebufferResized(window, size)
		self.transform:SetSize(size)
	end

	return false
end

if HOTRELOAD then toggle() end

event.AddListener("KeyInput", "menu_toggle", function(key, press)
	if not press then return end

	if key == "escape" then return toggle() end
end)

event.AddListener("Update", "window_title", function(dt)
	if wait(1) then
		window.current:SetTitle("FPS: " .. math.round(1 / system.GetFrameTime()))
	end
end)

event.AddListener("WindowGainedFocus", "mouse_trap", function()
	if not visible and window.current then window.current:SetMouseTrapped(true) end
end) --toggle()
