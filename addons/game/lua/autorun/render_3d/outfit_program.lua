local desktop = import("goluwa/render2d/ui/desktop.lua")
local picker = import("lua/outfit_picker.lua")
desktop.RegisterProgram{
	Name = "Outfit",
	Icon = "user",
	Create = picker.Create,
	OnOpen = picker.Refresh,
}
