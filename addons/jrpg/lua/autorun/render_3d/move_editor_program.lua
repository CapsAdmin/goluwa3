local desktop = import("goluwa/render2d/ui/desktop.lua")
local move_editor = import("lua/jrpg/move_editor.lua")
desktop.RegisterProgram{
	Name = "Move editor",
	Icon = "layout",
	Positioned = true,
	Interactive = true,
	Create = move_editor.Create,
	OnEscape = function(window)
		window:OnClose()
		return true
	end,
}
