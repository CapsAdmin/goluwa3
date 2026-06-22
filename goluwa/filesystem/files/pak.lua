local objects = import("goluwa/objects/objects.lua")
local CONTEXT = objects.CreateTemplate("file_system_crytek_pak")
CONTEXT.Name = "crytek package"
CONTEXT.Extension = "pak"
CONTEXT.Base = import("goluwa/filesystem/files/zip.lua")
return CONTEXT:Register()
