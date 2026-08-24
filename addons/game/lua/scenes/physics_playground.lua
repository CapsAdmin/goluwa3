-- Physics engine feature showcase: a walled arena, one labeled zone per
-- feature. Keys: R kick pendulums, B kick bounce ball, K wake sleeper,
-- S re-fire CCD bullets, C topple capsule.
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local system = import("goluwa/system.lua")
local physics = import("goluwa/physics.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local assets = import("goluwa/assets.lua")

local function example_material(name)
	return assets.Load("materials/examples/" .. name .. ".lua")
end

local DistanceConstraint = import("goluwa/physics/constraint.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local shapes = import("lua/shapes.lua")
local ORIGIN = Vec3(-34, -1.5, -8)
local GROUND = ORIGIN

local function make_rotation(pitch, yaw, roll)
	return Quat():SetAngles(Deg3(pitch or 0, yaw or 0, roll or 0))
end

local function spawn_static_box(position, size, material, rotation, options)
	options = options or {}
	return shapes.Box{
		Name = "physics_playground_static_box",
		Position = position,
		Rotation = rotation or make_rotation(),
		Size = size,
		Material = material,
		RigidBody = {
			MotionType = "static",
			CollisionGroup = options.CollisionGroup,
			Friction = options.Friction or 0.85,
			Restitution = options.Restitution or 0,
		},
	}
end

local function spawn_anchor(position, radius, material)
	return shapes.Sphere{
		Name = "physics_playground_anchor",
		Position = position,
		Radius = radius or 0.18,
		Material = material,
		Collision = false,
		PhysicsNoCollision = true,
	}
end

local function spawn_dynamic_sphere(position, radius, material, options)
	options = options or {}
	return shapes.Sphere{
		Name = options.Name or "physics_playground_dynamic_sphere",
		Position = position,
		Radius = radius,
		Material = material,
		RigidBody = {
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
			CanSleep = options.CanSleep,
			CollisionGroup = options.CollisionGroup,
			CollisionMask = options.CollisionMask,
			CCD = options.CCD,
			AutoCCD = options.AutoCCD,
			MaxLinearSpeed = options.MaxLinearSpeed or 1000,
			MaxAngularSpeed = options.MaxAngularSpeed or 1000,
		},
	}
end

local function spawn_dynamic_box(position, size, material, rotation, options)
	options = options or {}
	return shapes.Box{
		Name = options.Name or "physics_playground_dynamic_box",
		Position = position,
		Rotation = rotation or make_rotation(),
		Size = size,
		Material = material,
		RigidBody = {
			Mass = options.Mass,
			AutomaticMass = options.AutomaticMass,
			LinearDamping = options.LinearDamping or 0.05,
			AngularDamping = options.AngularDamping or 0.12,
			AirLinearDamping = options.AirLinearDamping or 0.02,
			AirAngularDamping = options.AirAngularDamping or 0.05,
			Friction = options.Friction or 0.7,
			Restitution = options.Restitution or 0,
			GravityScale = options.GravityScale,
			CanSleep = options.CanSleep,
			CollisionGroup = options.CollisionGroup,
			CollisionMask = options.CollisionMask,
			MaxLinearSpeed = options.MaxLinearSpeed or 1000,
			MaxAngularSpeed = options.MaxAngularSpeed or 1000,
		},
	}
end

local function spawn_dynamic_capsule(position, radius, height, material, rotation, options)
	options = options or {}
	return shapes.Capsule{
		Name = options.Name or "physics_playground_dynamic_capsule",
		Position = position,
		Rotation = rotation or make_rotation(),
		Radius = radius,
		Height = height,
		Material = material,
		RigidBody = {
			Mass = options.Mass,
			AutomaticMass = options.AutomaticMass,
			LinearDamping = options.LinearDamping or 0.05,
			AngularDamping = options.AngularDamping or 0.12,
			AirLinearDamping = options.AirLinearDamping or 0.02,
			AirAngularDamping = options.AirAngularDamping or 0.05,
			Friction = options.Friction or 0.7,
			Restitution = options.Restitution or 0,
			GravityScale = options.GravityScale,
			CanSleep = options.CanSleep,
			CollisionGroup = options.CollisionGroup,
			CollisionMask = options.CollisionMask,
			MaxLinearSpeed = options.MaxLinearSpeed or 1000,
			MaxAngularSpeed = options.MaxAngularSpeed or 1000,
		},
	}
end

local function label(id, position, title, lines, title_color)
	local all_lines = {title}

	for i = 1, #lines do
		all_lines[#all_lines + 1] = lines[i]
	end

	debug_draw.DrawText{
		id = "physics_playground_" .. id,
		position = position,
		lines = all_lines,
		time = 1,
		padding = 7,
		line_gap = 2,
		background_alpha = 0.66,
		title_color = title_color,
		text_color = Color(0.9, 0.9, 0.94, 1),
	}
end

local prev_keys = {}

local function key_pressed(key)
	local down = input.IsKeyDown(key)
	local was = prev_keys[key]
	prev_keys[key] = down
	return down and not was
end

local floor_material = example_material("concrete")
local wall_material = example_material("rock")
local ground_material = example_material("gravel")
local steel_material = example_material("galvanized_steel")
local rope_material = example_material("leather")
local payload_material = shapes.Material{Color = Color(0.94, 0.44, 0.2, 1), Roughness = 0.38, Metallic = 0}
local accent_material = shapes.Material{Color = Color(0.2, 0.72, 1.0, 1), Roughness = 0.18, Metallic = 0.1}
local ice_material = shapes.Material{Color = Color(0.72, 0.9, 0.96, 1), Roughness = 0.06, Metallic = 0.1}
local rubber_material = example_material("black_rubber")
local glass_material = shapes.Material{Color = Color(0.7, 0.82, 0.88, 1), Roughness = 0.12, Metallic = 0.3}
local gem_material = shapes.Material{Color = Color(0.65, 0.45, 0.95, 1), Roughness = 0.15, Metallic = 0.4}
local phase_material = shapes.Material{Color = Color(0.9, 0.4, 0.85, 1), Roughness = 0.3, Metallic = 0}
local wood_material = example_material("wood_oak")
-- Enclosed arena: floor, four walls and a ceiling so nothing leaves the world
spawn_static_box(ORIGIN + Vec3(0, -0.75, 0), Vec3(48, 1.5, 32), floor_material)
spawn_static_box(ORIGIN + Vec3(-22, 5.75, 0), Vec3(2, 13, 28), wall_material)
spawn_static_box(ORIGIN + Vec3(22, 5.75, 0), Vec3(2, 13, 28), wall_material)
spawn_static_box(ORIGIN + Vec3(0, 5.75, -14), Vec3(46, 13, 2), wall_material)
spawn_static_box(ORIGIN + Vec3(0, 5.75, 14), Vec3(46, 13, 2), wall_material)
spawn_static_box(ORIGIN + Vec3(0, 13, 0), Vec3(48, 1.5, 32), wall_material)
local bounce_body
local bounce_collision_count = 0
local bounce_last_kick = 0

do -- restitution + OnCollisionEnter re-kick
	local bounce_ent, body = spawn_dynamic_sphere(
		GROUND + Vec3(-15, 7.5, -7),
		0.6,
		payload_material,
		{
			Name = "physics_playground_bounce_ball",
			Mass = 1.5,
			AutomaticMass = false,
			LinearDamping = 0.01,
			AngularDamping = 0.05,
			Friction = 0.3,
			Restitution = 0.85,
		}
	)
	bounce_body = body

	bounce_ent:AddLocalListener("OnCollisionEnter", function(_, info)
		local other = info.other_body

		if other and other:IsStatic() then
			bounce_collision_count = bounce_collision_count + 1

			if bounce_body:GetVelocity().y < 10 then
				bounce_body:ApplyImpulse(Vec3(0, 1.5 * 11, 0))
			end
		end
	end)
end

local rubber_body
local ice_body
local rubber_spawn_pos = GROUND + Vec3(-15.45, 3.1, 4.5)
local ice_spawn_pos = GROUND + Vec3(-14.5, 3.1, 4.5)

do -- friction: same ramp, rubber friction 1.2 crawls down, ice friction 0.03 races off
	spawn_static_box(
		GROUND + Vec3(-15, 1.9, 7.5),
		Vec3(3, 0.3, 8),
		ground_material,
		make_rotation(12, 0, 0)
	)
	_, rubber_body = spawn_dynamic_sphere(
		rubber_spawn_pos,
		0.45,
		rubber_material,
		{
			Name = "physics_playground_rubber_ball",
			Mass = 0.8,
			AutomaticMass = false,
			Friction = 1.2,
			Restitution = 0.05,
			AngularDamping = 0.3,
		}
	)
	_, ice_body = spawn_dynamic_sphere(
		ice_spawn_pos,
		0.45,
		ice_material,
		{
			Name = "physics_playground_ice_ball",
			Mass = 0.8,
			AutomaticMass = false,
			Friction = 0.03,
			Restitution = 0.1,
		}
	)
end

local rope_constraint
local spring_constraint
local rope_ball
local spring_ball

do -- distance constraints: unilateral rope vs compliant spring
	local rope_anchor = GROUND + Vec3(-10, 11.2, -7)
	local spring_anchor = GROUND + Vec3(-6, 11.2, -7)
	spawn_anchor(rope_anchor, 0.22, steel_material)
	spawn_anchor(spring_anchor, 0.22, steel_material)
	_, rope_ball = spawn_dynamic_sphere(
		rope_anchor + Vec3(0, -6.5, 0),
		0.6,
		accent_material,
		{
			Name = "physics_playground_rope_ball",
			Mass = 2,
			AutomaticMass = false,
			LinearDamping = 0.001,
			AirLinearDamping = 0.001,
			Friction = 0.4,
		}
	)
	rope_constraint = DistanceConstraint.New(nil, rope_ball, rope_anchor, rope_ball:GetPosition(), 6.5, 0, false)
	rope_ball:SetVelocity(Vec3(4.5, 0, 0))
	_, spring_ball = spawn_dynamic_sphere(
		spring_anchor + Vec3(2.2, -3.2, 0),
		0.5,
		payload_material,
		{
			Name = "physics_playground_spring_ball",
			Mass = 1.4,
			AutomaticMass = false,
			LinearDamping = 0.02,
			Friction = 0.4,
		}
	)
	spring_constraint = DistanceConstraint.New(nil, spring_ball, spring_anchor, spring_ball:GetPosition(), 4.2, 0.05, false)
	spring_ball:SetVelocity(Vec3(-2.5, 0, 0))
end

local sleep_body_a
local sleep_body_b
local sleep_body_c

do -- sleep: bodies freeze when at rest; CanSleep=false keeps one alive
	_, sleep_body_a = spawn_dynamic_box(
		GROUND + Vec3(-1.5, 2.6, -7),
		Vec3(0.9, 0.9, 0.9),
		steel_material,
		make_rotation(8, 18, -5),
		{
			Name = "physics_playground_sleep_a",
			Mass = 1.2,
			AutomaticMass = false,
			Friction = 0.7,
			AngularDamping = 0.1,
		}
	)
	_, sleep_body_b = spawn_dynamic_box(
		GROUND + Vec3(0, 4.4, -7),
		Vec3(0.9, 0.9, 0.9),
		accent_material,
		make_rotation(0, 30, 10),
		{
			Name = "physics_playground_sleep_b",
			Mass = 1.2,
			AutomaticMass = false,
			Friction = 0.7,
			AngularDamping = 0.1,
		}
	)
	_, sleep_body_c = spawn_dynamic_box(
		GROUND + Vec3(1.5, 5.8, -7),
		Vec3(0.9, 0.9, 0.9),
		payload_material,
		make_rotation(12, -20, 8),
		{
			Name = "physics_playground_sleep_c",
			Mass = 1.2,
			AutomaticMass = false,
			Friction = 0.7,
			AngularDamping = 0.1,
			CanSleep = false,
		}
	)
end

local pusher

do -- kinematic body: scripted motion that shoves dynamic bodies
	pusher = spawn_static_box(
		GROUND + Vec3(3, 1.0, 0),
		Vec3(2, 2, 2),
		steel_material,
		make_rotation(),
		{Friction = 0.9}
	)
	pusher.rigid_body:SetMotionType("kinematic")

	for i = 1, 3 do
		spawn_dynamic_box(
			GROUND + Vec3(6 + (i - 1) * 1.2, 1.15, 0),
			Vec3(0.8, 0.8, 0.8),
			wood_material,
			make_rotation(0, 15 * i, 0),
			{
				Name = "physics_playground_pushed_box_" .. i,
				Mass = 0.9,
				AutomaticMass = false,
				Friction = 0.6,
				AngularDamping = 0.1,
			}
		)
	end
end

local wedge_faces = {
	{Vec3(-3, 0, -1.5), Vec3(3, 0, -1.5), Vec3(-3, 0, 1.5)},
	{Vec3(3, 0, -1.5), Vec3(3, 0, 1.5), Vec3(-3, 0, 1.5)},
	{Vec3(-3, 0, -1.5), Vec3(0, 2.2, -1.5), Vec3(0, 2.2, 1.5)},
	{Vec3(-3, 0, -1.5), Vec3(0, 2.2, 1.5), Vec3(-3, 0, 1.5)},
	{Vec3(3, 0, -1.5), Vec3(0, 2.2, 1.5), Vec3(0, 2.2, -1.5)},
	{Vec3(3, 0, -1.5), Vec3(3, 0, 1.5), Vec3(0, 2.2, 1.5)},
	{Vec3(-3, 0, -1.5), Vec3(3, 0, -1.5), Vec3(0, 2.2, -1.5)},
	{Vec3(-3, 0, 1.5), Vec3(0, 2.2, 1.5), Vec3(3, 0, 1.5)},
}

local function add_facet(poly, a, b, c)
	local normal = (b - a):GetCross(c - a):GetNormalized()
	local center = (a + b + c) * 0.333333

	if normal:Dot(center) < 0 then
		b, c = c, b
		normal = normal * -1
	end

	poly:AddVertex{pos = c, uv = Vec2(0.5, 1), normal = normal}
	poly:AddVertex{pos = b, uv = Vec2(1, 0), normal = normal}
	poly:AddVertex{pos = a, uv = Vec2(0, 0), normal = normal}
	return poly
end

do -- static mesh: triangle BVH contacts
	local wedge_pos = GROUND + Vec3(15, 1.1, -7)
	shapes.Polygon{
		Name = "physics_playground_wedge",
		Position = wedge_pos,
		Rotation = make_rotation(),
		Material = ground_material,
		Polygon = function(poly)
			for _, face in ipairs(wedge_faces) do
				add_facet(poly, face[1], face[2], face[3])
			end

			return poly
		end,
		BuildBoundingBox = true,
		RigidBody = {
			MotionType = "static",
			Friction = 0.6,
			Restitution = 0,
		},
	}
	spawn_dynamic_box(
		wedge_pos + Vec3(-1.6, 2.6, 0),
		Vec3(0.8, 0.8, 0.8),
		steel_material,
		make_rotation(5, 20, 5),
		{
			Name = "physics_playground_wedge_box",
			Mass = 1.1,
			AutomaticMass = false,
			Friction = 0.55,
			AngularDamping = 0.08,
		}
	)
end

local gem_points = {
	Vec3(1.1, 0, 0),
	Vec3(-1.1, 0, 0),
	Vec3(0, 1.1, 0),
	Vec3(0, -1.1, 0),
	Vec3(0, 0, 1.1),
	Vec3(0, 0, -1.1),
}
local gem_hull = convex_hull.BuildFromTriangles(gem_points)
local gem_faces = {
	{1, 3, 5},
	{2, 3, 5},
	{2, 4, 5},
	{1, 4, 5},
	{1, 3, 6},
	{2, 3, 6},
	{2, 4, 6},
	{1, 4, 6},
}

do -- convex hull: GJK/EPA solver on a custom hull
	local gem_pos = GROUND + Vec3(15, 4.5, 7)
	local _, gem_body = shapes.Polygon{
		Name = "physics_playground_gem",
		Position = gem_pos,
		Rotation = make_rotation(20, 30, 10),
		Material = gem_material,
		Polygon = function(poly)
			for _, face in ipairs(gem_faces) do
				add_facet(poly, gem_points[face[1]], gem_points[face[2]], gem_points[face[3]])
			end

			return poly
		end,
		BuildBoundingBox = true,
		CollisionShape = ConvexShape.New(gem_hull),
		RigidBody = {
			Mass = 1.6,
			AutomaticMass = false,
			LinearDamping = 0.05,
			AngularDamping = 0.06,
			Friction = 0.4,
			Restitution = 0.3,
		},
	}
	gem_body:SetAngularVelocity(Vec3(2, 3, 1.5))
end

local rocket
local rocket_body
local spinner_body

do -- per-frame forces: ApplyForce hover + ApplyTorque spin
	rocket, rocket_body = spawn_dynamic_box(
		GROUND + Vec3(0, 3.5, 6),
		Vec3(1.1, 1.1, 1.1),
		steel_material,
		make_rotation(),
		{
			Name = "physics_playground_rocket",
			Mass = 1.6,
			AutomaticMass = false,
			LinearDamping = 0.12,
			AngularDamping = 0.35,
			AirLinearDamping = 0.2,
			Friction = 0.5,
			Restitution = 0.2,
		}
	)
	local spinner_anchor = GROUND + Vec3(6, 7.8, 9)
	spawn_anchor(spinner_anchor, 0.2)
	_, spinner_body = spawn_dynamic_box(
		GROUND + Vec3(6, 4.3, 9),
		Vec3(2.2, 0.55, 0.55),
		accent_material,
		make_rotation(0, 45, 0),
		{
			Name = "physics_playground_spinner",
			Mass = 0.8,
			AutomaticMass = false,
			AngularDamping = 0.5,
			MaxAngularSpeed = 12,
			Friction = 0.5,
			Restitution = 0.1,
		}
	)
	DistanceConstraint.New(nil, spinner_body, spinner_anchor, spinner_body:GetPosition(), 3.5, 0, false)
end

local bullet_a_body
local bullet_b_body
local bullet_a_spawn = GROUND + Vec3(12, 4.75, 1.2)
local bullet_b_spawn = GROUND + Vec3(12, 2.45, -1.2)

do -- CCD: explicit CCD stops at the thin plate, auto CCD off tunnels through
	spawn_static_box(GROUND + Vec3(17.5, 4.75, 0), Vec3(0.25, 8, 8), wall_material)
	_, bullet_a_body = spawn_dynamic_sphere(
		bullet_a_spawn,
		0.25,
		steel_material,
		{
			Name = "physics_playground_bullet_ccd",
			Mass = 0.5,
			AutomaticMass = false,
			LinearDamping = 0,
			Friction = 0.3,
			Restitution = 0.6,
			CCD = true,
			AutoCCD = false,
		}
	)
	_, bullet_b_body = spawn_dynamic_sphere(
		bullet_b_spawn,
		0.25,
		wood_material,
		{
			Name = "physics_playground_bullet_noccd",
			Mass = 0.5,
			AutomaticMass = false,
			LinearDamping = 0,
			Friction = 0.3,
			Restitution = 0.4,
			CCD = false,
			AutoCCD = false,
		}
	)
	bullet_a_body:SetPosition(bullet_a_spawn)
	bullet_a_body:SetVelocity(Vec3(55, 0, 0))
	bullet_b_body:SetPosition(bullet_b_spawn)
	bullet_b_body:SetVelocity(Vec3(55, 0, 0))
end

local phase_body
local phase_spawn = GROUND + Vec3(-3, 5, 10)

do -- collision groups and masks: the ball ignores group 2, falls through the row
	for i = 1, 3 do
		spawn_dynamic_box(
			GROUND + Vec3(-4 + (i - 1), 0.35, 10),
			Vec3(0.7, 0.7, 0.7),
			wood_material,
			make_rotation(),
			{
				Name = "physics_playground_phase_box_" .. i,
				Mass = 0.5,
				AutomaticMass = false,
				Friction = 0.8,
				CollisionGroup = 2,
			}
		)
	end

	_, phase_body = spawn_dynamic_sphere(
		phase_spawn,
		0.5,
		phase_material,
		{
			Name = "physics_playground_phase_ball",
			Mass = 0.8,
			AutomaticMass = false,
			Friction = 0.4,
			Restitution = 0.3,
			CollisionGroup = 1,
			CollisionMask = -3,
		}
	)
end

local capsule_stand
local capsule_log
local capsule_drop
local capsule_stand_spawn = GROUND + Vec3(6, 1.2, 9.2)
local capsule_log_spawn = GROUND + Vec3(3.4, 2.75, 7.3)
local capsule_drop_spawn = GROUND + Vec3(8.5, 4.5, 9.2)

do -- capsules: a standing one topples (C), a log rolls down a ramp, a stubby one bounces
	spawn_static_box(
		GROUND + Vec3(3.4, 1.5, 9.4),
		Vec3(2.2, 0.3, 6.5),
		ground_material,
		make_rotation(14, 0, 0)
	)
	_, capsule_stand = spawn_dynamic_capsule(
		capsule_stand_spawn,
		0.4,
		1.6,
		wood_material,
		make_rotation(),
		{
			Name = "physics_playground_capsule_stand",
			Mass = 1.2,
			AutomaticMass = false,
			Friction = 0.8,
			Restitution = 0.05,
			AngularDamping = 0.05,
		}
	)
	_, capsule_log = spawn_dynamic_capsule(
		capsule_log_spawn,
		0.35,
		1.3,
		steel_material,
		make_rotation(0, 0, 90),
		{
			Name = "physics_playground_capsule_log",
			Mass = 1.0,
			AutomaticMass = false,
			Friction = 0.35,
			Restitution = 0.1,
			AngularDamping = 0.02,
		}
	)
	_, capsule_drop = spawn_dynamic_capsule(
		capsule_drop_spawn,
		0.45,
		0.95,
		payload_material,
		make_rotation(),
		{
			Name = "physics_playground_capsule_drop",
			Mass = 0.9,
			AutomaticMass = false,
			Friction = 0.5,
			Restitution = 0.55,
		}
	)
end

local hover_body

do -- gravity scale: zero gravity + damping drifts inside a cage
	local cage_c = GROUND + Vec3(-2, 0, -2)
	local cage_wall = Vec3(0.15, 4, 4.3)
	spawn_static_box(cage_c + Vec3(-2, 2, 0), cage_wall, glass_material)
	spawn_static_box(cage_c + Vec3(2, 2, 0), cage_wall, glass_material)
	spawn_static_box(cage_c + Vec3(0, 2, -2), Vec3(4.3, 4, 0.15), glass_material)
	spawn_static_box(cage_c + Vec3(0, 2, 2), Vec3(4.3, 4, 0.15), glass_material)
	spawn_static_box(cage_c + Vec3(0, 4, 0), Vec3(4.45, 0.15, 4.45), glass_material)
	_, hover_body = spawn_dynamic_sphere(
		cage_c + Vec3(0, 2.2, 0),
		0.35,
		accent_material,
		{
			Name = "physics_playground_hover_ball",
			Mass = 0.5,
			AutomaticMass = false,
			LinearDamping = 0.1,
			AirLinearDamping = 0.15,
			Friction = 0.3,
			GravityScale = 0,
			CanSleep = false,
		}
	)
	hover_body:SetVelocity(Vec3(2.2, 1.1, -2.4))
end

do -- friction x restitution chart: cols = friction 0..1, rows = restitution 0..1
	local ice = Color(0.72, 0.9, 0.96, 1)
	local rubber = Color(0.36, 0.16, 0.55, 1)
	local bouncy = Color(0.78, 0.93, 0.12, 1)

	for i = 1, 5 do
		local friction = (i - 1) * 0.25
		local base = ice:GetLerped(friction, rubber)

		for j = 1, 5 do
			local restitution = (j - 1) * 0.25
			spawn_dynamic_box(
				GROUND + Vec3(18 + (i - 3) * 0.95, 0.4, 10 + (j - 3) * 0.95),
				Vec3(0.7, 0.7, 0.7),
				shapes.Material{
					Color = base:GetLerped(restitution, bouncy),
					Roughness = math.lerp(friction, 0.06, 0.85) * math.lerp(restitution, 1, 0.45),
					Metallic = 0,
				},
				make_rotation(),
				{
					Name = "physics_playground_grid_" .. friction .. "_" .. restitution,
					Mass = 1,
					AutomaticMass = false,
					Friction = friction,
					Restitution = restitution,
				}
			)
		end
	end
end

local ramp_last_spawn = 0
local bullet_last_fire = 0
local phase_last_spawn = 0
local capsule_last_spawn = 0
local rocket_home = GROUND + Vec3(0, 3.5, 6)

event.AddListener("Update", "physics_playground_update", function(dt)
	local t = system.GetElapsedTime()

	if key_pressed("r") then
		rope_ball:SetVelocity(Vec3(6, 0, 0))
		spring_ball:SetVelocity(Vec3(-5, 0, 0))
	end

	if key_pressed("b") and (bounce_body:GetVelocity().y < 10) then
		bounce_body:ApplyImpulse(Vec3(0, 1.5 * 11, 0))
	end

	if key_pressed("k") then
		sleep_body_b:Wake()
		sleep_body_b:ApplyImpulse(Vec3(1.5, 6, 0))
	end

	if key_pressed("c") then capsule_stand:ApplyImpulse(Vec3(4, 0, 0.5)) end

	if key_pressed("s") then
		bullet_a_body:SetPosition(bullet_a_spawn)
		bullet_a_body:SetVelocity(Vec3(55, 0, 0))
		bullet_b_body:SetPosition(bullet_b_spawn)
		bullet_b_body:SetVelocity(Vec3(55, 0, 0))
	end

	-- kinematic pusher shuttles back and forth, shoving the box row
	local pusher_x = 7 + math.sin(t * 1.6) * 4.5
	pusher.transform:SetPosition(GROUND + Vec3(pusher_x, 1.0, 0))
	-- rocket hovers on applied force with a centering pull, spinner spins on applied torque
	local rocket_pos = rocket_body:GetPosition()
	rocket_body:ApplyForce(
		Vec3(
			(rocket_home.x - rocket_pos.x) * 6 + math.sin(t * 1.3) * 6,
			(rocket_home.y - rocket_pos.y) * 6 + 28 * 1.6 * 1.02,
			(rocket_home.z - rocket_pos.z) * 6 + math.cos(t * 0.9) * 4
		)
	)
	spinner_body:ApplyTorque(Vec3(0, 1.5, 0))

	if t - bounce_last_kick > 3.5 and bounce_body:GetVelocity().y < 4 then
		bounce_last_kick = t
		bounce_body:ApplyImpulse(Vec3(0, 1.5 * 11, 0))
	end

	-- respawn timers keep one-shot demos cycling
	if t - ramp_last_spawn > 7 then
		ramp_last_spawn = t
		rubber_body:SetPosition(rubber_spawn_pos)
		rubber_body:SetVelocity(Vec3(0, 0, 0))
		ice_body:SetPosition(ice_spawn_pos)
		ice_body:SetVelocity(Vec3(0, 0, 0))
	end

	if t - bullet_last_fire > 4 then
		bullet_last_fire = t
		bullet_a_body:SetPosition(bullet_a_spawn)
		bullet_a_body:SetVelocity(Vec3(55, 0, 0))
		bullet_b_body:SetPosition(bullet_b_spawn)
		bullet_b_body:SetVelocity(Vec3(55, 0, 0))
	end

	if t - phase_last_spawn > 4.5 then
		phase_last_spawn = t
		phase_body:SetPosition(phase_spawn)
		phase_body:SetVelocity(Vec3(0, 0, 0))
	end

	if t - capsule_last_spawn > 6 then
		capsule_last_spawn = t
		capsule_stand:SetPosition(capsule_stand_spawn)
		capsule_stand:SetRotation(make_rotation())
		capsule_stand:SetVelocity(Vec3(0, 0, 0))
		capsule_log:SetPosition(capsule_log_spawn)
		capsule_log:SetVelocity(Vec3(0, 0, 0))
		capsule_drop:SetPosition(capsule_drop_spawn)
		capsule_drop:SetVelocity(Vec3(0, 0, 0))
	end

	-- sweeping raycast probe: closest hit below a circling point
	local scan_angle = t * 0.7
	local scan_origin = GROUND + Vec3(math.cos(scan_angle) * 8, 11, math.sin(scan_angle) * 8)
	local scan_hit = physics.RayCast(scan_origin, Vec3(0, -1, 0), 12, nil, nil, {
		IgnoreRigidBodies = false,
	})

	if scan_hit and scan_hit.position then
		debug_draw.DrawLine{
			id = "physics_playground_scan_ray",
			from = scan_origin,
			to = scan_hit.position,
			color = Color(1, 0.9, 0.3, 0.9),
			width = 2,
			time = 1,
		}
		debug_draw.DrawSphere{
			id = "physics_playground_scan_marker",
			position = scan_hit.position,
			radius = 0.12,
			color = Color(1, 0.3, 0.3, 0.9),
			time = 1,
		}
	else
		debug_draw.DrawLine{
			id = "physics_playground_scan_ray",
			from = scan_origin,
			to = scan_origin + Vec3(0, -12, 0),
			color = Color(1, 0.9, 0.3, 0.4),
			width = 1,
			time = 1,
		}
	end

	debug_draw.DrawSphere{
		id = "physics_playground_scan_emitter",
		position = scan_origin,
		radius = 0.14,
		color = Color(0.72, 0.77, 0.84, 1),
		time = 1,
	}
	label(
		"header",
		GROUND + Vec3(0, 10.2, 0),
		"PHYSICS PLAYGROUND",
		{
			"R kick pendulums   B kick ball   K wake sleeper   S re-fire bullets   C topple capsule",
		},
		Color(1, 1, 1, 1)
	)
	label(
		"bounce",
		GROUND + Vec3(-15, 4.2, -7),
		"Restitution 0.85",
		{
			"OnCollisionEnter hits: " .. bounce_collision_count,
		},
		Color(0.94, 0.44, 0.2, 1)
	)
	label(
		"friction",
		GROUND + Vec3(-15, 5, 7),
		"Friction",
		{
			"rubber mu=1.2 crawls, ice mu=0.03 races",
		},
		Color(0.6, 0.9, 1, 1)
	)
	label(
		"constraints",
		GROUND + Vec3(-8, 6.5, -7),
		"Distance constraints",
		{
			"left: rigid rope   right: spring (compliance 0.05)",
			string.format(
				"rope %.2f m   spring %.2f m",
				rope_constraint:GetCurrentLength() or 0,
				spring_constraint:GetCurrentLength() or 0
			),
		},
		Color(0.7, 0.56, 0.3, 1)
	)
	label(
		"sleep",
		GROUND + Vec3(0, 3.5, -7),
		"Sleep",
		{
			"A " .. (
				sleep_body_a:GetAwake() and
				"awake" or
				"SLEEPING"
			),
			"B " .. (
				sleep_body_b:GetAwake() and
				"awake" or
				"SLEEPING"
			) .. " (K wakes)",
			"C awake (CanSleep=false)",
		},
		Color(0.5, 1, 0.5, 1)
	)
	label(
		"kinematic",
		GROUND + Vec3(7, 3.5, 0),
		"Kinematic body",
		{
			"scripted motion, shoves dynamics",
		},
		Color(0.72, 0.77, 0.84, 1)
	)
	label(
		"mesh",
		GROUND + Vec3(15, 5, -7),
		"Static mesh",
		{
			"triangle BVH contacts",
		},
		Color(0.9, 0.3, 0.25, 1)
	)
	label(
		"convex",
		GROUND + Vec3(15, 5, 7),
		"Convex hull",
		{
			"GJK/EPA on custom hull",
		},
		Color(0.8, 0.5, 1, 1)
	)
	label(
		"forces",
		GROUND + Vec3(1.5, 6.5, 6),
		"Applied forces",
		{
			"ApplyForce hover rocket, ApplyTorque spin (held by rope)",
		},
		Color(1, 0.9, 0.3, 1)
	)
	label(
		"ccd",
		GROUND + Vec3(17, 9.5, 0),
		"CCD",
		{
			"top bullet (CCD) stops at thin plate",
			"bottom (auto CCD off) tunnels through",
		},
		Color(1, 0.55, 0.2, 1)
	)
	label(
		"mask",
		GROUND + Vec3(-3, 6.5, 10),
		"CollisionGroup / Mask",
		{
			"ball ignores group 2 boxes",
		},
		Color(0.9, 0.4, 0.85, 1)
	)
	label(
		"grid",
		GROUND + Vec3(18, 3.4, 10),
		"Friction x Restitution",
		{
			"cols: friction 0..1   rows: restitution 0..1",
		},
		Color(0.6, 0.75, 1, 1)
	)
	label(
		"capsule",
		GROUND + Vec3(5, 5, 9.2),
		"Capsule",
		{
			"stand topples (C)   log rolls   stubby bounces",
		},
		Color(0.9, 0.7, 0.4, 1)
	)
	label(
		"hover",
		GROUND + Vec3(-2, 5.5, -2),
		"GravityScale = 0",
		{
			"floats, damps, never sleeps",
		},
		Color(0.65, 0.9, 1, 1)
	)
	local scan_lines

	if scan_hit then
		scan_lines = {
			string.format("raycast hit at %.2f m", scan_hit.distance or 0),
		}
	else
		scan_lines = {
			"raycast: no hit",
		}
	end

	label(
		"raycast",
		scan_origin + Vec3(0, 0.6, 0),
		"Raycast",
		scan_lines,
		Color(1, 0.9, 0.3, 1)
	)
end)
