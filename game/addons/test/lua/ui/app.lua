local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local window = require("window")
local event = require("event")
local Panel = require("ecs.entities.2d.panel")
local system = require("system")
local theme = runfile("lua/ui/theme.lua")
local Text = runfile("lua/ui/elements/text.lua")
local MenuButton = runfile("lua/ui/elements/menu_button.lua")
local MenuSpacer = runfile("lua/ui/elements/menu_spacer.lua")
local ContextMenu = runfile("lua/ui/elements/context_menu.lua")
local Frame = runfile("lua/ui/elements/frame.lua")
local Slider = runfile("lua/ui/elements/slider.lua")
local world_panel = require("ecs.panel").World
local menu = NULL
local visible = false

event.AddListener("KeyInput", "menu_toggle", function(key, press)
	if not press then return end

	if key == "escape" then
		visible = not visible

		if window.current then window.current:SetMouseTrapped(not visible) end

		if menu:IsValid() then
			menu:Remove()

			if not visible then return end
		end

		local top_bar = Frame(
			{
				Layout = {"GmodTop"},
				Size = Vec2(0, 30),
				Margin = theme.Sizes.FrameMargin,
				Children = {
					MenuButton(
						{
							Text = "GAME",
							Layout = {"MoveLeft", "CenterYSimple"},
							Size = theme.Sizes.TopBarButtonSize,
							OnClick = function(ent)
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
											Children = {
												MenuButton({Text = "LOAD"}),
												MenuButton({Text = "RUN (ESCAPE)"}),
												MenuButton({Text = "RESET", Disabled = true}),
												MenuSpacer({Size = 6, Layout = {"FillX"}}),
												MenuButton({Text = "SAVE STATE", Disabled = true}),
												MenuButton({Text = "OPEN STATE", Disabled = true}),
												MenuButton({Text = "PICK STATE", Disabled = true}),
												MenuSpacer({Size = 6, Layout = {"FillX"}}),
												MenuButton(
													{
														Text = "QUIT",
														OnClick = function()
															system.ShutDown()
														end,
													}
												),
											},
										}
									)
								)
							end,
						}
					),
					MenuButton(
						{
							Text = "CONFIG",
							Layout = {"MoveLeft", "CenterYSimple"},
							Size = theme.Sizes.TopBarButtonSize,
						}
					),
					MenuButton(
						{
							Text = "CHEAT",
							Layout = {"MoveLeft", "CenterYSimple"},
							Size = theme.Sizes.TopBarButtonSize,
						}
					),
					MenuButton(
						{
							Text = "NETPLAY",
							Layout = {"MoveLeft", "CenterYSimple"},
							Size = theme.Sizes.TopBarButtonSize,
						}
					),
					MenuButton(
						{
							Text = "MISC",
							Layout = {"MoveLeft", "CenterYSimple"},
							Size = Vec2(80, 30),
						}
					),
				},
			}
		)
		top_bar:AddComponent("draggable")
		top_bar:AddComponent("resizable")
		local slider_demo = Slider(
			{
				Layout = {"Center"},
				Size = Vec2(400, 50),
				Value = 0.5,
				Min = 0,
				Max = 100,
				OnChange = function(value)
					print("Slider value:", value)
				end,
			}
		)
		menu = Panel(
			{
				Name = "GameMenuPanel",
				Color = Color(0, 0, 0, 0.5),
				Padding = Rect() + 5,
				Layout = {"Fill"},
				Children = {top_bar, slider_demo},
			}
		)
		return false
	end
end)
