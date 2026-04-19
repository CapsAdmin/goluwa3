local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local Panel = import("goluwa/ecs/panel.lua")
local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")
local theme = import("./theme.lua")
local MenuBar = import("./elements/menu_bar.lua")
local MenuItem = import("./elements/context_menu_item.lua")
local MenuSpacer = import("./elements/menu_spacer.lua")
local Frame = import("./elements/frame.lua")
local Gallery = import("./widgets/gallery.lua")
local line = import("goluwa/love/line.lua")
local world_panel = Panel.World
local menu = NULL
local visible = false
world_panel:RemoveChildren()

local function love_game_active()
	for _, love in ipairs(line.love_envs or {}) do
		if love and love._line_env and not love._line_env.error_message then
			return true
		end
	end

	return false
end

local function toggle()
	visible = not visible

	if menu:IsValid() then
		menu:Remove()

		if not visible then
			if not love_game_active() then system.GetWindow():SetMouseTrapped(true) end

			return
		end
	end

	system.GetWindow():SetMouseTrapped(false)

	local function open_gallery()
		world_panel:Ensure(Gallery({Key = "GalleryWindow"}))
	end

	local function build_game_menu()
		return {
			MenuItem{Text = "LOAD", OnClick = open_gallery},
			MenuItem{Text = "RUN (ESCAPE)", Disabled = true},
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
	end

	local function build_placeholder_menu(label)
		return {
			MenuItem{Text = label .. " Settings", Disabled = true},
			MenuItem{Text = label .. " Tools", Disabled = true},
		}
	end

	local top_bar = Frame{
		layout = {
			GrowWidth = 1,
			FitHeight = true,
		},
		Padding = Rect() + theme.GetSize("XXS"),
	}{
		MenuBar{
			MenuKey = "AppMenuBarContextMenu",
			Items = {
				{Text = "GAME", Items = build_game_menu},
				{
					Text = "CONFIG",
					Items = function()
						return build_placeholder_menu("CONFIG")
					end,
				},
				{
					Text = "CHEAT",
					Items = function()
						return build_placeholder_menu("CHEAT")
					end,
				},
				{
					Text = "NETPLAY",
					Items = function()
						return build_placeholder_menu("NETPLAY")
					end,
				},
				{
					Text = "MISC",
					Items = function()
						return build_placeholder_menu("MISC")
					end,
				},
			},
			GrowWidth = false,
		},
	}
	menu = Panel.New{
		Key = "GameMenuPanel",
		Parent = world_panel,
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
		mouse_input = false,
		clickable = false,
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

	if love_game_active() then return end

	if key == "escape" then return toggle() end
end)

event.AddListener("Update", "window_title", function(dt)
	if wait(1) then
		system.GetWindow():SetTitle("FPS: " .. math.round(1 / system.GetFrameTime()))
	end
end)

event.AddListener("WindowGainedFocus", "mouse_trap", function()
	if not visible and not love_game_active() then
		system.GetWindow():SetMouseTrapped(true)
	end
end) --toggle()
