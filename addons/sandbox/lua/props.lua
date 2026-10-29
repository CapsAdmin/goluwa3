local prefab = import("goluwa/entities/prefab.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local surface_properties = import("goluwa/source_engine/surface_properties.lua")
Entity.RegisterComponent("source_ragdoll", import("lua/components/source_ragdoll.lua"))
local props = {}
prefab.Register(
		"prop_physics",
		{
			inputs = {
				{
					Name = "Model",
					Type = "string",
					Default = "",
					Targets = {{Node = "visual", Component = "visual", Property = "ModelPath"}},
				},
				{
					Name = "Offset",
					Type = "vec3",
					Default = Vec3(),
					Targets = {{Node = "visual", Component = "transform", Property = "Position"}},
				},
			},
			entities = {
				{guid = "root", components = {}},
				{
					guid = "visual",
					parent = "root",
					properties = {Name = "visual"},
					components = {transform = {}, visual = {}, animator = {Playing = false}},
				},
			},
		}
	).builtin = true
prefab.Register(
		"prop_ragdoll",
		{
			inputs = {
				{
					Name = "Model",
					Type = "string",
					Default = "",
					Targets = {
						{Node = "root", Component = "source_ragdoll", Property = "ModelPath"},
						{Node = "visual", Component = "visual", Property = "ModelPath"},
					},
				},
			},
			entities = {
				{guid = "root", components = {source_ragdoll = {}}},
				{
					guid = "visual",
					parent = "root",
					properties = {Name = "visual"},
					components = {transform = {}, visual = {}, animator = {Playing = false}},
				},
			},
		}
	).builtin = true
local CLEARANCE = 0.02

local function get_lowest(physics, rotation)
	local lowest = math.huge

	for _, child in ipairs(physics.children) do
		for _, vertex in ipairs(child.ConvexHull.vertices) do
			lowest = math.min(lowest, rotation:VecMul(child.Position + vertex).y)
		end
	end

	return lowest
end

function props.Spawn(model_path, position, rotation, on_spawn)
	local done = false

	model_loader.LoadModel(
		model_path,
		function(model)
			if done then return end

			done = true
			local physics = model.physics

			if not physics then
				wlog("%s has no collision data, it cannot be a physics prop", model_path)
				return
			end

			if physics.ragdoll then
				local lowest = math.huge
				local root = physics.ragdoll.solids[1]
				local rest_rotation = root.bone_rotation
				local rest_position = root.bone_position + rest_rotation:VecMul(root.mass_center)

				for _, solid in ipairs(physics.ragdoll.solids) do
					for _, child in ipairs(solid.children) do
						for _, vertex in ipairs(child.ConvexHull.vertices) do
							lowest = math.min(
								lowest,
								rotation:VecMul(solid.bone_position + solid.bone_rotation:VecMul(child.Position + vertex)).y
							)
						end
					end
				end

				local entity = Entity.New{
					Transient = false,
					Name = model_path:match("([^/]+)%.%w+$") or model_path,
					transform = {
						Position = position + Vec3(0, CLEARANCE - lowest, 0) + rotation:VecMul(rest_position),
						Rotation = rotation * rest_rotation,
					},
					network = SERVER and {} or nil,
					prefab = {Path = "prop_ragdoll", Inputs = {Model = model_path}},
				}

				if on_spawn then on_spawn(entity) end

				return
			end

			local surface = surface_properties.Get(physics.surface_property or "default")
			local entity = Entity.New{
				Transient = false,
				Name = model_path:match("([^/]+)%.%w+$") or model_path,
				transform = {
					Position = position + Vec3(0, CLEARANCE - get_lowest(physics, rotation), 0),
					Rotation = rotation,
				},
				network = SERVER and {} or nil,
				rigid_body = {
					ShapeModelPath = model_path,
					MotionType = "dynamic",
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
				},
				prefab = {
					Path = "prop_physics",
					Inputs = {Model = model_path, Offset = physics.center_of_mass * -1},
				},
			}

			if on_spawn then on_spawn(entity) end
		end,
		nil,
		function(err)
			wlog("failed to load %s: %s", model_path, tostring(err))
		end
	)
end

return props
