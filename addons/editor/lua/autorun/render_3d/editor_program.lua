local system = import("goluwa/system.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local selected_entity_guid = nil
desktop.RegisterProgram{
	Name = "Editor",
	Icon = "entity",
	Positioned = true,
	Interactive = true,
	Create = function()
		system.GetWindow():SetMouseTrapped(true)
		Panel.World:RemoveKeyed("EditorMenuBarContextMenu")
		return import("lua/editor.lua"){
			Key = "GameEditorWindow",
			RequestMouse = true,
			SelectedEntityGUID = selected_entity_guid,
			OnClose = function(self, guid)
				selected_entity_guid = guid
				Panel.World:RemoveKeyed("EditorMenuBarContextMenu")
				self:Remove()
			end,
		}
	end,
	OnEscape = function(window)
		if window:IsPlaying() then window:SetPlaying(false) else window:OnClose() end

		return true
	end,
}

if HOTRELOAD then desktop.Open("Editor") end
