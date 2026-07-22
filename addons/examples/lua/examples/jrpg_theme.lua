local JRPGTheme = import("goluwa/render2d/ui/themes/jrpg.lua")
local theme = JRPGTheme.New()
theme:Initialize()
local event = import("goluwa/event.lua")

event.AddListener("Draw2D", "test", function()
	theme:DrawMuseum()
end)
