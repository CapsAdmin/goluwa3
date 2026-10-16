-- the particles demo (addons/examples/lua/examples/render3d/particles_demo.lua) from the side, one picture per collision mode
-- luajit glw --3d --background --validate lua "import('test/harnesses/particles/sparks_shot.lua')"
-- OUT=tmp/shots/sparks MODES=shelter_map,scene_depth,rays SETTLE=4
local system = import("goluwa/system.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Shot = import("goluwa/render3d/shot.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local out = test_scene.GetString("OUT", "tmp/shots/sparks")
local modes = {}

for mode in test_scene.GetString("MODES", "shelter_map,scene_depth,rays"):gmatch("[^,]+") do
	modes[#modes + 1] = mode
end

local demo = import("addons/examples/lua/examples/render3d/particles_demo.lua")
local index = 0

local function next_mode()
	index = index + 1

	if not modes[index] then
		system.ShutDown(0)
		return
	end

	demo.SetCollision(modes[index])
	Shot.Capture(
		{Position = Vec3(-7, 1.8, 1), Rotation = QuatDeg3(-3, 240, 0), ExposureLock = test_scene.GetNumber("EV", 12)},
		function(texture)
			print(texture:SaveWithoutAlpha(out .. "_" .. modes[index] .. ".png"))
			next_mode()
		end,
		{settle = test_scene.GetNumber("SETTLE", 4)}
	)
end

test_scene.WhenReady(next_mode)
