local system = require("system")
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
require("pvars").Initialize()
require("repl").Initialize()
require("filewatcher").Start()

if _G.GRAPHICS then
	local render = require("render.render")

	if not render.available then
		logf("[game] Graphics not available - running in headless mode\n")
		_G.GRAPHICS = false
	else
		render.Initialize({samples = "1"})
		require("render2d.render2d").Initialize()
		require("render3d.render3d").Initialize()
		require("render2d.gfx").Initialize()
		require("render3d.model_loader")
	end
end

vfs.AutorunAddons()

if _G.AUDIO then vfs.AutorunAddons("audio/") end

if _G.GRAPHICS then
	print("autorunning graphics addons")
	vfs.AutorunAddons("graphics/")
end

system.KeepAlive("game")

do
	local resource = require("resource")
	resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/extras/", true)
	resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/base/", true)
	vfs.MountAddons("os:downloads/")
end
