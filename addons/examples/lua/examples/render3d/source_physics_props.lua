-- Source engine props colliding using the hulls and mass from their .phy files.
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Entity = import("goluwa/entities/entity.lua")
local steam = import("goluwa/steam/steam.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local shapes = import("lua/shapes.lua")
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
	RigidBody = {MotionType = "static", Friction = 0.9},
}

for i, path in ipairs(models) do
	model_loader.LoadModel(
		path,
		function(data)
			local row = math.floor((i - 1) / PER_ROW)
			local column = (i - 1) % PER_ROW - (PER_ROW - 1) / 2
			local ent = Entity.New({Name = "source_physics_prop_" .. path})
			ent:AddComponent("transform")
			ent.transform:SetPosition(ORIGIN + Vec3(column * SPACING, 1.5 + row * 2, row * SPACING))
			ent.transform:SetRotation(Quat():SetAngles(Deg3(0, i * 37, 0)))
			ent:AddComponent("visual")
			ent.visual:SetModelPath(path)
			ent:AddComponent(
				"rigid_body",
				{
					Shapes = data.physics.children,
					Mass = data.physics.mass,
					AutomaticMass = false,
					Friction = 0.7,
					Restitution = 0,
					LinearDamping = 0.05,
					AngularDamping = 0.1,
				}
			)
		end,
		nil,
		function(err)
			logf("failed to load %s: %s\n", path, err)
		end
	)
end
