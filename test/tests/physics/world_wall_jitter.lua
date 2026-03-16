local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local raycast = import("goluwa/physics/raycast.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local sphere_shape = SphereShape.New

local function simulate_physics(steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

local function create_brush_wall_source()
	local ent = Entity.New({Name = "world_wall_source"})
	ent:AddComponent("transform")
	local source = raycast.CreateModelSource{
		{
			Owner = ent,
			Visible = true,
			WorldSpaceVertices = true,
			AABB = AABB(0, -4, -8, 1, 4, 8),
			Primitives = {
				{
					brush_planes = {
						{normal = Vec3(1, 0, 0), dist = 1},
						{normal = Vec3(-1, 0, 0), dist = 0},
						{normal = Vec3(0, 1, 0), dist = 4},
						{normal = Vec3(0, -1, 0), dist = 4},
						{normal = Vec3(0, 0, 1), dist = 8},
						{normal = Vec3(0, 0, -1), dist = 8},
					},
					aabb = AABB(0, -4, -8, 1, 4, 8),
				},
			},
		},
	}
	return ent, source
end

local function create_brush_box_source(mins, maxs)
	local ent = Entity.New({Name = "world_brush_box_source"})
	ent:AddComponent("transform")
	local source = raycast.CreateModelSource{
		{
			Owner = ent,
			Visible = true,
			WorldSpaceVertices = true,
			AABB = AABB(mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z),
			Primitives = {
				{
					brush_planes = {
						{normal = Vec3(1, 0, 0), dist = maxs.x},
						{normal = Vec3(-1, 0, 0), dist = -mins.x},
						{normal = Vec3(0, 1, 0), dist = maxs.y},
						{normal = Vec3(0, -1, 0), dist = -mins.y},
						{normal = Vec3(0, 0, 1), dist = maxs.z},
						{normal = Vec3(0, 0, -1), dist = -mins.z},
					},
					aabb = AABB(mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z),
				},
			},
		},
	}
	return ent, source
end

T.Test3D("Dynamic sphere slides along brush world wall without sticking", function()
	local source_ent, source = create_brush_wall_source()
	physics.SetWorldTraceSource(source)
	local sphere_ent = Entity.New({Name = "world_wall_slide_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(-2, 0, -2))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
			Friction = 0,
			Restitution = 0,
			MaxLinearSpeed = 1000,
		}
	)
	sphere:SetVelocity(Vec3(8, 0, 3))
	simulate_physics(90)
	local start_contact_z = sphere_ent.transform:GetPosition().z
	local min_x = math.huge
	local max_x = -math.huge

	for _ = 1, 90 do
		simulate_physics(1)
		local pos = sphere_ent.transform:GetPosition()
		min_x = math.min(min_x, pos.x)
		max_x = math.max(max_x, pos.x)
	end

	local final_position = sphere_ent.transform:GetPosition()
	local final_velocity = sphere:GetVelocity()
	physics.SetWorldTraceSource(nil)
	sphere_ent:Remove()
	source_ent:Remove()
	T(final_position.z - start_contact_z)[">"](1.2)
	T(final_position.x)["<"](0.05)
	T(final_position.x)[">="](-0.8)
	T(max_x - min_x)["<"](0.2)
	T(math.abs(final_velocity.x))["<"](0.35)
	T(final_velocity.z)[">"](1.0)
end)

T.Test3D("Dynamic sphere dropped above brush top edge does not sink deeply", function()
	local source_ent, source = create_brush_box_source(Vec3(-3, 0, -3), Vec3(3, 1, 3))
	physics.SetWorldTraceSource(source)
	local sphere_ent = Entity.New({Name = "world_brush_edge_drop_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(3.32, 4, 0))
	local radius = 0.5
	sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(radius),
			Radius = radius,
			LinearDamping = 0.02,
			AngularDamping = 0.05,
			Friction = 0.1,
			Restitution = 0,
		}
	)
	local min_edge_distance = math.huge

	for _ = 1, 180 do
		simulate_physics(1)
		local position = sphere_ent.transform:GetPosition()

		if math.abs(position.z) < 0.2 and position.x > 2.6 and position.y < 1.8 then
			local dx = math.max(position.x - 3, 0)
			local dy = position.y - 1
			min_edge_distance = math.min(min_edge_distance, math.sqrt(dx * dx + dy * dy))
		end
	end

	physics.SetWorldTraceSource(nil)
	sphere_ent:Remove()
	source_ent:Remove()
	T(min_edge_distance)[">="](0.48)
end)

T.Test3D("Dynamic sphere hitting brush ceiling corner does not sink deeply", function()
	local source_ent, source = create_brush_box_source(Vec3(-2, 2, -2), Vec3(2, 3, 2))
	physics.SetWorldTraceSource(source)
	local sphere_ent = Entity.New({Name = "world_brush_ceiling_corner_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(2.55, 1.05, 0))
	local radius = 0.5
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(radius),
			Radius = radius,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
			Friction = 0,
			Restitution = 0,
			MaxLinearSpeed = 1000,
		}
	)
	sphere:SetVelocity(Vec3(-3, 3, 0))
	local min_corner_distance = math.huge

	for _ = 1, 120 do
		simulate_physics(1)
		local position = sphere_ent.transform:GetPosition()

		if math.abs(position.z) < 0.2 and position.x < 2.7 and position.y > 1.2 then
			local dx = math.max(position.x - 2, 0)
			local dy = math.max(2 - position.y, 0)
			min_corner_distance = math.min(min_corner_distance, math.sqrt(dx * dx + dy * dy))
		end
	end

	physics.SetWorldTraceSource(nil)
	sphere_ent:Remove()
	source_ent:Remove()
	T(min_corner_distance)[">="](0.48)
end)

T.Test3D("Physgun-style sphere push against brush platform edge does not stick deeply", function()
	local source_ent, source = create_brush_box_source(Vec3(-2, 2, -2), Vec3(2, 3, 2))
	physics.SetWorldTraceSource(source)
	local sphere_ent = Entity.New({Name = "world_brush_physgun_edge_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(2.8, 1.2, 0))
	local radius = 0.5
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(radius),
			Radius = radius,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
			Friction = 0,
			Restitution = 0,
			MaxLinearSpeed = 1000,
		}
	)
	local min_corner_distance = math.huge

	for _ = 1, 120 do
		sphere:SetVelocity(Vec3(-6, 6, 0))
		simulate_physics(1)
		local position = sphere_ent.transform:GetPosition()
		local dx = math.max(position.x - 2, 0)
		local dy = math.max(2 - position.y, 0)
		min_corner_distance = math.min(min_corner_distance, math.sqrt(dx * dx + dy * dy))
	end

	physics.SetWorldTraceSource(nil)
	sphere_ent:Remove()
	source_ent:Remove()
	T(min_corner_distance)[">="](0.48)
end)