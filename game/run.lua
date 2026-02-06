local system = require("system")
_G.PROFILE = false
_G.GRAPHICS = true
local vfs = require("vfs")
vfs.MountStorageDirectories()
local render = require("render.render")

if not render.available then
	logf("[game] Graphics not available - running in headless mode\n")
	system.KeepAlive("headless_mode")
	-- Load REPL for headless mode
	local repl = require("repl")
	repl.Initialize()
	return
end

_G.require = vfs.Require
_G.runfile = function(...)
	local ret = list.pack(vfs.RunFile(...))

	-- not very ideal
	if ret[1] == false and type(ret[2]) == "string" then error(ret[2], 2) end

	return list.unpack(ret)
end
_G.R = vfs.GetAbsolutePath
render.Initialize({samples = "max"})
require("render2d.render2d").Initialize()
require("render3d.render3d").Initialize()
require("render2d.gfx").Initialize()
require("pvars").Initialize()
require("repl").Initialize()
require("render3d.model_loader")
vfs.AutorunAddons()
system.KeepAlive("game")
require("filewatcher").Start()

do
	local resource = require("resource")
	resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/extras/", true)
	resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/base/", true)
	vfs.MountAddons("os:downloads/")
end
