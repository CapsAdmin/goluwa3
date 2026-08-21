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

local function spawn_tilted_box(def)
	def = def or {}
	local ent = shapes.Box{
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
			Friction = 0.1,
			Restitution = 0.8,
		},
	}
	return ent
end

for i = 1, 100 do
	spawn_tilted_box{
		position = ORIGIN + Vec3(0, i + 5, 0),
		size = Vec3():Random(0.5, 5),
		pitch = 60,
		yaw = 30,
		roll = 20,
		material = steel_material,
	}
end
