local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local shapes = import("lua/shapes.lua")

local function make_rotation(pitch, yaw, roll)
	return Quat():SetAngles(Deg3(pitch or 0, yaw or 0, roll or 0))
end

local function add_box_visual(center, rotation, size, material)
	return shapes.Box{
		Name = "debug_compound_visual",
		PhysicsNoCollision = true,
		Collision = false,
		Position = center,
		Rotation = rotation,
		Size = size,
		Material = material,
	}
end

local function spawn_static_box(center, size, material, rotation, friction)
	rotation = rotation or make_rotation()
	local ent = shapes.Box{
		Name = "debug_walk_box",
		Position = center,
		Rotation = rotation,
		Size = size,
		Material = material,
		RigidBody = {
			MotionType = "static",
			Friction = friction or 0.7,
			Restitution = 0,
		},
	}
	add_box_visual(center, rotation, size, material)
	return ent
end

local function spawn_stairs(base_center, step_count, step_size, material)
	for i = 1, step_count do
		local size = Vec3(step_size.x, step_size.y * i, step_size.z)
		local center = base_center + Vec3(step_size.x * (i - 0.5), size.y * 0.5, 0)
		spawn_static_box(center, size, material)
	end
end

local walk_material = shapes.Material{
	Albedo = "return vec4(0.22, 0.20, 0.18, 1.0);",
	Metallic = "return vec4(0.0);",
	Roughness = "return vec4(0.88);",
}
spawn_static_box(Vec3(-10, -3.5, 3.5), Vec3(18, 1, 14), walk_material)
spawn_stairs(Vec3(-16, -3.0, 0), 6, Vec3(1.1, 0.45, 4.5), walk_material)
spawn_static_box(Vec3(-8.4, -0.075, 0), Vec3(5.5, 0.45, 4.5), walk_material)
spawn_static_box(
	Vec3(-3.8, 0.75, 0),
	Vec3(6.5, 0.6, 4.5),
	walk_material,
	make_rotation(0, 0, -18),
	0.8
)
spawn_static_box(Vec3(1.4, 1.85, 0), Vec3(6, 0.7, 4.5), walk_material)
spawn_static_box(Vec3(5.5, 2.55, 0), Vec3(2.2, 2.1, 4.5), walk_material)
spawn_static_box(Vec3(9.2, 3.05, 0), Vec3(5.2, 0.55, 4.5), walk_material)
spawn_static_box(Vec3(12.8, 2.15, 0), Vec3(2.2, 1.25, 4.5), walk_material)
