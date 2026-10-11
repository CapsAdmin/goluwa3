local objects = import("goluwa/objects/objects.lua")
local DermaTheme = import("./derma.lua")
local DermaDarkTheme = objects.CreateTemplate("ui_theme_derma_dark")
DermaDarkTheme.Base = DermaTheme
DermaDarkTheme.Name = "derma_dark"
DermaDarkTheme.SkinPath = "textures/gui/skins/dark.png"
return DermaDarkTheme:Register()
