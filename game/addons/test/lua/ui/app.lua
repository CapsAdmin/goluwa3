local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local window = require("window")
local event = require("event")
local Panel = require("ecs.panel")
local system = require("system")
local vfs = require("vfs")
local theme = require("ui.theme")
local Button = require("ui.elements.button")
local MenuItem = require("ui.elements.context_menu_item")
local MenuSpacer = require("ui.elements.menu_spacer")
local ContextMenu = require("ui.elements.context_menu")
local Frame = require("ui.elements.frame")
local Row = require("ui.elements.row")
local Gallery = require("ui.widgets.gallery")
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

	local top_bar = Frame(
		{
			layout = {
				GrowWidth = 1,
				FitHeight = true,
			},
			Padding = Rect() + theme.GetSize("XXS"),
		}
	)(
		{
			Row({})(
				{
					Button(
						{
							Text = "GAME",
							OnClick = function(ent)
								print("click?")
								local x, y = ent.transform:GetWorldMatrix():GetTranslation()
								y = y + ent.transform:GetHeight()
								world_panel:Ensure(
									ContextMenu(
										{
											Key = "ActiveContextMenu",
											Position = Vec2(x, y),
											OnClose = function(ent)
												print("removing context menu")
												ent:Remove()
											end,
										}
									)(
										{
											MenuItem(
												{
													Text = "LOAD",
													OnClick = function()
														world_panel:Ensure(Gallery({Key = "GalleryWindow"}))
													end,
												}
											),
											MenuItem({Text = "RUN (ESCAPE)"}),
											MenuItem({Text = "RESET", Disabled = true}),
											MenuSpacer(),
											MenuItem({Text = "SAVE STATE", Disabled = true}),
											MenuItem({Text = "OPEN STATE", Disabled = true}),
											MenuItem({Text = "PICK STATE", Disabled = true}),
											MenuSpacer(),
											MenuItem(
												{
													Text = "QUIT",
													OnClick = function()
														system.ShutDown()
													end,
												}
											),
										}
									)
								)
							end,
						}
					),
					Button({
						Text = "CONFIG",
					}),
					Button({
						Text = "CHEAT",
					}),
					Button({
						Text = "NETPLAY",
					}),
					Button({
						Text = "MISC",
					}),
				}
			),
		}
	)

	menu = Panel.New(
		{
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
		}
	)({
		top_bar,
	})
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
end)--toggle()
