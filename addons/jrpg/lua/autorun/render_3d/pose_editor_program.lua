local desktop = import("goluwa/render2d/ui/desktop.lua")
local pose_editor = import("lua/jrpg/pose_editor.lua")
desktop.RegisterProgram{
	Name = "Pose editor",
	Icon = "layout",
	Positioned = true,
	Interactive = true,
	Create = pose_editor.Create,
	OnEscape = function(window)
		window:OnClose()
		return true
	end,
}
