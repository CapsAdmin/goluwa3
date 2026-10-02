-- Source engine props colliding using the hulls and mass from their .phy files.
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Entity = import("goluwa/entities/entity.lua")
local steam = import("goluwa/steam/steam.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local shapes = import("lua/shapes.lua")
local surface_properties = import("goluwa/steam/surface_properties.lua")
local physics_lib = import("goluwa/physics.lua")
steam.MountSourceGame("gmod")
local models = {
	"models/props_c17/oildrum001.mdl",
	"models/props_borealis/bluebarrel001.mdl",
	"models/props_c17/bench01a.mdl",
	"models/props_junk/wood_crate001a.mdl",
	"models/props_junk/CinderBlock01a.mdl",
	"models/props_junk/TrafficCone001a.mdl",
	"models/props_junk/wood_pallet001a.mdl",
	"models/props_vehicles/tire001c_car.mdl",
	"models/props_c17/concrete_barrier001a.mdl",
	"models/props_c17/FurnitureShelf001a.mdl",
}
local ORIGIN = Vec3(0, 0, -8)
local SPACING = 2.5
local PER_ROW = 5
shapes.Box{
	Name = "source_physics_props_ground",
	Position = ORIGIN + Vec3(0, -0.5, 0),
	Size = Vec3(30, 1, 30),
	RigidBody = {
		MotionType = "static",
		Friction = surface_properties.Get("concrete").friction,
		Restitution = surface_properties.Get("concrete").elasticity,
		FrictionCombineMode = "multiply",
		RestitutionCombineMode = "multiply",
	},
}

for i, path in ipairs(models) do
	model_loader.LoadModel(
		path,
		function(data)
			local row = math.floor((i - 1) / PER_ROW)
			local column = (i - 1) % PER_ROW - (PER_ROW - 1) / 2
			local physics = data.physics
			local surface = surface_properties.Get(physics.surface_property)
			local center_of_mass = physics.center_of_mass
			local ent = Entity.New({Name = "source_physics_prop_" .. path})
			ent:AddComponent("transform")
			ent.transform:SetPosition(ORIGIN + Vec3(column * SPACING, 1.5 + row * 2, row * SPACING) + center_of_mass)
			ent.transform:SetRotation(Quat():SetAngles(Deg3(0, i * 37, 0)))
			ent:AddComponent(
				"rigid_body",
				{
					Shapes = physics.children,
					Mass = physics.mass,
					Inertia = physics.inertia,
					AutomaticMass = false,
					Friction = surface.friction,
					Restitution = surface.elasticity,
					FrictionCombineMode = "multiply",
					RestitutionCombineMode = "multiply",
					LinearDamping = physics.damping,
					AirLinearDamping = physics.damping,
					AngularDamping = physics.rotation_damping,
					AirAngularDamping = physics.rotation_damping,
				}
			)
			-- the body origin is the center of mass, the model origin is not
			local visual = Entity.New({Name = "source_physics_visual_" .. path})
			visual.PhysicsNoCollision = true
			visual:AddComponent("transform")
			visual.transform:SetPosition(center_of_mass * -1)
			visual:AddComponent("visual")
			visual.visual:SetModelPath(path)
			visual:SetParent(ent)
		end,
		nil,
		function(err)
			logf("failed to load %s: %s\n", path, err)
		end
	)
end
