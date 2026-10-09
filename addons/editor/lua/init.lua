local input = import("goluwa/input.lua")
local system = import("goluwa/system.lua")
local init = false
local editor_window = NULL
local selected_entity_guid = nil
local world_panel = NULL
local toggle

local function lazy_init()
	if init then return end

	init = true
	system.GetWindow():SetMouseTrapped(true)
	local Panel = import("goluwa/render2d/ui/panel.lua")
	local Editor = import("lua/editor.lua")
	world_panel = Panel.World
	world_panel:RemoveKeyed("GameMenuPanel")
	world_panel:RemoveKeyed("GameEditorWindow")
	world_panel:RemoveKeyed("EditorMenuBarContextMenu")

	local function build_editor()
		world_panel:RemoveKeyed("EditorMenuBarContextMenu")
		editor_window = world_panel:Ensure(
			Editor{
				Key = "GameEditorWindow",
				RequestMouse = true,
				SelectedEntityGUID = selected_entity_guid,
				OnClose = function(self, guid)
					selected_entity_guid = guid

					if self and self:IsValid() then self:Remove() end

					editor_window = NULL
				end,
			}
		)
		return editor_window
	end

	function toggle()
		if editor_window:IsValid() then
			world_panel:RemoveKeyed("EditorMenuBarContextMenu")
			editor_window:Remove()
			editor_window = NULL
			return false
		end

		build_editor()
		return false
	end

	if HOTRELOAD then toggle() end
end

ToggleEditor = function()
	lazy_init()
	toggle()
end
input.Bind("escape", "toggle_editor", ToggleEditor)
