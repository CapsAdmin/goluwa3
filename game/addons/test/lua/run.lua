_G.PROFILE = false
_G.GRAPHICS = true
require("goluwa.global_environment")
local render = require("graphics.render")
local render2d = require("graphics.render2d")
local render3d = require("graphics.render3d")
local gfx = require("graphics.gfx")
local system = require("system")
local main_loop = require("main")
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
render.Initialize()
render2d.Initialize()
render3d.Initialize()
gfx.Initialize()

do
	require("components.transform")
	require("components.model")
	require("components.light")
end

vfs.AutorunAddons()

do
	local unref = system.KeepAlive("game")
	main_loop()
	unref()
end
