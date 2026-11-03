local desktop = import("goluwa/render2d/ui/desktop.lua")
local effects_editor = import("lua/jrpg/effects_editor.lua")
desktop.RegisterProgram{
	Name = "Effects editor",
	Icon = "layout",
	Positioned = true,
	Interactive = true,
	Create = effects_editor.Create,
	OnEscape = function(window)
		window:OnClose()
		return true
	end,
}
