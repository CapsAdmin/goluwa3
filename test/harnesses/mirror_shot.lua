import("test/harnesses/mirror_scene.lua")
local event = import("goluwa/event.lua")
local Shot = import("goluwa/render3d/shot.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

event.AddListener("BVHSceneReady", "mirror_shot", function()
	print("bvh ready, capturing")

	Shot.Capture(
		{Position = Vec3(0, 1.0, 0), Rotation = QuatDeg3(0, 180, 0), FOV = math.rad(50)},
		function(texture, info)
			print(texture:SaveWithoutAlpha(_G.MIRROR_OUT or "tmp/mirror_out.png"), info.seconds)
			system.ShutDown(0)
		end,
		{settle = 4}
	)
end)
