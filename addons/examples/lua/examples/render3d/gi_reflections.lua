--[[
	Global illumination and reflection probe test scene.

	Areas, left to right along x:
	  * Cornell room (x -14): red/green walls, white floor and ceiling with a
	    gap, white box and sphere inside. Look for red/green bounce on the
	    white surfaces and a lit interior under the roof.
	  * Emissive tunnel (x 0): a closed tunnel the sun never enters, lit only
	    by an orange emissive bar through voxel gi.
	  * Reflection stage (x 14): metal spheres sweeping roughness on a polished
	    floor between coloured walls, covered by a manual reflection probe. The
	    chrome sphere at the far end mostly reflects things off screen, so it
	    shows the probe rather than ssr.

	Useful console commands: voxel_gi_debug (show gi irradiance only),
	voxel_gi_probes (probe overlay), lightprobes_reflection_probes,
	lightprobes_dump, voxel_gi_invalidate.

	Run: USE_MOLTENVK=1 luajit glw --3d lua addons/examples/lua/examples/render3d/gi_reflections.lua
]]
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local lightprobes = import("goluwa/render3d/lightprobes.lua")
local voxel_gi = import("goluwa/render3d/voxel_gi.lua")
local shapes = import("lua/shapes.lua")

local function mat(color, roughness, metallic)
	return shapes.Material{Color = color, Roughness = roughness, Metallic = metallic or 0}
end

local function emissive_mat(color, strength)
	return shapes.Material{
		Color = color,
		Roughness = 0.8,
		Metallic = 0,
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 1, 1, strength),
	}
end

local function box(name, position, size, material)
	shapes.Box{
		Name = name,
		Position = position,
		Size = size,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local function sphere(name, position, radius, material)
	shapes.Sphere{
		Name = name,
		Position = position,
		Radius = radius,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local white = mat(Color(0.8, 0.8, 0.8, 1), 0.9)
local grey = mat(Color(0.4, 0.4, 0.4, 1), 0.9)
local red = mat(Color(0.75, 0.08, 0.05, 1), 0.9)
local green = mat(Color(0.08, 0.6, 0.1, 1), 0.9)
local blue = mat(Color(0.1, 0.25, 0.8, 1), 0.7)
local yellow = mat(Color(0.9, 0.75, 0.15, 1), 0.7)
-- ground
box("ground", Vec3(0, -1, 0), Vec3(120, 2, 120), mat(Color(0.9, 0.9, 0.9, 1), 0.05, 1))

-- cornell room, open towards +z, roof with a gap so the sun gets in
do
	local cx, w, h, d, t = -14, 12, 8, 12, 0.5
	box("cornell_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("cornell_back", Vec3(cx, h / 2, -d / 2), Vec3(w, h, t), white)
	box("cornell_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), red)
	box("cornell_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), green)
	box("cornell_roof_back", Vec3(cx, h, -d / 4 - 1), Vec3(w, t, d / 2 - 2), white)
	box("cornell_roof_front", Vec3(cx, h, d / 4 + 1), Vec3(w, t, d / 2 - 2), white)
	box("cornell_box", Vec3(cx - 2.5, 1.5, -2), Vec3(3, 3, 3), white)
	sphere("cornell_sphere", Vec3(cx + 2.5, 1.5, 1.5), 1.5, white)
	lightprobes.CreateReflectionProbe(Vec3(cx, h / 2, 0), 16, lightprobes.UPDATE_STATIC)
end

-- emissive tunnel, closed at both ends except a doorway on +z
do
	local cx, w, h, d, t = 0, 6, 4, 14, 0.5
	box("tunnel_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("tunnel_roof", Vec3(cx, h, 0), Vec3(w, t, d), white)
	box("tunnel_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), white)
	box("tunnel_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), white)
	box("tunnel_back", Vec3(cx, h / 2, -d / 2), Vec3(w, h, t), white)
	-- front wall with a low doorway
	box("tunnel_front_top", Vec3(cx, h - 0.75, d / 2), Vec3(w, 1.5, t), white)
	box("tunnel_front_left", Vec3(cx - 2.25, 1.25, d / 2), Vec3(1.5, 2.5, t), white)
	box("tunnel_front_right", Vec3(cx + 2.25, 1.25, d / 2), Vec3(1.5, 2.5, t), white)
	box(
		"tunnel_lamp",
		Vec3(cx, h - 0.6, -3),
		Vec3(4, 0.3, 0.6),
		emissive_mat(Color(1, 0.55, 0.2, 1), 8)
	)
	sphere("tunnel_sphere", Vec3(cx - 1.5, 1, -3), 1, white)
	box("tunnel_pillar", Vec3(cx + 1.5, 1.25, -1), Vec3(1, 2.5, 1), blue)
end

-- reflection stage: polished floor, coloured walls, metal spheres
do
	local cx, w, d = 16, 14, 12
	box(
		"stage_floor",
		Vec3(cx, 0.05, 0),
		Vec3(w, 0.1, d),
		mat(Color(0.9, 0.9, 0.9, 1), 0.05, 1)
	)
	box("stage_back", Vec3(cx, 3, -d / 2), Vec3(w, 6, 0.5), blue)
	box("stage_right", Vec3(cx + w / 2, 3, 0), Vec3(0.5, 6, d), yellow)
	box("stage_left", Vec3(cx - w / 2, 3, 0), Vec3(0.5, 6, d), red)

	for i = 0, 4 do
		sphere(
			"stage_metal_" .. i,
			Vec3(cx - 5 + i * 2.5, 1.2, -2),
			1.2,
			mat(Color(0.95, 0.75, 0.4, 1), i / 4, 1)
		)
	end

	sphere("stage_chrome", Vec3(cx, 2, 3), 2, mat(Color(0.95, 0.95, 0.95, 1), 0.02, 1))
	sphere("stage_dielectric", Vec3(cx - 5, 1, 3), 1, mat(Color(0.9, 0.9, 0.9, 1), 0.15, 0))
	lightprobes.CreateReflectionProbe(Vec3(cx, 3, 0), 20, lightprobes.UPDATE_STATIC)
end

lightprobes.SetReflectionProbesEnabled(true)
voxel_gi.SetEnabled(true)

-- start in front of the scene looking at all three areas
do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(2, 5, 24))
	cam:SetAngles(Deg3(-8, 0, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.transform:SetPosition(cam:GetPosition():Copy())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end
