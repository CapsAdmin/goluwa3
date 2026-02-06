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
local Dropdown = runfile("lua/ui/elements/dropdown.lua")
local Row = runfile("lua/ui/elements/row.lua")
local Column = runfile("lua/ui/elements/column.lua")
local Window = runfile("lua/ui/elements/window.lua")
local world_panel = Panel.World
local menu = NULL
local visible = false
world_panel:RemoveChildren()

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
				layout = {
					GrowWidth = 1,
					FitHeight = true,
				},
				Padding = "XXS",
				Children = {
					Row({})(
						{
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
						}
					),
				},
			}
		)
		local slider_demo = Slider(
			{
				Size = Vec2(400, 50),
				Value = 0.5,
				Min = 0,
				Max = 100,
				OnChange = function(value)
					print("Slider value:", value)
				end,
				layout = {GrowWidth = 1},
			}
		)
		local checkbox_demo = Row(
			{
				layout = {Direction = "x", ChildGap = 10, AlignmentY = "center"},
				Children = {
					Checkbox(
						{
							Value = true,
							OnChange = function(val)
								print("Checkbox value:", val)
							end,
						}
					),
					Text({Text = "toggle"}),
				},
			}
		)
		local selected_radio = 1
		local radio_group = Column(
			{
				layout = {Direction = "y", ChildGap = 5, AlignmentX = "start"},
				Children = {
					Row(
						{
							layout = {Direction = "x", ChildGap = 10, AlignmentY = "center"},
							Children = {
								RadioButton(
									{
										IsSelected = function()
											return selected_radio == 1
										end,
										OnSelect = function()
											print("p1")
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
							layout = {Direction = "x", ChildGap = 10, AlignmentY = "center"},
							Children = {
								RadioButton(
									{
										IsSelected = function()
											return selected_radio == 2
										end,
										OnSelect = function()
											print("p2")
											selected_radio = 2
										end,
									}
								),
								Text({Text = "p3"}),
							},
						}
					),
					Row(
						{
							layout = {Direction = "x", ChildGap = 10, AlignmentY = "center"},
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
		local selected_dropdown_val = "Option 1"
		local dropdown_demo = Dropdown(
			{
				Text = "Select Option",
				Size = Vec2(10, 10),
				Options = {"Option 1", "Option 2", "Option 3", "Option 4"},
				OnSelect = function(val)
					print("Dropdown selected:", val)
					selected_dropdown_val = val
				end,
				GetText = function()
					return "Selected: " .. selected_dropdown_val
				end,
				layout = {GrowWidth = 1},
			}
		)
		local demo_window = Window(
			{
				Title = "UI ELEMENTS DEMO",
				Size = Vec2(450, 500),
				Position = (world_panel.transform:GetSize() - Vec2(450, 500)) / 2,
				Children = {
					dropdown_demo,
					slider_demo,
					checkbox_demo,
					radio_group,
					MenuButton({Text = "CONFIG", Padding = "XS"}),
				},
			}
		)
		menu = Panel.NewPanel(
			{
				Name = "GameMenuPanel",
				Color = Color(0, 0, 0, 0.5),
				Size = world_panel.transform:GetSize(),
				layout = {
					Direction = "y",
				},
				Children = {
					top_bar,
					demo_window,
				},
			}
		)
		menu:AddEvent("WindowFramebufferResized")

		function menu:OnWindowFramebufferResized(window, size)
			self.transform:SetSize(size)
		end

		return false
	end
end)
