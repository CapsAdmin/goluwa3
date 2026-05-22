local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local init = false
local editor_window = NULL
local selected_entity_guid = nil
local visible = false
local suppress_close_callback = false
local world_panel = NULL
local toggle

local function sync_mouse_trapped_state()
	system.GetWindow():SetMouseTrapped(not visible)
end

local function lazy_init()
	if init then return end

	init = true
	local Panel = import("goluwa/ecs/panel.lua")
	local Editor = import("lua/ui/widgets/editor.lua")
	world_panel = Panel.World
	world_panel:RemoveKeyed("GameMenuPanel")
	world_panel:RemoveKeyed("GameEditorWindow")
	world_panel:RemoveKeyed("EditorMenuBarContextMenu")

	local function build_editor(position, size)
		world_panel:RemoveKeyed("EditorMenuBarContextMenu")

		if editor_window:IsValid() then
			suppress_close_callback = true
			editor_window:Remove()
			editor_window = NULL
			suppress_close_callback = false
		end

		visible = true
		sync_mouse_trapped_state()
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
					sync_mouse_trapped_state()
				end,
				OnThemeChange = function(guid, next_position, next_size)
					selected_entity_guid = guid
					build_editor(next_position, next_size)
				end,
			}
		)
		return editor_window
	end

	function toggle()
		visible = not visible

		if not visible then
			world_panel:RemoveKeyed("EditorMenuBarContextMenu")

			if editor_window:IsValid() then
				editor_window:Remove()
				editor_window = NULL
			end

			sync_mouse_trapped_state()
			return false
		end

		build_editor()
		return false
	end

	if HOTRELOAD then toggle() end
end

event.AddListener("KeyInput", "menu_toggle", function(key, press)
	if not press then return end

	if key == "escape" then
		lazy_init()
		return toggle()
	end
end)

event.AddListener("WindowGainedFocus", "mouse_trap", function()
	if not visible then sync_mouse_trapped_state() end
end) --toggle()
