local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local window = require("window")
local event = require("event")
local Panel = require("ecs.entities.2d.panel")
local Text = runfile("lua/ui/elements/text.lua")
local MenuButton = runfile("lua/ui/elements/menu_button.lua")
local MenuSpacer = runfile("lua/ui/elements/menu_spacer.lua")
local ContextMenu = runfile("lua/ui/elements/context_menu.lua")
local Frame = runfile("lua/ui/elements/frame.lua")
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

		menu = Panel(
			{
				Name = "GameMenuPanel",
				Color = Color(0, 0, 0, 0.5),
				Padding = Rect() + 5,
				Layout = {"Fill"},
				Children = {
					Frame(
						{
							Layout = {"GmodTop"},
							Size = Vec2(0, 30),
							Margin = Rect() + 5,
							Children = {
								MenuButton(
									{
										Text = "GAME",
										Layout = {"MoveLeft", "CenterYSimple"},
										Size = Vec2(80, 30),
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
										Size = Vec2(80, 30),
									}
								),
								MenuButton(
									{
										Text = "CHEAT",
										Layout = {"MoveLeft", "CenterYSimple"},
										Size = Vec2(80, 30),
									}
								),
								MenuButton(
									{
										Text = "NETPLAY",
										Layout = {"MoveLeft", "CenterYSimple"},
										Size = Vec2(80, 30),
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
					),
				},
			}
		)
		return false
	end
end)
