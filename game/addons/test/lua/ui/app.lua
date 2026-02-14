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
local Text = require("ui.elements.text")
local Button = require("ui.elements.button")
local MenuItem = require("ui.elements.context_menu_item")
local MenuSpacer = require("ui.elements.menu_spacer")
local ContextMenu = require("ui.elements.context_menu")
local Frame = require("ui.elements.frame")
local Slider = require("ui.elements.slider")
local Checkbox = require("ui.elements.checkbox")
local RadioButton = require("ui.elements.radio_button")
local Dropdown = require("ui.elements.dropdown")
local Row = require("ui.elements.row")
local Column = require("ui.elements.column")
local Splitter = require("ui.elements.splitter")
local Window = require("ui.elements.window")
local ScrollablePanel = require("ui.elements.scrollable_panel")
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
	local pages = {}
	local gallery_files = vfs.Find("lua/ui/gallery/%.lua$")

	for _, file in ipairs(gallery_files) do
		local mod_name = file:gsub("%.lua$", "")
		local ok, page = pcall(require, "ui.gallery." .. mod_name)

		if ok then
			table.insert(pages, page)
		else
			print("Failed to load page: " .. mod_name .. " - " .. tostring(page))
		end
	end

	local content_panel = ScrollablePanel(
		{
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
			},
			Padding = Rect() + theme.GetPadding("S"),
		}
	)

	local function select_page(page)
		print("Selecting page: " .. tostring(page.Name))
		local viewport

		for _, child in ipairs(content_panel:GetChildren()) do
			if child:GetName() == "viewport" then
				viewport = child

				break
			end
		end

		if viewport then
			viewport:RemoveChildren()

			if page and page.Create then
				local content = page.Create()
				viewport:AddChild(content)

				if content.layout then
					-- TODO
					require("timer").Delay(0, function()
						if not content:IsValid() then return end

						content.layout:InvalidateLayout(true)
					end)
				end
			end
		else
			print("Could not find viewport in content_panel")
		end
	end

	if #pages > 0 then select_page(pages[1]) end

	local page_buttons = {}

	for _, page in ipairs(pages) do
		table.insert(
			page_buttons,
			Button(
				{
					Text = page.Name or "Unnamed Page",
					OnClick = function()
						select_page(page)
					end,
					layout = {
						GrowWidth = 1,
					},
				}
			)
		)
	end

	local demo_window = Window(
		{
			Title = "UI GALLERY",
			Size = Vec2(800, 600),
			Padding = "none",
			Position = (world_panel.transform:GetSize() - Vec2(1000, 700)) / 2,
			layout = {
				FitHeight = false,
				FitWidth = false,
			},
		}
	)(
		{
			Splitter({
				InitialSize = 220,
			})(
				{
					ScrollablePanel(
						{
							Color = theme.GetColor("black"):SetAlpha(0.3),
							layout = {
								GrowHeight = 1,
							},
							Padding = Rect() + theme.GetPadding("XXS"),
						}
					)(
						{
							Column(
								{
									layout = {
										ChildGap = 4,
										GrowWidth = 1,
										AlignmentX = "stretch",
									},
								}
							)(page_buttons),
						}
					),
					content_panel,
				}
			),
		}
	)
	menu = Panel.New(
		{
			Name = "GameMenuPanel",
			transform = {
				Size = world_panel.transform:GetSize(),
			},
			rect = {
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
		demo_window,
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
end)
