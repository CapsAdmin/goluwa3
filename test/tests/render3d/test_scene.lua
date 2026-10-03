local T = import("test/environment.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function count_children()
	return #test_scene.GetRoot():GetChildren()
end

T.Test3D("test_scene room builds six pieces, or nine with an opening", function()
	test_scene.Reset()
	test_scene.Room{size = Vec3(8, 3, 8)}
	T(count_children())["=="](6)
	test_scene.Reset()
	test_scene.Room{
		size = Vec3(8, 3, 8),
		openings = {{wall = "+z", x = 0, y = 1.6, width = 2, height = 1.2}},
	}
	T(count_children())["=="](9)
	test_scene.Reset()
end)

T.Test3D("test_scene reset removes only what the helpers made", function()
	test_scene.Reset()
	test_scene.Ground{}
	test_scene.Box{name = "crate", pos = Vec3(0, 1, 0), size = Vec3(1, 1, 1)}
	T(count_children())["=="](2)
	local root = test_scene.GetRoot()
	test_scene.Reset()
	T(root:IsValid())["=="](false)
	T(count_children())["=="](0)
	test_scene.Reset()
end)

T.Test("test_scene env knobs treat empty as unset", function()
	T(test_scene.GetNumber("GLW_TEST_SCENE_UNSET", 7))["=="](7)
	T(test_scene.GetString("GLW_TEST_SCENE_UNSET", "x"))["=="]("x")
end)
