local prototype = import("goluwa/prototype.lua")
local CONTEXT = prototype.CreateTemplate("file_system_crytek_pak")
CONTEXT.Name = "crytek package"
CONTEXT.Extension = "pak"
CONTEXT.Base = import("goluwa/filesystem/files/zip.lua")
return CONTEXT:Register()
