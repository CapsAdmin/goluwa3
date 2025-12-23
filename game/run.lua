_G.PROFILE = false
_G.GRAPHICS = true
local render = require("render.render")
local render2d = require("render2d.render2d")
local render3d = require("render3d.render3d")
local gfx = require("render2d.gfx")
local system = require("system")
local vfs = require("vfs")
vfs.MountStorageDirectories()
--_G.require = vfs.Require
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
	require("render3d.model_loader")
	require("components.transform")
	require("components.model")
	require("components.light")
end

vfs.AutorunAddons()
system.KeepAlive("game")
