--[[
	Dynamic stress scene for the scene_bvh partial rebuild work.

	Mixes a large static environment with four groups of continuous movers so
	the fraction of the scene that is dirty per frame varies a lot:

	Static, left to right along x:
	  * Cornell room (x -16): coloured walls, box and sphere.
	  * Emissive tunnel (x 0): closed tunnel with an orange emissive bar.
	  * Pillar hall (x 16): pillars along an enclosed hall.

	Dynamic, left to right:
	  * Big sweep (x 32): one large box shuttling back and forth. High dirty
	    triangle fraction from a single visual.
	  * Orbit ring (x 44): six spheres on a shared orbit. Several medium
	    movers, all moving every frame.
	  * Swarm (x 56): many small boxes on dephased sinusoidal paths. High
	    visual count, low fraction per visual.
	  * Rig (x 68): one parent box with three children. One transform change
	    moves four visuals, exercising the subtree cascade.

	Motion is continuous on purpose: the scene never settles, so the bvh dirty
	window stays open and the rebuild throttle is exercised every frame. Point
	lights above each dynamic group keep the occlusion dirty-box path warm.

	Useful console commands: scene_bvh_info (triangle/node counts, dirty
	window), scene_bvh_rebuild.

	Run: luajit glw --3d lua addons/examples/lua/examples/render3d/bvh_dynamic.lua
]]
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local Event = import("goluwa/event.lua")
local System = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
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
	return shapes.Box{
		Name = name,
		Position = position,
		Size = size,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local function sphere(name, position, radius, material)
	return shapes.Sphere{
		Name = name,
		Position = position,
		Radius = radius,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local function light(name, position, range, color)
	local ent = Entity.New{Name = name}
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	local c = ent:AddComponent("light")
	c:SetLightType("point")
	c:SetColor(color)
	c:SetIntensity(5000)
	c:SetRange(range)
	return c
end

local white = mat(Color(0.8, 0.8, 0.8, 1), 0.9)
local grey = mat(Color(0.4, 0.4, 0.4, 1), 0.9)
local red = mat(Color(0.75, 0.08, 0.05, 1), 0.9)
local green = mat(Color(0.08, 0.6, 0.1, 1), 0.9)
local blue = mat(Color(0.1, 0.25, 0.8, 1), 0.7)
local yellow = mat(Color(0.9, 0.75, 0.15, 1), 0.7)
local orange = mat(Color(0.9, 0.4, 0.05, 1), 0.9)
box("ground", Vec3(28, -1, 0), Vec3(110, 2, 40), mat(Color(0.9, 0.9, 0.9, 1), 1, 1))

-- cornell room, open towards +z, roof with a gap so the sun gets in
do
	local cx, w, h, d, t = -16, 12, 8, 12, 0.5
	box("cornell_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("cornell_back", Vec3(cx, h / 2, -d / 2), Vec3(w, h, t), white)
	box("cornell_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), red)
	box("cornell_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), green)
	box("cornell_roof_back", Vec3(cx, h, -d / 4 - 1), Vec3(w, t, d / 2 - 2), white)
	box("cornell_roof_front", Vec3(cx, h, d / 4 + 1), Vec3(w, t, d / 2 - 2), white)
	box("cornell_box", Vec3(cx - 2.5, 1.5, -2), Vec3(3, 3, 3), white)
	sphere("cornell_sphere", Vec3(cx + 2.5, 1.5, 1.5), 1.5, white)
end

-- emissive tunnel, closed at both ends except a doorway on +z
do
	local cx, w, h, d, t = 0, 6, 4, 14, 0.5
	box("tunnel_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("tunnel_roof", Vec3(cx, h, 0), Vec3(w, t, d), white)
	box("tunnel_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), white)
	box("tunnel_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), white)
	box("tunnel_back", Vec3(cx, h / 2, -d / 2), Vec3(w, h, t), white)
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

-- pillar hall
do
	local cx, w, h, d, t = 16, 8, 5, 22, 0.5
	box("hall_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("hall_roof", Vec3(cx, h, 0), Vec3(w, t, d), white)
	box("hall_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), white)
	box("hall_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), white)
	box("hall_back", Vec3(cx, h / 2, -d / 2), Vec3(w, h, t), orange)

	for i, z in ipairs{-7, -2.5, 2, 6.5} do
		box(
			"hall_pillar_" .. i,
			Vec3(cx + (i % 2 == 0 and 2 or -2), 1.5, z),
			Vec3(1, 3, 1),
			grey
		)
	end
end

-- big sweep: one large box, high dirty fraction from a single visual
local big_sweep = box("big_sweep", Vec3(32, 2, 0), Vec3(3, 3, 3), yellow)
light("big_sweep_light", Vec3(32, 8, 0), 18, Color(1, 0, 0, 1))
-- orbit ring: several medium movers, all moving every frame
local orbiters = {}

for i = 1, 6 do
	orbiters[i] = sphere("orbiter_" .. i, Vec3(44, 1.2, 0), 1.2, i % 2 == 0 and blue or orange)
end

light("orbit_light", Vec3(44, 8, 0), 18, Color(0, 1, 0, 1))
-- swarm: many small boxes on dephased paths
local SWARM_COUNT = 24
local swarm = {}

for i = 1, SWARM_COUNT do
	swarm[i] = box("swarm_" .. i, Vec3(56, 2, 0), Vec3(0.4, 0.4, 0.4), i % 3 == 0 and red or green)
end

light("swarm_light", Vec3(56, 8, 0), 18, Color(0, 0, 1, 1))
-- rig: one parent transform change moves four visuals (subtree cascade)
local rig = box("rig_parent", Vec3(68, 2, 0), Vec3(1.5, 1.5, 1.5), blue)
local rig_children = {}

do
	local arms = {
		Vec3(1.8, 0, 0),
		Vec3(-0.9, 0, 1.56),
		Vec3(-0.9, 0, -1.56),
	}

	for i, offset in ipairs(arms) do
		local child = box("rig_child_" .. i, offset, Vec3(1, 1, 1), i == 1 and red or green)
		child:SetParent(rig)
		rig_children[i] = child
	end
end

light("rig_light", Vec3(68, 8, 0), 18, Color(1, 1, 0, 1))

local function update_movers(t)
	big_sweep.transform:SetPosition(Vec3(32 + 4 * math.sin(t * 0.6), 2, 0))

	for i = 1, #orbiters do
		local angle = t * 0.9 + (i - 1) * math.pi / 3
		orbiters[i].transform:SetPosition(
			Vec3(44 + 5 * math.cos(angle), 1.2 + 0.5 * math.sin(t * 2 + i), 5 * math.sin(angle))
		)
	end

	for i = 1, #swarm do
		local ph = (i - 1) * 0.7
		local ent = swarm[i]
		ent.transform:SetPosition(
			Vec3(
				56 + 4 * math.sin(t * 0.7 + ph),
				2 + 1.5 * math.sin(t * 1.1 + ph * 2),
				4 * math.sin(t * 0.9 + ph * 3)
			)
		)
		ent.transform:SetAngles(Deg3(t * 40 + i * 15, t * 30, 0))
	end

	local rig_angle = t * 0.5
	rig.transform:SetPosition(Vec3(68 + 3 * math.cos(rig_angle), 2, 3 * math.sin(rig_angle)))
	rig.transform:SetAngles(Deg3(0, -rig_angle * 57.2958, 0))
end

Event.AddListener("Update", "bvh_dynamic_update", function()
	update_movers(System.GetElapsedTime())
end)

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(30, 12, 30))
	cam:SetAngles(Deg3(-18, -8, 0))
	cam:SetFOV(math.rad(60))
end
