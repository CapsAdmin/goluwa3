local prefab = import("goluwa/entities/prefab.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
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
local BOX_DENSITY = 150
local MIN_BOX_EXTENT = 0.05

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
				local min, max = model.bounds.min, model.bounds.max
				local size = Vec3(
					math.max(max.x - min.x, MIN_BOX_EXTENT),
					math.max(max.y - min.y, MIN_BOX_EXTENT),
					math.max(max.z - min.z, MIN_BOX_EXTENT)
				)
				local center = (min + max) * 0.5
				local lowest = math.huge

				for _, sign_x in ipairs({-1, 1}) do
					for _, sign_y in ipairs({-1, 1}) do
						for _, sign_z in ipairs({-1, 1}) do
							lowest = math.min(
								lowest,
								rotation:VecMul(center + Vec3(sign_x * size.x, sign_y * size.y, sign_z * size.z) * 0.5).y
							)
						end
					end
				end

				local surface = surface_properties.Get("default")
				local entity = Entity.New{
					Transient = false,
					Name = model_path:match("([^/]+)%.%w+$") or model_path,
					transform = {
						Position = position + Vec3(0, CLEARANCE - lowest, 0) + rotation:VecMul(center),
						Rotation = rotation,
					},
					network = SERVER and {} or nil,
					rigid_body = {
						Shape = BoxShape.New(size),
						MotionType = "dynamic",
						Mass = size.x * size.y * size.z * BOX_DENSITY,
						AutomaticMass = false,
						Friction = surface.friction,
						Restitution = surface.elasticity,
						FrictionCombineMode = "multiply",
						RestitutionCombineMode = "multiply",
					},
					prefab = {Path = "prop_physics", Inputs = {Model = model_path, Offset = center * -1}},
				}

				if on_spawn then on_spawn(entity) end

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
