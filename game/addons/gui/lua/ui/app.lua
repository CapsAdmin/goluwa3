local event = import("goluwa/event.lua")
local Panel = import("goluwa/ecs/panel.lua")
local system = import("goluwa/system.lua")
local Editor = import("./widgets/editor.lua")
local line = import("goluwa/love/line.lua")
local world_panel = Panel.World
local editor_window = NULL
local selected_entity_guid = nil
local visible = false
local suppress_close_callback = false
world_panel:RemoveKeyed("GameMenuPanel")
world_panel:RemoveKeyed("GameEditorWindow")
world_panel:RemoveKeyed("EditorMenuBarContextMenu")

local function love_game_active()
	for _, love in ipairs(line.love_envs or {}) do
		if love and love._line_env and not love._line_env.error_message then
			return true
		end
	end

	return false
end

local function build_editor(position, size)
	world_panel:RemoveKeyed("EditorMenuBarContextMenu")

	if editor_window:IsValid() then
		suppress_close_callback = true
		editor_window:Remove()
		editor_window = NULL
		suppress_close_callback = false
	end

	system.GetWindow():SetMouseTrapped(false)
	visible = true
	editor_window = world_panel:Ensure(
		Editor{
			Key = "GameEditorWindow",
			SelectedEntityGUID = selected_entity_guid,
			Position = position,
			Size = size,
			OnClose = function(self, guid)
				selected_entity_guid = guid

				if suppress_close_callback then return end

				if self and self:IsValid() then self:Remove() end

				editor_window = NULL
				visible = false

				if not love_game_active() then system.GetWindow():SetMouseTrapped(true) end
			end,
			OnThemeChange = function(guid, next_position, next_size)
				selected_entity_guid = guid
				build_editor(next_position, next_size)
			end,
		}
	)
	return editor_window
end

local function toggle()
	visible = not visible

	if not visible then
		world_panel:RemoveKeyed("EditorMenuBarContextMenu")

		if editor_window:IsValid() then
			editor_window:Remove()
			editor_window = NULL
		end

		if not love_game_active() then system.GetWindow():SetMouseTrapped(true) end

		return false
	end

	build_editor()
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
