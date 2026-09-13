--[[
	Noisy static stress scene for the voxel rasterize pass.

	A huge ground plane with many static spheres and boxes scattered
	deterministically around the origin. Nothing moves, so the only thing
	that should trigger rasterize work is camera translation and rotation
	(forward bias).

	Run: luajit glw lua addons/examples/lua/examples/render3d/voxel_noise.lua
]]
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Color = import("goluwa/structs/color.lua")
local Event = import("goluwa/event.lua")
local System = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("lua/shapes.lua")
local SPHERE_COUNT = 300
local BOX_COUNT = 300
local SPREAD = 60
-- deterministic rng
local seed = 12345678

local function rand()
	seed = (seed * 1664525 + 1013904223) % 4294967296
	return seed / 4294967296
end

local function rand_range(min, max)
	return min + rand() * (max - min)
end

local function mat(color, roughness, metallic)
	return shapes.Material{
		Color = color,
		Roughness = roughness,
		Metallic = metallic or 0,
	}
end

local palette = {
	mat(Color(0.8, 0.8, 0.8, 1), 0.9),
	mat(Color(0.75, 0.08, 0.05, 1), 0.9),
	mat(Color(0.08, 0.6, 0.1, 1), 0.9),
	mat(Color(0.1, 0.25, 0.8, 1), 0.7),
	mat(Color(0.9, 0.75, 0.15, 1), 0.7),
	mat(Color(0.4, 0.4, 0.4, 1), 0.9),
	mat(Color(0.6, 0.2, 0.7, 1), 0.6),
	mat(Color(0.9, 0.4, 0.05, 1), 0.9),
}

local function pick_material()
	return palette[1 + math.floor(rand() * #palette)]
end

-- huge ground plane
shapes.Box{
	Name = "ground",
	Position = Vec3(0, -1, 0),
	Size = Vec3(400, 2, 400),
	Material = mat(Color(0.7, 0.7, 0.7, 1), 1, 0),
	Collision = false,
	RigidBody = false,
}

for i = 1, SPHERE_COUNT do
	local x = rand_range(-SPREAD, SPREAD)
	local z = rand_range(-SPREAD, SPREAD)
	local radius = rand_range(0.3, 3.0)
	shapes.Sphere{
		Name = "sphere_" .. i,
		Position = Vec3(x, radius, z),
		Radius = radius,
		Material = pick_material(),
		Collision = false,
		RigidBody = false,
	}
end

for i = 1, BOX_COUNT do
	local x = rand_range(-SPREAD, SPREAD)
	local z = rand_range(-SPREAD, SPREAD)
	local sx = rand_range(0.5, 4.0)
	local sy = rand_range(0.5, 4.0)
	local sz = rand_range(0.5, 4.0)
	local ent = shapes.Box{
		Name = "box_" .. i,
		Position = Vec3(x, sy * 0.5, z),
		Size = Vec3(sx, sy, sz),
		Material = pick_material(),
		Collision = false,
		RigidBody = false,
	}
	ent.transform:SetAngles(Deg3(0, rand() * 360, 0))
end

-- orbit the camera around the scene center so the rasterize pass keeps
-- getting dirty slices from translation and rotation (forward bias).
-- the player controller drives the game camera every Update, so the orbit
-- runs on a render camera override, which is what the pipeline reads
local orbit_cam = render3d.GetCamera():Copy()
orbit_cam:SetFOV(math.rad(60))
render3d.SetRenderCamera(orbit_cam)

Event.AddListener("Update", "voxel_noise_orbit", function()
	local t = System.GetElapsedTime() * 0.25
	local radius = 30
	local x = radius * math.cos(t)
	local z = radius * math.sin(t)
	local y = 8 + 4 * math.sin(t * 0.5)
	orbit_cam:SetPosition(Vec3(x, y, z))
	local pitch = -math.asin(y / math.sqrt(radius * radius + y * y))
	orbit_cam:SetAngles(Ang3(pitch, t - math.pi * 0.5, 0))
end)
