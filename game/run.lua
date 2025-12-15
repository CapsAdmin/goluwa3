_G.PROFILE = false
require("goluwa.global_environment")
local render = require("graphics.render")
local render2d = require("graphics.render2d")
local render3d = require("graphics.render3d")
local gfx = require("graphics.gfx")
local system = require("system")
local main_loop = require("main")
render.Initialize()
render2d.Initialize()
render3d.Initialize()
gfx.Initialize()

do
	require("components.transform")
	require("components.model")
	require("components.light")
	require("game.camera_movement")
end

require("game.test_2d")
require("game.test_occlusion")
--require("game.test_gltf")
require("game.debug")

do
	local unref = system.KeepAlive("game")
	main_loop()
	unref()
end
