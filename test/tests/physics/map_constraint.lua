local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/physics_helpers.lua")

local function create_box(name, position, motion)
	local entity = Entity.New({Name = name})
	entity:AddComponent("transform")
	entity.transform:SetPosition(position)
	entity:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(0.5, 0.05, 0.25)),
			Size = Vec3(0.5, 0.05, 0.25),
			MotionType = motion,
		}
	)
	return entity
end

T.TestPhysics("map constraints join bodies at their spawn pose once both have shapes", function()
	local door = create_box("map_constraint_door", Vec3(0, 5, 0), "dynamic")
	local frame = create_box("map_constraint_frame", Vec3(0, 5, 0.5), "static")
	local hinge_entity = Entity.New({Name = "map_constraint_hinge"})
	hinge_entity:AddComponent("transform")
	local hinge = hinge_entity:AddComponent(
		"map_constraint",
		{
			Kind = "hinge",
			Entity0 = door:GetGUID(),
			Entity1 = frame:GetGUID(),
			Anchor0 = Vec3(-0.25, 0, 0),
			Axis0 = Vec3(0, 1, 0),
			HasLimits = true,
			Lower = 0,
			Upper = math.rad(90),
		}
	)
	T(hinge:Build())["=="](true)
	T(hinge.physics_constraint ~= nil)["=="](true)
	local pivot = Vec3(-0.25, 5, 0)
	test_helpers.Simulate(240)
	local anchor = door.transform:GetWorldPosition() + door.transform:GetWorldRotation():VecMul(Vec3(-0.25, 0, 0))
	T((anchor - pivot):GetLength())["<"](0.05)
	hinge_entity:Remove()
	door:Remove()
	frame:Remove()
end)

T.TestPhysics("map constraints wait for the shape model of a body before they are built", function()
	local door = create_box("map_constraint_loading_door", Vec3(0, 5, 0), "dynamic")
	rawset(door.rigid_body, "ShapeModelPath", "models/not_loaded_yet.vmdl_c")
	local hinge_entity = Entity.New({Name = "map_constraint_loading_hinge"})
	hinge_entity:AddComponent("transform")
	local hinge = hinge_entity:AddComponent(
		"map_constraint",
		{
			Kind = "hinge",
			Entity0 = door:GetGUID(),
			Entity1 = "",
			Anchor0 = Vec3(-0.25, 0, 0),
			Axis0 = Vec3(0, 1, 0),
		}
	)
	T(hinge:Build())["=="](false)
	door.rigid_body.shape_model_static = false
	T(hinge:Build())["=="](true)
	hinge_entity:Remove()
	door:Remove()
end)
