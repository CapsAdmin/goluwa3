local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local physics = import("goluwa/physics.lua")
local DistanceConstraint = import("goluwa/physics/constraint.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local sphere_shape = SphereShape.New
local box_shape = BoxShape.New
local capsule_shape = CapsuleShape.New
local ORIGIN = Vec3(34, -1.5, -8)

local function solid_texture(r, g, b, a)
	local tex = Texture.New{
		width = 4,
		height = 4,
		format = "r8g8b8a8_unorm",
		mip_map_levels = "auto",
		image = {
			usage = {"storage", "sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "repeat",
			wrap_t = "repeat",
		},
	}
	tex:Shade(string.format("return vec4(%f, %f, %f, %f);", r, g, b, a or 1))
	return tex
end

local function make_material(color, roughness, metallic)
	local mat = Material.New()
	mat:SetAlbedoTexture(solid_texture(color.r, color.g, color.b, color.a or 1))
	mat:SetRoughnessTexture(solid_texture(roughness or 0.65, roughness or 0.65, roughness or 0.65, 1))
	mat:SetMetallicTexture(solid_texture(metallic or 0, metallic or 0, metallic or 0, 1))
	return mat
end

local function make_rotation(pitch, yaw, roll)
	return Quat():SetAngles(Deg3(pitch or 0, yaw or 0, roll or 0))
end

local function add_cube_model(ent, size, material)
	ent.transform:SetScale(size)
	ent:AddComponent("model")
	local poly = Polygon3D.New()
	poly:CreateCube(0.5)
	poly:Upload()
	ent.model:AddPrimitive(poly, material)
	ent.model:BuildAABB()
	return ent
end

local function add_sphere_model(ent, radius, material)
	ent:AddComponent("model")
	local poly = Polygon3D.New()
	poly:CreateSphere(radius)
	poly:Upload()
	ent.model:AddPrimitive(poly, material)
	ent.model:BuildAABB()
	return ent
end

local function add_capsule_model(ent, radius, height, material)
	ent.transform:SetScale(Vec3(radius * 2, math.max(height, radius * 2), radius * 2))
	ent:AddComponent("model")
	local poly = Polygon3D.New()
	poly:CreateSphere(0.5)
	poly:Upload()
	ent.model:AddPrimitive(poly, material)
	ent.model:BuildAABB()
	return ent
end

local function spawn_visual_anchor(position, radius, material)
	local ent = Entity.New({Name = "constraint_anchor_visual"})
	ent.PhysicsNoCollision = true
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	add_sphere_model(ent, radius or 0.18, material)
	return ent
end

local function spawn_static_box(position, size, material, rotation)
	local ent = Entity.New({Name = "constraint_static_box"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetRotation(rotation or make_rotation())
	add_cube_model(ent, size, material)
	ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(size),
			MotionType = "static",
			Friction = 0.85,
			Restitution = 0,
		}
	)
	return ent
end

local function spawn_stairs(base_center, step_count, step_size, material, direction)
	direction = direction or 1

	for i = 1, step_count do
		local size = Vec3(step_size.x, step_size.y * i, step_size.z)
		local center = base_center + Vec3(direction * step_size.x * (i - 0.5), size.y * 0.5, 0)
		spawn_static_box(center, size, material)
	end

	return true
end

local function spawn_dynamic_sphere(position, radius, material, options)
	options = options or {}
	local ent = Entity.New{Name = options.Name or "constraint_dynamic_sphere"}
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	add_sphere_model(ent, radius, material)
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(radius),
			Radius = radius,
			Mass = options.Mass,
			AutomaticMass = options.AutomaticMass,
			LinearDamping = options.LinearDamping or 0.05,
			AngularDamping = options.AngularDamping or 0.1,
			AirLinearDamping = options.AirLinearDamping or 0.02,
			AirAngularDamping = options.AirAngularDamping or 0.05,
			Friction = options.Friction or 0.4,
			Restitution = options.Restitution or 0,
			GravityScale = options.GravityScale,
			MaxLinearSpeed = options.MaxLinearSpeed or 1000,
			MaxAngularSpeed = options.MaxAngularSpeed or 1000,
		}
	)
	return ent, body
end

local function spawn_dynamic_box(position, size, material, rotation, options)
	options = options or {}
	local ent = Entity.New{Name = options.Name or "constraint_dynamic_box"}
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetRotation(rotation or make_rotation())
	add_cube_model(ent, size, material)
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(size),
			Mass = options.Mass,
			AutomaticMass = options.AutomaticMass,
			LinearDamping = options.LinearDamping or 0.05,
			AngularDamping = options.AngularDamping or 0.12,
			AirLinearDamping = options.AirLinearDamping or 0.02,
			AirAngularDamping = options.AirAngularDamping or 0.05,
			Friction = options.Friction or 0.7,
			Restitution = options.Restitution or 0,
			GravityScale = options.GravityScale,
			MaxLinearSpeed = options.MaxLinearSpeed or 1000,
			MaxAngularSpeed = options.MaxAngularSpeed or 1000,
		}
	)
	return ent, body
end

local function spawn_dynamic_capsule(position, radius, height, material, rotation, options)
	options = options or {}
	local ent = Entity.New{Name = options.Name or "constraint_dynamic_capsule"}
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetRotation(rotation or make_rotation())
	add_capsule_model(ent, radius, height, material)
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = capsule_shape(radius, height),
			Radius = radius,
			Height = height,
			Mass = options.Mass,
			AutomaticMass = options.AutomaticMass,
			LinearDamping = options.LinearDamping or 0.05,
			AngularDamping = options.AngularDamping or 0.1,
			AirLinearDamping = options.AirLinearDamping or 0.02,
			AirAngularDamping = options.AirAngularDamping or 0.05,
			Friction = options.Friction or 0.45,
			Restitution = options.Restitution or 0,
			GravityScale = options.GravityScale,
			MaxLinearSpeed = options.MaxLinearSpeed or 1000,
			MaxAngularSpeed = options.MaxAngularSpeed or 1000,
		}
	)
	return ent, body
end

local function add_distance_constraint(body0, body1, pos0, pos1, distance, compliance, unilateral)
	return DistanceConstraint.New(body0, body1, pos0, pos1, distance, compliance or 0, unilateral)
end

local ground_material = make_material(Color(0.20, 0.18, 0.16, 1), 0.92, 0)
local steel_material = make_material(Color(0.72, 0.77, 0.84, 1), 0.22, 1)
local rope_material = make_material(Color(0.70, 0.56, 0.30, 1), 0.95, 0)
local payload_material = make_material(Color(0.94, 0.44, 0.20, 1), 0.38, 0)
local accent_material = make_material(Color(0.20, 0.72, 1.00, 1), 0.18, 0.1)
local wood_material = make_material(Color(0.49, 0.31, 0.16, 1), 0.88, 0)
spawn_static_box(ORIGIN + Vec3(0, -1.0, 0), Vec3(30, 1.5, 16), ground_material)
spawn_static_box(ORIGIN + Vec3(-10, 1.4, 0), Vec3(4, 3, 6), ground_material)
spawn_static_box(ORIGIN + Vec3(10, 1.4, 0), Vec3(4, 3, 6), ground_material)
spawn_static_box(ORIGIN + Vec3(0, 7.0, -5), Vec3(12, 0.75, 2.5), ground_material)
spawn_stairs(ORIGIN + Vec3(-15.0, -1.75, 0), 5, Vec3(1.0, 0.63, 4.0), ground_material, 1)
spawn_stairs(ORIGIN + Vec3(15.0, -1.75, 0), 5, Vec3(1.0, 0.63, 4.0), ground_material, -1)

-- Pendulum with a world anchor.
do
	local anchor = ORIGIN + Vec3(-11, 7.5, -3)
	spawn_visual_anchor(anchor, 0.22, steel_material)
	local _, bob = spawn_dynamic_sphere(
		anchor + Vec3(3.2, -4.5, 0),
		0.65,
		payload_material,
		{
			Mass = 3,
			AutomaticMass = false,
			LinearDamping = 0.01,
			AngularDamping = 0.03,
			Friction = 0.35,
		}
	)
	add_distance_constraint(nil, bob, anchor, bob:GetPosition(), 5.6, 0, false)
	bob:SetVelocity(Vec3(0, 0, 7))
end

-- Plank bridge suspended between the two support boxes.
do
	local bridge_y = ORIGIN.y + 3.15
	local left_post_top = Vec3(ORIGIN.x - 8.15, bridge_y, ORIGIN.z)
	local right_post_top = Vec3(ORIGIN.x + 8.15, bridge_y, ORIGIN.z)
	spawn_visual_anchor(left_post_top, 0.2, steel_material)
	spawn_visual_anchor(right_post_top, 0.2, steel_material)
	local planks = {}
	local plank_count = 9
	local plank_size = Vec3(1.45, 0.22, 2.1)

	for i = 1, plank_count do
		local t = (i - 1) / (plank_count - 1)
		local x = left_post_top.x + (right_post_top.x - left_post_top.x) * t
		local sag = math.sin(t * math.pi) * 0.65
		local z_tilt = (t - 0.5) * 0.25
		local position = Vec3(x, left_post_top.y - 0.35 - sag, ORIGIN.z + z_tilt)
		local rotation = make_rotation(0, 0, (t - 0.5) * 4)
		local _, body = spawn_dynamic_box(
			position,
			plank_size,
			wood_material,
			rotation,
			{
				Mass = 1.35,
				AutomaticMass = false,
				LinearDamping = 0.08,
				AngularDamping = 0.12,
				Friction = 0.95,
			}
		)
		planks[#planks + 1] = body
	end

	local first = planks[1]
	local last = planks[#planks]
	add_distance_constraint(nil, first, left_post_top, first:GetPosition() + Vec3(-0.7, 0, 0), 0.35, 0, false)
	add_distance_constraint(
		nil,
		first,
		left_post_top + Vec3(0, 0, 1.4),
		first:GetPosition() + Vec3(-0.7, 0, 1.0),
		0.75,
		0,
		false
	)
	add_distance_constraint(nil, last, right_post_top, last:GetPosition() + Vec3(0.7, 0, 0), 0.35, 0, false)
	add_distance_constraint(
		nil,
		last,
		right_post_top + Vec3(0, 0, 1.4),
		last:GetPosition() + Vec3(0.7, 0, 1.0),
		0.75,
		0,
		false
	)

	for i = 1, #planks - 1 do
		local body0 = planks[i]
		local body1 = planks[i + 1]
		add_distance_constraint(
			body0,
			body1,
			body0:GetPosition() + Vec3(0.72, 0, 0),
			body1:GetPosition() + Vec3(-0.72, 0, 0),
			0.34,
			0,
			false
		)
		add_distance_constraint(
			body0,
			body1,
			body0:GetPosition() + Vec3(0.72, 0, 0.85),
			body1:GetPosition() + Vec3(-0.72, 0, 0.85),
			0.34,
			0,
			false
		)
		add_distance_constraint(
			body0,
			body1,
			body0:GetPosition() + Vec3(0.72, 0, -0.85),
			body1:GetPosition() + Vec3(-0.72, 0, -0.85),
			0.34,
			0,
			false
		)
	end
end

-- A simple house with a floor-aligned hinged door.
do
	local house_center = ORIGIN + Vec3(0, 0.25, -10.5)
	spawn_static_box(house_center + Vec3(0, -0.75, 0), Vec3(8.0, 1.5, 7.0), ground_material)
	spawn_static_box(house_center + Vec3(0, 2.2, -3.35), Vec3(8.0, 4.4, 0.3), wood_material)
	spawn_static_box(house_center + Vec3(-3.85, 2.2, 0), Vec3(0.3, 4.4, 7.0), wood_material)
	spawn_static_box(house_center + Vec3(3.85, 2.2, 0), Vec3(0.3, 4.4, 7.0), wood_material)
	spawn_static_box(house_center + Vec3(-2.2, 2.2, 3.35), Vec3(3.3, 4.4, 0.3), wood_material)
	spawn_static_box(house_center + Vec3(2.35, 2.2, 3.35), Vec3(2.7, 4.4, 0.3), wood_material)
	spawn_static_box(house_center + Vec3(0, 4.55, 0), Vec3(8.4, 0.3, 7.4), steel_material)
	local hinge_top = house_center + Vec3(0.9, 2.2, 3.2)
	local hinge_bottom = house_center + Vec3(0.9, 0.0, 3.2)
	spawn_visual_anchor(hinge_top, 0.12, steel_material)
	spawn_visual_anchor(hinge_bottom, 0.12, steel_material)
	local door_rotation = make_rotation(0, -8, 0)
	local _, door = spawn_dynamic_box(
		house_center + Vec3(1.95, 1.1, 3.2),
		Vec3(2.1, 2.2, 0.22),
		wood_material,
		door_rotation,
		{
			Mass = 10,
			AutomaticMass = false,
			LinearDamping = 0.02,
			AngularDamping = 0.025,
			Friction = 0.7,
		}
	)
	add_distance_constraint(nil, door, hinge_top, door:GetPosition() + Vec3(-1.05, 1.1, 0), 0, 0, false)
	add_distance_constraint(nil, door, hinge_bottom, door:GetPosition() + Vec3(-1.05, -1.1, 0), 0, 0, false)
	door:SetVelocity(Vec3(0, 0, 2))
	door:SetAngularVelocity(Vec3(0, 0.2, 0))
end

-- Linked movers so impulses propagate through the constraint.
do
	local _, left = spawn_dynamic_sphere(
		ORIGIN + Vec3(-5, 2.2, 5),
		0.55,
		accent_material,
		{
			Mass = 1.25,
			AutomaticMass = false,
			LinearDamping = 0.02,
			AngularDamping = 0.04,
			Friction = 0.45,
		}
	)
	local _, right = spawn_dynamic_sphere(
		ORIGIN + Vec3(-1.8, 2.2, 5),
		0.55,
		payload_material,
		{
			Mass = 1.25,
			AutomaticMass = false,
			LinearDamping = 0.02,
			AngularDamping = 0.04,
			Friction = 0.45,
		}
	)
	add_distance_constraint(left, right, left:GetPosition(), right:GetPosition(), 3.2, 0, false)
	left:SetVelocity(Vec3(12, 0, 0))
end

-- Unconstrained clutter of different boxes and capsules to knock around.
do
	local clutter_origin = ORIGIN + Vec3(11.5, 0.2, 6.0)
	local loose_boxes = {
		{
			position = clutter_origin + Vec3(-1.8, 1.4, -1.2),
			size = Vec3(0.9, 0.9, 0.9),
			rotation = make_rotation(8, 20, -6),
			material = steel_material,
			options = {Mass = 1.2, AutomaticMass = false, Friction = 0.65, AngularDamping = 0.08},
		},
		{
			position = clutter_origin + Vec3(0.2, 2.4, -0.3),
			size = Vec3(0.7, 2.0, 0.7),
			rotation = make_rotation(0, 32, 14),
			material = wood_material,
			options = {Mass = 1.6, AutomaticMass = false, Friction = 0.82, AngularDamping = 0.12},
		},
		{
			position = clutter_origin + Vec3(1.8, 1.1, 0.8),
			size = Vec3(1.8, 0.45, 1.0),
			rotation = make_rotation(-6, -18, 9),
			material = accent_material,
			options = {Mass = 1.1, AutomaticMass = false, Friction = 0.55, AngularDamping = 0.09},
		},
		{
			position = clutter_origin + Vec3(3.1, 2.9, -1.0),
			size = Vec3(1.2, 1.4, 0.5),
			rotation = make_rotation(12, -26, -12),
			material = payload_material,
			options = {Mass = 1.45, AutomaticMass = false, Friction = 0.58, AngularDamping = 0.1},
		},
	}
	local loose_capsules = {
		{
			position = clutter_origin + Vec3(-2.8, 3.1, 1.6),
			radius = 0.38,
			height = 1.8,
			rotation = make_rotation(18, 14, 24),
			material = rope_material,
			options = {Mass = 1.0, AutomaticMass = false, Friction = 0.42, AngularDamping = 0.08},
		},
		{
			position = clutter_origin + Vec3(-0.6, 4.0, 1.0),
			radius = 0.28,
			height = 2.4,
			rotation = make_rotation(-10, -22, 34),
			material = steel_material,
			options = {Mass = 1.15, AutomaticMass = false, Friction = 0.35, AngularDamping = 0.06},
		},
		{
			position = clutter_origin + Vec3(1.4, 2.3, 1.9),
			radius = 0.46,
			height = 1.6,
			rotation = make_rotation(6, 40, -18),
			material = payload_material,
			options = {Mass = 1.5, AutomaticMass = false, Friction = 0.5, AngularDamping = 0.09},
		},
		{
			position = clutter_origin + Vec3(3.4, 3.7, 1.4),
			radius = 0.32,
			height = 2.8,
			rotation = make_rotation(24, -12, 16),
			material = accent_material,
			options = {Mass = 1.25, AutomaticMass = false, Friction = 0.38, AngularDamping = 0.07},
		},
	}

	for _, def in ipairs(loose_boxes) do
		spawn_dynamic_box(def.position, def.size, def.material, def.rotation, def.options)
	end

	for _, def in ipairs(loose_capsules) do
		spawn_dynamic_capsule(
			def.position,
			def.radius,
			def.height,
			def.material,
			def.rotation,
			def.options
		)
	end
end
