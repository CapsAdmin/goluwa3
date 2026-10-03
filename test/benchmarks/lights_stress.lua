-- glw: --3d
-- a grid of closed rooms with doorways and point lights spread over them, like
-- the lights of a BSP map. each phase swaps the lights for another count and range
local frame_benchmark = import("goluwa/render3d/frame_benchmark.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Entity = import("goluwa/entities/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ROOMS = test_scene.GetNumber("LS_ROOMS", 6)
local CLUTTER = test_scene.GetNumber("LS_CLUTTER", 4)
local W, H, T, DOOR = 10, 4, 0.3, 2
local lights = {}

local function build_scene()
	test_scene.Reset()
	local white = test_scene.Matte(0.8)
	local tints = {
		test_scene.Matte(Color(0.75, 0.2, 0.15, 1)),
		test_scene.Matte(Color(0.2, 0.6, 0.25, 1)),
		test_scene.Matte(Color(0.2, 0.3, 0.75, 1)),
	}
	local extent = ROOMS * W
	test_scene.Box{pos = Vec3(extent / 2, -0.5, extent / 2), size = Vec3(extent + 4, 1, extent + 4), material = white}
	test_scene.Box{pos = Vec3(extent / 2, H + T / 2, extent / 2), size = Vec3(extent + 4, T, extent + 4), material = white}

	-- walls along x and z at every room boundary, each with a doorway in the middle
	for i = 0, ROOMS do
		for j = 0, ROOMS - 1 do
			local a, seg = i * W, (W - DOOR) / 2
			local material = tints[(i + j) % 3 + 1]
			local b0, b1 = j * W + seg / 2, j * W + W - seg / 2
			local closed = i == 0 or i == ROOMS
			test_scene.Box{pos = Vec3(a, H / 2, b0), size = Vec3(T, H, closed and W or seg), material = material}
			test_scene.Box{pos = Vec3(b0, H / 2, a), size = Vec3(closed and W or seg, H, T), material = material}

			if not closed then
				test_scene.Box{pos = Vec3(a, H / 2, b1), size = Vec3(T, H, seg), material = material}
				test_scene.Box{pos = Vec3(b1, H / 2, a), size = Vec3(seg, H, T), material = material}
			end
		end
	end

	for rx = 0, ROOMS - 1 do
		for rz = 0, ROOMS - 1 do
			for k = 1, CLUTTER do
				local sphere = shapes.Sphere{
					Position = Vec3(rx * W + 2 + (k * 2.3) % 6, 0.6, rz * W + 2 + (k * 3.7) % 6),
					Radius = 0.6,
					Material = white,
					Collision = false,
					RigidBody = false,
				}
				test_scene.GetRoot():AddChild(sphere)
			end
		end
	end
end

-- lights round robin over the rooms, several per room once there are more
-- lights than rooms
local function set_lights(count, range)
	return function()
		for _, light in ipairs(lights) do
			light:Remove()
		end

		lights = {}

		for n = 0, count - 1 do
			local room = n % (ROOMS * ROOMS)
			local slot = math.floor(n / (ROOMS * ROOMS))
			local rx, rz = room % ROOMS, math.floor(room / ROOMS)
			local entity = Entity.New{Name = "stress_light_" .. n}
			entity:AddComponent("transform")
			entity.transform:SetPosition(Vec3(rx * W + 2.5 + (slot * 2.9) % 5, H - 0.5, rz * W + 2.5 + (slot * 1.7) % 5))
			local light = entity:AddComponent("light_point")
			light:SetColor(Color(1, 0.85, 0.7, 1))
			light:SetLumen(800)
			light:SetRange(range)
			test_scene.GetRoot():AddChild(entity)
			lights[#lights + 1] = entity
		end
	end
end

frame_benchmark.Run{
	name = "lights stress",
	fov = 90,
	load = build_scene,
	view = function()
		return Vec3(1.5, 2, 1.5), -5, 225
	end,
	phases = {
		{name = "0 lights", enter = set_lights(0, 1)},
		{name = "126 lights, range 0.3 m", enter = set_lights(126, 0.3)},
		{name = "126 lights, range 12 m", enter = set_lights(126, 12)},
		{name = "126 lights, range 24 m", enter = set_lights(126, 24)},
		{name = "126 lights, range 100 m", enter = set_lights(126, 100)},
	},
}
