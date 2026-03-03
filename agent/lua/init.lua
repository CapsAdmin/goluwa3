local system = require("system")
_G.PROFILE = false
local vfs = require("vfs")
vfs.MountStorageDirectories()
_G.require = vfs.Require
_G.runfile = function(...)
	local ret = list.pack(vfs.RunFile(...))

	-- not very ideal
	if ret[1] == false and type(ret[2]) == "string" then error(ret[2], 2) end

	return list.unpack(ret)
end
_G.R = vfs.GetAbsolutePath
require("repl").Initialize()
system.KeepAlive("agent")
require("filewatcher").Start()