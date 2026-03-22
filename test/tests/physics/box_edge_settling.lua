local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

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
			Shape = BoxShape.New(size),
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
			Shape = BoxShape.New(size),
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

local function spawn_tilted_capsule(name, position, radius, height, angles, body_config)
	body_config = body_config or {}
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetAngles(angles or Deg3())
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(radius, height),
			Radius = radius,
			Height = height,
			Mass = body_config.Mass or 1,
			AutomaticMass = body_config.AutomaticMass == nil and false or body_config.AutomaticMass,
			LinearDamping = body_config.LinearDamping or 0.05,
			AngularDamping = body_config.AngularDamping or 0.08,
			AirLinearDamping = body_config.AirLinearDamping or 0.01,
			AirAngularDamping = body_config.AirAngularDamping or 0.02,
			Friction = body_config.Friction or 0.45,
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

local function assert_axis_aligned_resting_box(
	ent,
	body,
	size,
	support_top,
	max_face_error,
	min_primary_axis,
	max_secondary_axis
)
	local position = ent.transform:GetPosition()
	local rotation = ent.transform:GetRotation()
	local verticals = get_axis_verticals(rotation)
	local center_offset = position.y - support_top
	local half_sizes = {size.x * 0.5, size.y * 0.5, size.z * 0.5}
	local best_error = math.huge

	for _, half in ipairs(half_sizes) do
		best_error = math.min(best_error, math.abs(center_offset - half))
	end

	T(body:GetGrounded())["=="](true)
	T(verticals.largest)[">"](min_primary_axis or 0.985)
	T(verticals.middle)["<"](max_secondary_axis or 0.18)
	T(best_error)["<"](max_face_error or 0.08)
	T(body:GetVelocity():GetLength())["<"](0.12)
	T(body:GetAngularVelocity():GetLength())["<"](0.18)
	return position:Copy(), verticals, center_offset, best_error
end

T.Test3D("Tilted tall box settles onto a face on a static box platform", function()
	local ground = test_helpers.CreateFlatGround("rigid_box_edge_static_ground", 16)
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
	local ground = test_helpers.CreateFlatGround("rigid_box_edge_dynamic_ground", 20)
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
	T(platform_position.y)["<="](0.66)
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
	local ground = test_helpers.CreateFlatGround("rigid_box_edge_compact_ground", 16)
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
	local ground = test_helpers.CreateFlatGround("rigid_box_edge_beam_ground", 18)
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

T.Test3D("Thin tilted box tips down instead of hanging on a narrow support edge", function()
	local ground = test_helpers.CreateFlatGround("rigid_box_tipassist_ground", 18)
	local platform_ent = spawn_box_platform(
		"rigid_box_tipassist_platform",
		Vec3(0, 1, 0),
		Vec3(24, 1, 24),
		{
			MotionType = "static",
			Friction = 1,
			Restitution = 0,
		}
	)
	local top_ent = Entity.New({Name = "rigid_box_tipassist_top"})
	top_ent:AddComponent("transform")
	top_ent.transform:SetAngles(Deg3(0, 0, 45))
	local top = top_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(10, 0.35, 4)),
			Size = Vec3(10, 0.35, 4),
			Mass = 2,
			AutomaticMass = false,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
			Friction = 0,
			Restitution = 0,
		}
	)
	local support_radius = top:GetPhysicsShape():GetSupportRadiusAlongNormal(top, Vec3(0, 1, 0))
	top_ent.transform:SetPosition(Vec3(0, 1.5 + support_radius, 0))
	simulate_physics(120)
	local mid_angles = top_ent.transform:GetRotation():GetAngles()
	simulate_physics(120)
	local final_angles = top_ent.transform:GetRotation():GetAngles()
	local grounded = top:GetGrounded()
	top_ent:Remove()
	platform_ent:Remove()
	ground:Remove()
	T(grounded)["=="](true)
	T(math.abs(mid_angles.z))["<"](0.5)
	T(math.abs(final_angles.z))["<"](0.12)
end)

T.Test3D("Twenty meter beam resting on one end settles quickly from forty five degrees", function()
	local ground = test_helpers.CreateFlatGround("rigid_box_beam_quick_settle_ground", 48)
	local platform_ent = spawn_box_platform(
		"rigid_box_beam_quick_settle_platform",
		Vec3(0, 0.5, 0),
		Vec3(48, 1, 48),
		{
			MotionType = "static",
			Friction = 1,
			Restitution = 0,
		}
	)
	local beam_ent = Entity.New({Name = "rigid_box_beam_quick_settle_top"})
	beam_ent:AddComponent("transform")
	beam_ent.transform:SetAngles(Deg3(0, 0, 45))
	local beam = beam_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(20, 0.35, 0.35)),
			Size = Vec3(20, 0.35, 0.35),
			Mass = 4,
			AutomaticMass = false,
			CanSleep = false,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
			Friction = 1,
			Restitution = 0,
		}
	)
	local support_radius = beam:GetPhysicsShape():GetSupportRadiusAlongNormal(beam, Vec3(0, 1, 0))
	beam_ent.transform:SetPosition(Vec3(0, 1 + support_radius, 0))
	simulate_physics(30)
	local early_angles = beam_ent.transform:GetRotation():GetAngles()
	local early_angvel = beam:GetAngularVelocity():GetLength()
	simulate_physics(30)
	local half_second_angles = beam_ent.transform:GetRotation():GetAngles()
	local half_second_angvel = beam:GetAngularVelocity():GetLength()
	simulate_physics(60)
	local one_and_half_second_angles = beam_ent.transform:GetRotation():GetAngles()
	local one_and_half_second_angvel = beam:GetAngularVelocity():GetLength()
	simulate_physics(30)
	local two_second_angles = beam_ent.transform:GetRotation():GetAngles()
	local two_second_angvel = beam:GetAngularVelocity():GetLength()
	beam_ent:Remove()
	platform_ent:Remove()
	ground:Remove()
	T(math.abs(early_angles.z))["<"](0.72)
	T(math.abs(half_second_angles.z))["<"](0.5)
	T(math.abs(one_and_half_second_angles.z))["<"](0.25)
	T(one_and_half_second_angvel)[">"](1.5)
	T(math.abs(two_second_angles.z))["<"](0.08)
	T(two_second_angvel)[">"](1.5)
end)

T.Test3D("Long box overhanging a static platform tips instead of hovering flat", function()
	local ground = test_helpers.CreateFlatGround("rigid_box_overhang_ground", 18)
	local platform_ent = spawn_box_platform(
		"rigid_box_overhang_platform",
		Vec3(0, 1, 0),
		Vec3(2.5, 1, 4),
		{
			MotionType = "static",
			Friction = 1,
			Restitution = 0,
		}
	)
	local top_ent = Entity.New({Name = "rigid_box_overhang_top"})
	top_ent:AddComponent("transform")
	top_ent.transform:SetPosition(Vec3(2.35, 3.5, 0))
	local top = top_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(6.5, 0.8, 1.2)),
			Size = Vec3(6.5, 0.8, 1.2),
			Mass = 2.5,
			AutomaticMass = false,
			LinearDamping = 0,
			AngularDamping = 0.02,
			Friction = 0.95,
			Restitution = 0,
		}
	)
	simulate_physics(360)
	local position = top_ent.transform:GetPosition()
	local angles = top_ent.transform:GetRotation():GetAngles()
	local angular_speed = top:GetAngularVelocity():GetLength()
	top_ent:Remove()
	platform_ent:Remove()
	ground:Remove()
	T(position.x)[">"](2.5)
	T(position.y)["<"](2.2)
end)

T.Test3D("Thin rotated clutter box settles flat on a static platform", function()
	local ground = test_helpers.CreateFlatGround("rigid_box_clutter_ground", 18)
	local platform_ent = spawn_box_platform(
		"rigid_box_clutter_platform",
		Vec3(0, 1, 0),
		Vec3(6, 1, 6),
		{
			MotionType = "static",
			Friction = 1,
			Restitution = 0,
		}
	)
	local top_ent, top = spawn_tilted_box(
		"rigid_box_clutter_top",
		Vec3(0, 4.5, 0),
		Vec3(1.8, 0.45, 1.0),
		Deg3(-6, -18, 9),
		{Mass = 1.1, AngularDamping = 0.09, Friction = 0.55}
	)
	simulate_physics(1200)
	local settled_position, settled_verticals = assert_settled_on_face(top_ent, top, 1, 0.5, 0.18, 0.34, 0.985, 0.18)
	simulate_physics(600)
	local final_position = top_ent.transform:GetPosition()
	local final_verticals = get_axis_verticals(top_ent.transform:GetRotation())
	local linear_speed = top:GetVelocity():GetLength()
	local angular_speed = top:GetAngularVelocity():GetLength()
	top_ent:Remove()
	platform_ent:Remove()
	ground:Remove()
	T((final_position - settled_position):GetLength())["<"](0.05)
	T(final_verticals.largest)[">="](settled_verticals.largest - 0.02)
	T(final_verticals.middle)["<"](0.18)
	T(linear_speed)["<"](0.05)
	T(angular_speed)["<"](0.08)
end)

T.Test3D("Rotated clutter boxes settle and sleep on a static platform", function()
	local ground = test_helpers.CreateFlatGround("rigid_box_clutter_group_ground", 24)
	local platform_ent = spawn_box_platform(
		"rigid_box_clutter_group_platform",
		Vec3(0, 1, 0),
		Vec3(12, 1, 10),
		{
			MotionType = "static",
			Friction = 1,
			Restitution = 0,
		}
	)
	local defs = {
		{
			name = "rigid_box_clutter_group_1",
			position = Vec3(-4.0, 4.2, -1.8),
			size = Vec3(0.9, 0.9, 0.9),
			angles = Deg3(8, 20, -6),
			config = {Mass = 1.2, AngularDamping = 0.08, Friction = 0.65},
		},
		{
			name = "rigid_box_clutter_group_2",
			position = Vec3(-1.2, 5.0, -0.6),
			size = Vec3(0.7, 2.0, 0.7),
			angles = Deg3(0, 32, 14),
			config = {Mass = 1.6, AngularDamping = 0.12, Friction = 0.82},
		},
		{
			name = "rigid_box_clutter_group_3",
			position = Vec3(1.6, 4.4, 0.7),
			size = Vec3(1.8, 0.45, 1.0),
			angles = Deg3(-6, -18, 9),
			config = {Mass = 1.1, AngularDamping = 0.09, Friction = 0.55},
		},
		{
			name = "rigid_box_clutter_group_4",
			position = Vec3(4.1, 5.2, -1.0),
			size = Vec3(1.2, 1.4, 0.5),
			angles = Deg3(12, -26, -12),
			config = {Mass = 1.45, AngularDamping = 0.1, Friction = 0.58},
		},
	}
	local spawned = {}

	for _, def in ipairs(defs) do
		local ent, body = spawn_tilted_box(def.name, def.position, def.size, def.angles, def.config)
		spawned[#spawned + 1] = {ent = ent, body = body}
	end

	simulate_physics(1800)

	for _, item in ipairs(spawned) do
		local position = item.ent.transform:GetPosition()
		T(item.body:GetGrounded())["=="](true)
		T(position.y)[">="](1.18)
		T(item.body:GetVelocity():GetLength())["<"](0.08)
		T(item.body:GetAngularVelocity():GetLength())["<"](0.12)
	end

	simulate_physics(600)

	for _, item in ipairs(spawned) do
		T(item.body:GetAwake())["=="](false)
		item.ent:Remove()
	end

	platform_ent:Remove()
	ground:Remove()
end)

T.Test3D("Mixed clutter lets the loose boxes settle cleanly", function()
	local ground = test_helpers.CreateFlatGround("rigid_box_mixed_clutter_ground", 40)
	local floor_ent = spawn_box_platform(
		"rigid_box_mixed_clutter_floor",
		Vec3(0, -2.5, 0),
		Vec3(30, 1.5, 16),
		{
			MotionType = "static",
			Friction = 0.85,
			Restitution = 0,
		}
	)
	local box_defs = {
		{
			name = "rigid_box_mixed_clutter_box_1",
			position = Vec3(9.7, 0.1, 4.8),
			size = Vec3(0.9, 0.9, 0.9),
			angles = Deg3(8, 20, -6),
			config = {Mass = 1.2, AngularDamping = 0.08, Friction = 0.65},
		},
		{
			name = "rigid_box_mixed_clutter_box_2",
			position = Vec3(11.7, 1.1, 5.7),
			size = Vec3(0.7, 2.0, 0.7),
			angles = Deg3(0, 32, 14),
			config = {Mass = 1.6, AngularDamping = 0.12, Friction = 0.82},
		},
		{
			name = "rigid_box_mixed_clutter_box_3",
			position = Vec3(13.3, -0.2, 6.8),
			size = Vec3(1.8, 0.45, 1.0),
			angles = Deg3(-6, -18, 9),
			config = {Mass = 1.1, AngularDamping = 0.09, Friction = 0.55},
		},
		{
			name = "rigid_box_mixed_clutter_box_4",
			position = Vec3(14.6, 1.6, 5.0),
			size = Vec3(1.2, 1.4, 0.5),
			angles = Deg3(12, -26, -12),
			config = {Mass = 1.45, AngularDamping = 0.1, Friction = 0.58},
		},
	}
	local capsule_defs = {
		{
			name = "rigid_box_mixed_clutter_capsule_1",
			position = Vec3(8.7, 1.8, 7.6),
			radius = 0.38,
			height = 1.8,
			angles = Deg3(18, 14, 24),
			config = {Mass = 1.0, AngularDamping = 0.08, Friction = 0.42},
		},
		{
			name = "rigid_box_mixed_clutter_capsule_2",
			position = Vec3(10.9, 2.7, 7.0),
			radius = 0.28,
			height = 2.4,
			angles = Deg3(-10, -22, 34),
			config = {Mass = 1.15, AngularDamping = 0.06, Friction = 0.35},
		},
		{
			name = "rigid_box_mixed_clutter_capsule_3",
			position = Vec3(12.9, 1.0, 7.9),
			radius = 0.46,
			height = 1.6,
			angles = Deg3(6, 40, -18),
			config = {Mass = 1.5, AngularDamping = 0.09, Friction = 0.5},
		},
		{
			name = "rigid_box_mixed_clutter_capsule_4",
			position = Vec3(14.9, 2.4, 7.4),
			radius = 0.32,
			height = 2.8,
			angles = Deg3(24, -12, 16),
			config = {Mass = 1.25, AngularDamping = 0.07, Friction = 0.38},
		},
	}
	local boxes = {}
	local capsules = {}

	for _, def in ipairs(box_defs) do
		local ent, body = spawn_tilted_box(def.name, def.position, def.size, def.angles, def.config)
		boxes[#boxes + 1] = {ent = ent, body = body}
	end

	for _, def in ipairs(capsule_defs) do
		local ent, body = spawn_tilted_capsule(def.name, def.position, def.radius, def.height, def.angles, def.config)
		capsules[#capsules + 1] = {ent = ent, body = body}
	end

	simulate_physics(2400)
	local mixed_metrics = {}

	for _, item in ipairs(boxes) do
		mixed_metrics[#mixed_metrics + 1] = {
			name = item.ent.Name,
			grounded = item.body:GetGrounded(),
			linear = item.body:GetVelocity():GetLength(),
			angular = item.body:GetAngularVelocity():GetLength(),
		}
	end

	simulate_physics(720)

	for i, item in ipairs(boxes) do
		mixed_metrics[i].awake = item.body:GetAwake()
		item.ent:Remove()
	end

	for _, item in ipairs(capsules) do
		item.ent:Remove()
	end

	floor_ent:Remove()
	ground:Remove()

	for _, metric in ipairs(mixed_metrics) do
		T(metric.grounded)["=="](true)
		T(metric.linear)["<"](0.12)
		T(metric.angular)["<"](0.18)
		T(metric.awake)["=="](false)
	end
end)

T.Test3D("Evenly spaced playground boxes settle onto stable upright faces", function()
	local platform_ent = spawn_box_platform(
		"rigid_box_even_playground_platform",
		Vec3(0, -0.75, 0),
		Vec3(20, 1.5, 12),
		{
			MotionType = "static",
			Friction = 0.85,
			Restitution = 0,
		}
	)
	local defs = {
		{
			name = "rigid_box_even_playground_1",
			position = Vec3(-6.0, 2.2, 0),
			size = Vec3(0.9, 0.9, 0.9),
			angles = Deg3(8, 20, -6),
			config = {Mass = 1.2, AngularDamping = 0.08, Friction = 0.65},
			min_primary = 0.983,
			max_secondary = 0.18,
		},
		{
			name = "rigid_box_even_playground_2",
			position = Vec3(-2.0, 2.8, 0),
			size = Vec3(0.7, 2.0, 0.7),
			angles = Deg3(0, 32, 14),
			config = {Mass = 1.6, AngularDamping = 0.12, Friction = 0.82},
			min_primary = 0.983,
			max_secondary = 0.18,
		},
		{
			name = "rigid_box_even_playground_3",
			position = Vec3(2.0, 2.0, 0),
			size = Vec3(1.8, 0.45, 1.0),
			angles = Deg3(-6, -18, 9),
			config = {Mass = 1.1, AngularDamping = 0.09, Friction = 0.55},
			min_primary = 0.983,
			max_secondary = 0.18,
		},
		{
			name = "rigid_box_even_playground_4",
			position = Vec3(6.0, 2.6, 0),
			size = Vec3(1.2, 1.4, 0.5),
			angles = Deg3(12, -26, -12),
			config = {Mass = 1.45, AngularDamping = 0.1, Friction = 0.58},
			min_primary = 0.983,
			max_secondary = 0.18,
		},
	}
	local spawned = {}

	for _, def in ipairs(defs) do
		local ent, body = spawn_tilted_box(def.name, def.position, def.size, def.angles, def.config)
		spawned[#spawned + 1] = {ent = ent, body = body, def = def}
	end

	simulate_physics(1800)
	local even_metrics = {}

	for _, item in ipairs(spawned) do
		local position = item.ent.transform:GetPosition()
		local rotation = item.ent.transform:GetRotation()
		local verticals = get_axis_verticals(rotation)
		local center_offset = position.y
		local half_sizes = {item.def.size.x * 0.5, item.def.size.y * 0.5, item.def.size.z * 0.5}
		local best_error = math.huge

		for _, half in ipairs(half_sizes) do
			best_error = math.min(best_error, math.abs(center_offset - half))
		end

		even_metrics[#even_metrics + 1] = {
			name = item.ent.Name,
			grounded = item.body:GetGrounded(),
			largest = verticals.largest,
			middle = verticals.middle,
			best_error = best_error,
			linear = item.body:GetVelocity():GetLength(),
			angular = item.body:GetAngularVelocity():GetLength(),
			min_primary = item.def.min_primary,
			max_secondary = item.def.max_secondary,
		}
	end

	simulate_physics(900)

	for i, item in ipairs(spawned) do
		even_metrics[i].awake = item.body:GetAwake()
		even_metrics[i].sleep_linear = item.body:GetVelocity():GetLength()
		even_metrics[i].sleep_angular = item.body:GetAngularVelocity():GetLength()
		item.ent:Remove()
	end

	platform_ent:Remove()

	for _, metric in ipairs(even_metrics) do
		T(metric.grounded)["=="](true)
		T(metric.largest)[">"](metric.min_primary)
		T(metric.middle)["<"](metric.max_secondary)
		T(metric.best_error)["<"](0.08)
		T(metric.linear)["<"](0.12)
		T(metric.angular)["<"](0.18)
		T(metric.awake)["=="](false)
		T(metric.sleep_linear)["<"](0.05)
		T(metric.sleep_angular)["<"](0.08)
	end
end)
