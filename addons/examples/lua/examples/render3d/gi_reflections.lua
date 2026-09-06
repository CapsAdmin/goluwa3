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
	  * Multi-bounce bleed box (x 34): magenta/orange/cyan walls in a tight
	    room lit only through a roof gap, so the interior sphere and floor
	    should pick up several bounces of mixed colour rather than one tint.
	  * Thin-wall partition (x 52): a lit chamber and a fully sealed dark
	    chamber share a 0.15 m wall, with an emissive strip right against the
	    lit side. The dark chamber should stay essentially black; any glow
	    there is GI leaking through geometry thinner than a voxel.
	  * Pillar hall (x 72): an emissive back wall, alternating pillars, and a
	    22 m enclosed hall to a doorway at the front. Exercises the occlusion
	    march (light should dim as it has to bend around pillars) and probe
	    cascade transitions along the length.
	  * Two-storey shaft (x 92): a sealed ground floor lit only by whatever
	    bounces down a stairwell hole from an upper floor with a narrow roof
	    light well. Tests probe cascades stacked in y.

	Useful console commands: voxel_gi_debug (show gi irradiance only),
	voxel_gi_probes (probe overlay), voxel_gi_occlusion (toggle the occlusion
	march), voxel_gi_visibility (toggle the Chebyshev visibility test),
	envprobe_reflection_probes, envprobe_dump, voxel_gi_invalidate.

	Run: USE_MOLTENVK=1 luajit glw --3d lua addons/examples/lua/examples/render3d/gi_reflections.lua
]]
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local envprobe = import("goluwa/render3d/envprobe.lua")
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
local magenta = mat(Color(0.7, 0.1, 0.6, 1), 0.9)
local orange = mat(Color(0.9, 0.4, 0.05, 1), 0.9)
local cyan = mat(Color(0.05, 0.6, 0.65, 1), 0.9)
-- ground, wide enough to run under every room including the new ones out at x 92
box("ground", Vec3(20, -1, 0), Vec3(170, 2, 120), mat(Color(0.9, 0.9, 0.9, 1), 0.05, 1))

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
	envprobe.CreateReflectionProbe(Vec3(cx, h / 2, 0), 16, envprobe.UPDATE_STATIC)
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
	envprobe.CreateReflectionProbe(Vec3(cx, 3, 0), 20, envprobe.UPDATE_STATIC)
end

-- multi-bounce colour bleed box: three saturated walls in a tight room, open
-- at the front and lit only through a roof gap, so the interior sphere and
-- floor should show several bounces of mixed colour rather than one tint
do
	local cx, w, h, d, t = 34, 8, 6, 8, 0.5
	box("bleed_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("bleed_back", Vec3(cx, h / 2, -d / 2), Vec3(w, h, t), magenta)
	box("bleed_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), orange)
	box("bleed_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), cyan)
	box("bleed_roof_back", Vec3(cx, h, -d / 4 - 1), Vec3(w, t, d / 2 - 2), white)
	box("bleed_roof_front", Vec3(cx, h, d / 4 + 1), Vec3(w, t, d / 2 - 2), white)
	sphere("bleed_sphere", Vec3(cx, 1.5, 0), 1.5, white)
end

-- thin partition: a lit chamber shares a 0.15 m wall with a fully sealed dark
-- chamber, with an emissive strip right against the partition on the lit
-- side. The dark chamber has no light source of its own, so any glow in it
-- is GI leaking through geometry thinner than a voxel rather than around it.
do
	local cx, w, h, d, t, pt = 52, 10, 5, 8, 0.5, 0.15
	local half = (w - pt) / 2
	local lit_cx = cx - pt / 2 - half / 2
	local dark_cx = cx + pt / 2 + half / 2
	box("partition_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), grey)
	box("partition_wall", Vec3(cx, h / 2, 0), Vec3(pt, h, d), grey)

	box("partition_lit_back", Vec3(lit_cx, h / 2, -d / 2), Vec3(half, h, t), white)
	box("partition_lit_left", Vec3(lit_cx - half / 2, h / 2, 0), Vec3(t, h, d), white)
	box("partition_lit_front", Vec3(lit_cx, h / 2, d / 2), Vec3(half, h, t), white)
	box("partition_lit_roof_back", Vec3(lit_cx, h, -d / 4 - 1), Vec3(half, t, d / 2 - 2), white)
	box("partition_lit_roof_front", Vec3(lit_cx, h, d / 4 + 1), Vec3(half, t, d / 2 - 2), white)
	box(
		"partition_lamp",
		Vec3(lit_cx + half / 2 - 0.15, h / 2, 0),
		Vec3(0.1, h - 1, d - 2),
		emissive_mat(Color(1, 0.9, 0.7, 1), 6)
	)

	box("partition_dark_back", Vec3(dark_cx, h / 2, -d / 2), Vec3(half, h, t), grey)
	box("partition_dark_right", Vec3(dark_cx + half / 2, h / 2, 0), Vec3(t, h, d), grey)
	box("partition_dark_front", Vec3(dark_cx, h / 2, d / 2), Vec3(half, h, t), grey)
	box("partition_dark_roof", Vec3(dark_cx, h, 0), Vec3(half, t, d), grey)
end

-- pillar hall: an emissive panel at one end, alternating pillars along a long
-- enclosed hall, and a doorway at the far end. Light has to bend around the
-- pillars to reach the doorway, exercising the occlusion march, and the 22 m
-- length crosses several probe cascades.
do
	local cx, w, h, d, t = 72, 8, 5, 22, 0.5
	box("hall_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("hall_roof", Vec3(cx, h, 0), Vec3(w, t, d), white)
	box("hall_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), white)
	box("hall_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), white)
	box(
		"hall_lamp_wall",
		Vec3(cx, h / 2, -d / 2),
		Vec3(w, h, t),
		emissive_mat(Color(1, 0.35, 0.15, 1), 10)
	)
	-- low doorway in the front wall
	box("hall_front_top", Vec3(cx, h - 0.75, d / 2), Vec3(w, 1.5, t), white)
	box("hall_front_left", Vec3(cx - 3, 1.25, d / 2), Vec3(2, 2.5, t), white)
	box("hall_front_right", Vec3(cx + 3, 1.25, d / 2), Vec3(2, 2.5, t), white)

	for i, z in ipairs({-7, -2.5, 2, 6.5}) do
		box("hall_pillar_" .. i, Vec3(cx + (i % 2 == 0 and 2 or -2), 1.5, z), Vec3(1, 3, 1), grey)
	end
end

-- two-storey shaft: a sealed ground floor lit only by whatever bounces down
-- a stairwell hole from an upper floor with a narrow roof light well. Tests
-- probe cascades stacked in y and bounce travelling down a shaft.
do
	local cx, w, d, t, hole, well = 92, 8, 8, 0.5, 2.5, 1.5
	local floor1_h, floor2_h = 4, 4
	local h2 = floor1_h + floor2_h

	box("tower_floor1", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), grey)
	box("tower_wall1_back", Vec3(cx, floor1_h / 2, -d / 2), Vec3(w, floor1_h, t), grey)
	box("tower_wall1_front", Vec3(cx, floor1_h / 2, d / 2), Vec3(w, floor1_h, t), grey)
	box("tower_wall1_left", Vec3(cx - w / 2, floor1_h / 2, 0), Vec3(t, floor1_h, d), grey)
	box("tower_wall1_right", Vec3(cx + w / 2, floor1_h / 2, 0), Vec3(t, floor1_h, d), grey)

	-- mid slab, doubling as floor1's roof and floor2's floor, with a square
	-- stairwell hole built from a frame of four boxes
	local seg = (d - hole) / 2
	local off = d / 2 - seg / 2
	box("tower_slab_back", Vec3(cx, floor1_h, -off), Vec3(w, t, seg), grey)
	box("tower_slab_front", Vec3(cx, floor1_h, off), Vec3(w, t, seg), grey)
	box("tower_slab_left", Vec3(cx - off, floor1_h, 0), Vec3(seg, t, hole), grey)
	box("tower_slab_right", Vec3(cx + off, floor1_h, 0), Vec3(seg, t, hole), grey)

	box("tower_wall2_back", Vec3(cx, floor1_h + floor2_h / 2, -d / 2), Vec3(w, floor2_h, t), grey)
	box("tower_wall2_front", Vec3(cx, floor1_h + floor2_h / 2, d / 2), Vec3(w, floor2_h, t), grey)
	box("tower_wall2_left", Vec3(cx - w / 2, floor1_h + floor2_h / 2, 0), Vec3(t, floor2_h, d), grey)
	box("tower_wall2_right", Vec3(cx + w / 2, floor1_h + floor2_h / 2, 0), Vec3(t, floor2_h, d), grey)

	-- roof, same frame technique but with a narrower light well
	local seg2 = (d - well) / 2
	local off2 = d / 2 - seg2 / 2
	box("tower_roof_back", Vec3(cx, h2, -off2), Vec3(w, t, seg2), grey)
	box("tower_roof_front", Vec3(cx, h2, off2), Vec3(w, t, seg2), grey)
	box("tower_roof_left", Vec3(cx - off2, h2, 0), Vec3(seg2, t, well), grey)
	box("tower_roof_right", Vec3(cx + off2, h2, 0), Vec3(seg2, t, well), grey)

	sphere("tower_sphere1", Vec3(cx, 1.2, 0), 1, white)
	sphere("tower_sphere2", Vec3(cx, floor1_h + 1.2, 0), 1, white)
end

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
