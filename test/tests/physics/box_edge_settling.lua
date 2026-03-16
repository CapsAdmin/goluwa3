local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local box_shape = BoxShape.New
local create_flat_ground = test_helpers.CreateFlatGround

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

local function spawn_box_platform(name, position, size, config)
	config = config or {}
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)

	if config.Angles then ent.transform:SetAngles(config.Angles) end

	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(size),
			Size = size,
			MotionType = config.MotionType,
			Mass = config.Mass,
			AutomaticMass = config.AutomaticMass,
			LinearDamping = config.LinearDamping,
			AngularDamping = config.AngularDamping,
			AirLinearDamping = config.AirLinearDamping,
			AirAngularDamping = config.AirAngularDamping,
			GravityScale = config.GravityScale,
			Friction = config.Friction or 1,
			Restitution = config.Restitution or 0,
			SleepDelay = config.SleepDelay,
			SleepLinearThreshold = config.SleepLinearThreshold,
			SleepAngularThreshold = config.SleepAngularThreshold,
		}
	)
	return ent, body
end

local function spawn_tilted_box(name, position, size, angles, body_config)
	size = size or Vec3(0.9, 3.2, 0.9)
	angles = angles or Deg3(45, 0, 45)
	body_config = body_config or {}
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetAngles(angles)
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(size),
			Size = size,
			Mass = body_config.Mass or 3,
			AutomaticMass = body_config.AutomaticMass == nil and false or body_config.AutomaticMass,
			LinearDamping = body_config.LinearDamping or 0.05,
			AngularDamping = body_config.AngularDamping or 0.08,
			AirLinearDamping = body_config.AirLinearDamping or 0.01,
			AirAngularDamping = body_config.AirAngularDamping or 0.02,
			Friction = body_config.Friction or 0.95,
			Restitution = body_config.Restitution or 0,
			MaxLinearSpeed = body_config.MaxLinearSpeed or 1000,
			MaxAngularSpeed = body_config.MaxAngularSpeed or 1000,
		}
	)
	return ent, body
end

local function get_axis_verticals(rotation)
	local right_y = math.abs(rotation:GetRight().y)
	local up_y = math.abs(rotation:GetUp().y)
	local forward_y = math.abs(rotation:GetForward().y)
	local values = {right_y, up_y, forward_y}
	table.sort(values)
	return {
		right = right_y,
		up = up_y,
		forward = forward_y,
		largest = values[3],
		middle = values[2],
		smallest = values[1],
	}
end

local function assert_settled_on_face(
	ent,
	body,
	support_center_y,
	support_half_height,
	min_offset,
	max_offset,
	min_primary_axis,
	max_secondary_axis
)
	local position = ent.transform:GetPosition()
	local rotation = ent.transform:GetRotation()
	local verticals = get_axis_verticals(rotation)
	local support_top = support_center_y + support_half_height
	local center_offset = position.y - support_top
	T(body:GetGrounded())["=="](true)
	T(center_offset)[">="](min_offset)
	T(center_offset)["<="](max_offset)
	T(verticals.largest)[">"](min_primary_axis or 0.85)
	T(verticals.middle)["<"](max_secondary_axis or 0.45)
	T(body:GetVelocity():GetLength())["<"](0.12)
	T(body:GetAngularVelocity():GetLength())["<"](0.2)
	return position:Copy(), verticals, center_offset
end

T.Test3D("Tilted tall box settles onto a face on a static box platform", function()
	local ground = create_flat_ground("rigid_box_edge_static_ground", 16)
	local platform_ent = spawn_box_platform(
		"rigid_box_edge_static_platform",
		Vec3(0, 1, 0),
		Vec3(6, 1, 6),
		{
			MotionType = "static",
			Friction = 1,
			Restitution = 0,
		}
	)
	local top_ent, top = spawn_tilted_box("rigid_box_edge_static_top", Vec3(0, 6, 0))
	simulate_physics(720)
	local settled_position, settled_verticals = assert_settled_on_face(top_ent, top, 1, 0.5, 0.3, 0.7)
	simulate_physics(480)
	local final_position = top_ent.transform:GetPosition()
	local final_verticals = get_axis_verticals(top_ent.transform:GetRotation())
	local drift = (final_position - settled_position):GetLength()
	T(final_verticals.largest)[">="](settled_verticals.largest - 0.03)
	T(final_verticals.middle)["<"](settled_verticals.middle + 0.03)
	T(drift)["<"](0.06)
	top_ent:Remove()
	platform_ent:Remove()
	ground:Remove()
end)

T.Test3D("Tilted tall box settles onto a face on a dynamic box platform", function()
	local ground = create_flat_ground("rigid_box_edge_dynamic_ground", 20)
	local platform_ent, platform = spawn_box_platform(
		"rigid_box_edge_dynamic_platform",
		Vec3(0, 4, 0),
		Vec3(8, 1, 8),
		{
			Mass = 90,
			AutomaticMass = false,
			LinearDamping = 0.35,
			AngularDamping = 0.5,
			AirLinearDamping = 0.02,
			AirAngularDamping = 0.04,
			Friction = 1,
			Restitution = 0,
			SleepDelay = 0.35,
			SleepLinearThreshold = 0.03,
			SleepAngularThreshold = 0.03,
		}
	)
	simulate_physics(480)
	local platform_position = platform_ent.transform:GetPosition():Copy()
	T(platform:GetGrounded())["=="](true)
	T(platform_position.y)[">="](0.45)
	T(platform_position.y)["<="](0.65)
	T(platform:GetVelocity():GetLength())["<"](0.08)
	T(platform:GetAngularVelocity():GetLength())["<"](0.08)
	local top_ent, top = spawn_tilted_box("rigid_box_edge_dynamic_top", platform_position + Vec3(0, 5.5, 0))
	simulate_physics(960)
	local settled_platform_position = platform_ent.transform:GetPosition():Copy()
	local settled_position, settled_verticals = assert_settled_on_face(top_ent, top, settled_platform_position.y, 0.5, 0.3, 0.7)
	simulate_physics(480)
	local final_position = top_ent.transform:GetPosition()
	local final_verticals = get_axis_verticals(top_ent.transform:GetRotation())
	local top_drift = (final_position - settled_position):GetLength()
	local platform_drift = (platform_ent.transform:GetPosition() - settled_platform_position):GetLength()
	T(final_verticals.largest)[">="](settled_verticals.largest - 0.04)
	T(final_verticals.middle)["<"](settled_verticals.middle + 0.04)
	T(top_drift)["<"](0.08)
	T(platform_drift)["<"](0.03)
	top_ent:Remove()
	platform_ent:Remove()
	ground:Remove()
end)

T.Test3D("Compact rotated box settles flat instead of balancing on an edge", function()
	local ground = create_flat_ground("rigid_box_edge_compact_ground", 16)
	local platform_ent = spawn_box_platform(
		"rigid_box_edge_compact_platform",
		Vec3(0, 1, 0),
		Vec3(6, 1, 6),
		{
			MotionType = "static",
			Friction = 1,
			Restitution = 0,
		}
	)
	local top_ent, top = spawn_tilted_box(
		"rigid_box_edge_compact_top",
		Vec3(0, 5.5, 0),
		Vec3(1.2, 1.2, 1.2),
		Deg3(45, 0, 45),
		{Mass = 1.8, AngularDamping = 0.1}
	)
	simulate_physics(960)
	local settled_position, settled_verticals = assert_settled_on_face(top_ent, top, 1, 0.5, 0.45, 0.72, 0.985, 0.18)
	simulate_physics(480)
	local final_position = top_ent.transform:GetPosition()
	local final_verticals = get_axis_verticals(top_ent.transform:GetRotation())
	top_ent:Remove()
	platform_ent:Remove()
	ground:Remove()
	T((final_position - settled_position):GetLength())["<"](0.05)
	T(final_verticals.largest)[">"](0.985)
	T(final_verticals.middle)["<"](0.18)
end)

T.Test3D("Elongated box settles flat instead of leaving one long edge loaded", function()
	local ground = create_flat_ground("rigid_box_edge_beam_ground", 18)
	local platform_ent = spawn_box_platform(
		"rigid_box_edge_beam_platform",
		Vec3(0, 1, 0),
		Vec3(7, 1, 7),
		{
			MotionType = "static",
			Friction = 1,
			Restitution = 0,
		}
	)
	local top_ent, top = spawn_tilted_box(
		"rigid_box_edge_beam_top",
		Vec3(0, 6, 0),
		Vec3(3.8, 0.9, 0.9),
		Deg3(18, 0, 45),
		{Mass = 2.2, AngularDamping = 0.1}
	)
	simulate_physics(1200)
	local settled_position, settled_verticals = assert_settled_on_face(top_ent, top, 1, 0.5, 0.3, 0.58, 0.992, 0.12)
	simulate_physics(600)
	local final_position = top_ent.transform:GetPosition()
	local final_verticals = get_axis_verticals(top_ent.transform:GetRotation())
	top_ent:Remove()
	platform_ent:Remove()
	ground:Remove()
	T((final_position - settled_position):GetLength())["<"](0.06)
	T(final_verticals.largest)[">"](0.992)
	T(final_verticals.middle)["<"](0.12)
end)