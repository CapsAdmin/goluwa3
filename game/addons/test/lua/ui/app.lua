local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local window = require("window")
local event = require("event")
local Panel = require("ecs.panel")
local system = require("system")
local theme = runfile("lua/ui/theme.lua")
local Text = runfile("lua/ui/elements/text.lua")
local MenuButton = runfile("lua/ui/elements/menu_button.lua")
local MenuItem = runfile("lua/ui/elements/context_menu_item.lua")
local MenuSpacer = runfile("lua/ui/elements/menu_spacer.lua")
local ContextMenu = runfile("lua/ui/elements/context_menu.lua")
local Frame = runfile("lua/ui/elements/frame.lua")
local Slider = runfile("lua/ui/elements/slider.lua")
local Checkbox = runfile("lua/ui/elements/checkbox.lua")
local RadioButton = runfile("lua/ui/elements/radio_button.lua")
local Row = runfile("lua/ui/elements/row.lua")
local Column = runfile("lua/ui/elements/column.lua")
local world_panel = Panel.World
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
				Layout = {"MoveTop", "FillX", "SizeToChildrenHeight"},
				Flex = true,
				FlexGap = theme.Sizes2.M,
				FlexAlignItems = "center",
				Children = {
					MenuButton(
						{
							Text = "GAME",
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
												MenuItem({Text = "LOAD"}),
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
											},
										}
									)
								)
							end,
						}
					),
					MenuButton({
						Text = "CONFIG",
					}),
					MenuButton({
						Text = "CHEAT",
					}),
					MenuButton({
						Text = "NETPLAY",
					}),
					MenuButton({
						Text = "MISC",
					}),
				},
			}
		)
		top_bar:AddComponent("draggable")
		top_bar:AddComponent("resizable")
		local slider_demo = Slider(
			{
				Size = Vec2(400, 50),
				Value = 0.5,
				Min = 0,
				Max = 100,
				OnChange = function(value)
					print("Slider value:", value)
				end,
			}
		)
		local checkbox_demo = Row(
			{
				Children = {
					Checkbox(
						{
							Value = true,
							OnChange = function(val)
								print("Checkbox value:", val)
							end,
						}
					),
					Text({Text = "Enable Awesome Mode"}),
				},
			}
		)
		local selected_radio = 1
		local radio_group = Column(
			{
				Children = {
					Row(
						{
							Children = {
								RadioButton(
									{
										IsSelected = function()
											return selected_radio == 1
										end,
										OnSelect = function()
											print("Radio 1 selected")
											selected_radio = 1
										end,
									}
								),
								Text({Text = "Option 1"}),
							},
						}
					),
					Row(
						{
							Children = {
								RadioButton(
									{
										IsSelected = function()
											return selected_radio == 2
										end,
										OnSelect = function()
											print("Radio 2 selected")
											selected_radio = 2
										end,
									}
								),
								Text({Text = "Option 2"}),
							},
						}
					),
					Row(
						{
							Children = {
								RadioButton(
									{
										IsSelected = function()
											return selected_radio == 3
										end,
										OnSelect = function()
											print("Radio 3 selected")
											selected_radio = 3
										end,
									}
								),
								Text({Text = "Option 3"}),
							},
						}
					),
				},
			}
		)
		local demo_container = Frame(
			{
				Layout = {"Center"},
				Size = Vec2(450, 300),
				Flex = true,
				FlexDirection = "column",
				FlexGap = 10,
				Padding = Rect() + 20,
				Children = {
					Text({Text = "UI ELEMENTS DEMO", Size = "L"}),
					slider_demo,
					checkbox_demo,
					radio_group,
				},
			}
		)
		menu = Panel.NewPanel(
			{
				Name = "GameMenuPanel",
				Color = Color(0, 0, 0, 0.5),
				Padding = Rect() + 5,
				Layout = {"Fill"},
				Children = {top_bar, demo_container},
			}
		)
		return false
	end
end)
