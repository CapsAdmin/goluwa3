-- Illustrates the lifted-corner tilt freeze fix: a box dropped with a large
-- tilted rotation used to lock into its pose (phantom manifold points held the
-- lifted corners in place). Now the lift is released once the pair is at rest
-- and the box settles flat onto the ground.
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local shapes = import("lua/shapes.lua")
local ORIGIN = Vec3(0, 0, 0)

local function make_rotation(pitch, yaw, roll)
	return Quat():SetAngles(Deg3(pitch or 0, yaw or 0, roll or 0))
end

local ground_material = shapes.Material{Color = Color(0.22, 0.22, 0.25, 1), Roughness = 0.95, Metallic = 0}
local steel_material = shapes.Material{Color = Color(0.72, 0.77, 0.84, 1), Roughness = 0.22, Metallic = 1}
local wood_material = shapes.Material{Color = Color(0.49, 0.31, 0.16, 1), Roughness = 0.88, Metallic = 0}
local accent_material = shapes.Material{Color = Color(0.20, 0.72, 1.00, 1), Roughness = 0.18, Metallic = 0.1}
local payload_material = shapes.Material{Color = Color(0.94, 0.44, 0.20, 1), Roughness = 0.38, Metallic = 0}

local function spawn_static_box(position, size, material, rotation)
	return shapes.Box{
		Name = "tilt_settle_static_box",
		Position = position,
		Rotation = rotation or make_rotation(),
		Size = size,
		Material = material,
		RigidBody = {
			MotionType = "static",
			Friction = 0.85,
			Restitution = 0,
		},
	}
end

spawn_static_box(ORIGIN - Vec3(0, 1, 0), Vec3(200, 2, 200), ground_material)
local spawned = {}

local function clear_spawned()
	for _, ent in ipairs(spawned) do
		ent:Remove()
	end

	spawned = {}
end

local function spawn_tilted_box(def)
	def = def or {}
	local ent = shapes.Box{
		Name = def.name,
		Position = def.position,
		Rotation = make_rotation(def.pitch, def.yaw, def.roll),
		Size = def.size or Vec3(1, 1, 1),
		Material = def.material,
		RigidBody = {
			Mass = def.mass or 1.2,
			AutomaticMass = false,
			LinearDamping = 0.05,
			AngularDamping = 0.12,
			AirLinearDamping = 0.02,
			AirAngularDamping = 0.05,
			Friction = 0.7,
			Restitution = 0,
		},
	}
	table.insert(spawned, ent)
	return ent
end

local function spawn_all()
	clear_spawned()
	-- The original repro case: 60/30/20 used to freeze at ~6 degrees tilt.
	spawn_tilted_box{
		name = "tilt_settle_main_60_30_20",
		position = ORIGIN + Vec3(-3, 3, 0),
		size = Vec3(1, 1, 1),
		pitch = 60,
		yaw = 30,
		roll = 20,
		material = payload_material,
	}
	-- A couple of other aggressive tilts for comparison.
	spawn_tilted_box{
		name = "tilt_settle_steel_55_0_40",
		position = ORIGIN + Vec3(0, 3, 0),
		size = Vec3(0.8, 1.4, 0.8),
		pitch = 55,
		yaw = 0,
		roll = 40,
		material = steel_material,
		mass = 1.5,
	}
	spawn_tilted_box{
		name = "tilt_settle_wood_70_25_10",
		position = ORIGIN + Vec3(3, 3, 0),
		size = Vec3(1.2, 0.6, 0.9),
		pitch = 70,
		yaw = 25,
		roll = 10,
		material = wood_material,
		mass = 1.1,
	}
	-- A small tilt that already worked before the fix, as a control.
	spawn_tilted_box{
		name = "tilt_settle_control_5_8_3",
		position = ORIGIN + Vec3(6, 3, 0),
		size = Vec3(1, 1, 1),
		pitch = 5,
		yaw = 8,
		roll = 3,
		material = accent_material,
	}
end

spawn_all()
_G.TILT_RESET = spawn_all
