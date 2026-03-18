local T = import("test/environment.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local box_shape = BoxShape.New
local compound_shape = CompoundShape.New

T.Test3D("Rigid bodies derive accurate mass properties and full inertia behavior from shape geometry", function()
	local solid_ent = Entity.New({Name = "rigid_inertia_solid_box"})
	solid_ent:AddComponent("transform")
	local solid = solid_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(5, 1, 1)),
			Size = Vec3(5, 1, 1),
			AutomaticMass = false,
			Mass = 2,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
		}
	)
	local dumbbell_ent = Entity.New({Name = "rigid_inertia_compound"})
	dumbbell_ent:AddComponent("transform")
	local dumbbell = dumbbell_ent:AddComponent(
		"rigid_body",
		{
			Shape = compound_shape{
				{
					Shape = box_shape(Vec3(1, 1, 1)),
					Position = Vec3(-2, 0, 0),
				},
				{
					Shape = box_shape(Vec3(1, 1, 1)),
					Position = Vec3(2, 0, 0),
				},
			},
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
		}
	)
	T(solid.ComputedMass)["=="](2)
	T(dumbbell.ComputedMass)["=="](2)
	solid:ApplyAngularImpulse(Vec3(0, 2, 0))
	dumbbell:ApplyAngularImpulse(Vec3(0, 2, 0))
	local solid_angular = solid:GetAngularVelocity()
	local dumbbell_angular = dumbbell:GetAngularVelocity()
	T(solid_angular.y)[">"](0.4)
	T(dumbbell_angular.y)[">"](0.15)
	T(dumbbell_angular.y)["<"](solid_angular.y * 0.7)
	T(math.abs(dumbbell_angular.x))["<"](0.01)
	T(math.abs(dumbbell_angular.z))["<"](0.01)
	solid_ent:Remove()
	dumbbell_ent:Remove()
end)
