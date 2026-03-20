local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local sphere_shape = SphereShape.New
local box_shape = BoxShape.New
local convex_shape = ConvexShape.New
local CCD_FIXED_STEPS = {1 / 60}

local function simulate_physics(steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

local function with_fixed_step(fixed_dt, callback)
	local previous_fixed_dt = physics.FixedTimeStep
	local previous_accumulator = physics.FrameAccumulator
	local previous_alpha = physics.InterpolationAlpha
	physics.FixedTimeStep = fixed_dt
	physics.FrameAccumulator = 0
	physics.InterpolationAlpha = 0
	local ok, err = xpcall(callback, debug.traceback)
	physics.FixedTimeStep = previous_fixed_dt
	physics.FrameAccumulator = previous_accumulator or 0
	physics.InterpolationAlpha = previous_alpha or 0

	if not ok then
		error(string.format("[fixed_dt=%.6f] %s", fixed_dt, tostring(err)), 0)
	end
end

local function create_flat_ground(name, extent)
	extent = extent or 8
	local ground = Entity.New({Name = name})
	ground:AddComponent("transform")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-extent, 0, -extent), uv = Vec2(0, 0), normal = Vec3(0, 1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, extent), uv = Vec2(0.5, 1), normal = Vec3(0, 1, 0)}
	poly:AddVertex{pos = Vec3(extent, 0, -extent), uv = Vec2(1, 0), normal = Vec3(0, 1, 0)}
	poly:BuildBoundingBox()
	test_helpers.AttachWorldGeometryBody(ground, poly)
	return ground
end

local function add_triangle(poly, a, b, c)
	poly:AddVertex{pos = a, uv = Vec2(0, 0)}
	poly:AddVertex{pos = b, uv = Vec2(1, 0)}
	poly:AddVertex{pos = c, uv = Vec2(0.5, 1)}
end

local function create_internal_vertex_cube_mesh(size)
	size = size or 1
	local poly = Polygon3D.New()
	local s = size
	local v = {
		Vec3(-s, -s, -s),
		Vec3(s, -s, -s),
		Vec3(s, s, -s),
		Vec3(-s, s, -s),
		Vec3(-s, -s, s),
		Vec3(s, -s, s),
		Vec3(s, s, s),
		Vec3(-s, s, s),
	}
	local center = Vec3(0, 0, 0)
	local faces = {
		{1, 2, 3},
		{1, 3, 4},
		{5, 7, 6},
		{5, 8, 7},
		{1, 5, 6},
		{1, 6, 2},
		{4, 3, 7},
		{4, 7, 8},
		{1, 4, 8},
		{1, 8, 5},
		{2, 6, 7},
		{2, 7, 3},
	}

	for _, face in ipairs(faces) do
		add_triangle(poly, v[face[1]], v[face[2]], v[face[3]])
	end

	add_triangle(poly, v[1], v[2], center)
	add_triangle(poly, v[2], v[6], center)
	add_triangle(poly, v[6], v[5], center)
	add_triangle(poly, v[5], v[1], center)
	poly:BuildBoundingBox()
	return poly
end

local function create_pyramid_source_mesh()
	local poly = Polygon3D.New()
	local a = Vec3(-0.6, -0.5, -0.6)
	local b = Vec3(0.6, -0.5, -0.6)
	local c = Vec3(0.6, -0.5, 0.6)
	local d = Vec3(-0.6, -0.5, 0.6)
	local apex = Vec3(0, 0.7, 0)
	add_triangle(poly, a, b, apex)
	add_triangle(poly, b, c, apex)
	add_triangle(poly, c, d, apex)
	add_triangle(poly, d, a, apex)
	add_triangle(poly, a, d, c)
	add_triangle(poly, a, c, b)
	poly:BuildBoundingBox()
	return poly
end

local function create_octahedron_source_mesh(radius)
	radius = radius or 1
	local poly = Polygon3D.New()
	local top = Vec3(0, radius, 0)
	local bottom = Vec3(0, -radius, 0)
	local px = Vec3(radius, 0, 0)
	local nx = Vec3(-radius, 0, 0)
	local pz = Vec3(0, 0, radius)
	local nz = Vec3(0, 0, -radius)
	add_triangle(poly, top, px, pz)
	add_triangle(poly, top, pz, nx)
	add_triangle(poly, top, nx, nz)
	add_triangle(poly, top, nz, px)
	add_triangle(poly, bottom, pz, px)
	add_triangle(poly, bottom, nx, pz)
	add_triangle(poly, bottom, nz, nx)
	add_triangle(poly, bottom, px, nz)
	poly:BuildBoundingBox()
	return poly
end

local function create_box_source_mesh(size)
	local poly = Polygon3D.New()
	local hx = size.x * 0.5
	local hy = size.y * 0.5
	local hz = size.z * 0.5
	local v = {
		Vec3(-hx, -hy, -hz),
		Vec3(hx, -hy, -hz),
		Vec3(hx, hy, -hz),
		Vec3(-hx, hy, -hz),
		Vec3(-hx, -hy, hz),
		Vec3(hx, -hy, hz),
		Vec3(hx, hy, hz),
		Vec3(-hx, hy, hz),
	}
	local faces = {
		{1, 2, 3},
		{1, 3, 4},
		{5, 7, 6},
		{5, 8, 7},
		{1, 5, 6},
		{1, 6, 2},
		{4, 3, 7},
		{4, 7, 8},
		{1, 4, 8},
		{1, 8, 5},
		{2, 6, 7},
		{2, 7, 3},
	}

	for _, face in ipairs(faces) do
		add_triangle(poly, v[face[1]], v[face[2]], v[face[3]])
	end

	poly:BuildBoundingBox()
	return poly
end

T.Test3D("Convex hull approximation removes interior triangle vertices", function()
	local hull = convex_hull.BuildFromTriangles(create_internal_vertex_cube_mesh())
	local has_center = false

	for _, point in ipairs(hull.vertices) do
		if point:GetLength() < 0.05 then
			has_center = true

			break
		end
	end

	T(hull ~= nil)["=="](true)
	T(#hull.vertices)["=="](8)
	T(#hull.faces)[">="](6)
	T(#hull.indices)[">="](36)
	T(has_center)["=="](false)
end)

T.Test3D("Convex rigid body can rest on triangle world geometry", function()
	local ground = create_flat_ground("convex_ground_world", 10)
	local hull = convex_hull.BuildFromTriangles(create_pyramid_source_mesh())
	local body_ent = Entity.New({Name = "convex_ground_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(hull),
			ConvexHull = hull,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	simulate_physics(300)
	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](0.3)
	T(position.y)["<="](0.8)
	T(body:GetGroundNormal().y)[">"](0.9)
	body_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid sphere collides with static convex hull", function()
	local hull = convex_hull.BuildFromTriangles(create_octahedron_source_mesh(1))
	local convex_ent = Entity.New({Name = "convex_static_octahedron"})
	convex_ent:AddComponent("transform")
	convex_ent.transform:SetPosition(Vec3(0, 1, 0))
	convex_ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(hull),
			ConvexHull = hull,
			MotionType = "static",
		}
	)
	local sphere_ent = Entity.New({Name = "convex_hit_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(-3, 1, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			Restitution = 0,
		}
	)
	sphere:SetVelocity(Vec3(12, 0, 0))
	simulate_physics(90)
	local position = sphere_ent.transform:GetPosition()
	local velocity = sphere:GetVelocity()
	T(position.x)["<="](-1.15)
	T(position.x)[">="](-1.9)
	T(math.abs(position.y - 1))["<"](0.2)
	T(velocity.x)["<"](0.5)
	sphere_ent:Remove()
	convex_ent:Remove()
end)

T.Test3D("Convex rigid body collides with static box", function()
	local hull = convex_hull.BuildFromTriangles(create_pyramid_source_mesh())
	local box_ent = Entity.New({Name = "convex_static_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 1, 0))
	box_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(4, 1, 4)),
			Size = Vec3(4, 1, 4),
			MotionType = "static",
		}
	)
	local convex_ent = Entity.New({Name = "convex_dynamic_box_test"})
	convex_ent:AddComponent("transform")
	convex_ent.transform:SetPosition(Vec3(0, 4, 0))
	local convex = convex_ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(hull),
			ConvexHull = hull,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	simulate_physics(320)
	local position = convex_ent.transform:GetPosition()
	T(convex:GetGrounded())["=="](true)
	T(position.y)[">="](1.9)
	T(position.y)["<="](2.15)
	T(math.abs(position.x))["<"](0.4)
	convex_ent:Remove()
	box_ent:Remove()
end)

T.Test3D("Fast rigid sphere does not tunnel through thin static convex hull", function()
	local hull = convex_hull.BuildFromTriangles(create_box_source_mesh(Vec3(6, 0.2, 6)))
	local blocker_ent = Entity.New({Name = "rigid_ccd_convex_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(hull),
			ConvexHull = hull,
			MotionType = "static",
		}
	)
	local sphere_ent = Entity.New({Name = "rigid_ccd_convex_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 8, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	sphere:SetVelocity(Vec3(0, -320, 0))
	physics.Update(1 / 10)
	local position = sphere_ent.transform:GetPosition()
	blocker_ent:Remove()
	sphere_ent:Remove()
	T(position.y)[">="](1.55)
	T(math.abs(position.x))["<"](0.1)
	T(math.abs(position.z))["<"](0.1)
end)

T.Test3D("Fast rigid convex body does not tunnel through thin static box", function()
	local blocker_ent = Entity.New({Name = "rigid_ccd_box_blocker_for_convex"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(6, 0.2, 6)),
			Size = Vec3(6, 0.2, 6),
			MotionType = "static",
		}
	)
	local hull = convex_hull.BuildFromTriangles(create_box_source_mesh(Vec3(1, 1, 1)))
	local convex_ent = Entity.New({Name = "rigid_ccd_fast_convex"})
	convex_ent:AddComponent("transform")
	convex_ent.transform:SetPosition(Vec3(0, 8, 0))
	local convex = convex_ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(hull),
			ConvexHull = hull,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	convex:SetVelocity(Vec3(0, -320, 0))
	physics.Update(1 / 10)
	local position = convex_ent.transform:GetPosition()
	blocker_ent:Remove()
	convex_ent:Remove()
	T(position.y)[">="](1.45)
	T(math.abs(position.x))["<"](0.15)
	T(math.abs(position.z))["<"](0.15)
end)

T.Test3D("Fast rigid box does not tunnel through thin static convex hull", function()
	local hull = convex_hull.BuildFromTriangles(create_box_source_mesh(Vec3(6, 0.2, 6)))
	local blocker_ent = Entity.New({Name = "rigid_ccd_static_convex_for_box"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(hull),
			ConvexHull = hull,
			MotionType = "static",
		}
	)
	local box_ent = Entity.New({Name = "rigid_ccd_fast_box_vs_convex"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 8, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(1, 1, 1)),
			Size = Vec3(1, 1, 1),
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	box:SetVelocity(Vec3(0, -320, 0))
	physics.Update(1 / 10)
	local position = box_ent.transform:GetPosition()
	blocker_ent:Remove()
	box_ent:Remove()
	T(position.y)[">="](1.45)
	T(math.abs(position.x))["<"](0.15)
	T(math.abs(position.z))["<"](0.15)
end)

T.Test3D("Fast rigid convex bodies do not tunnel through each other", function()
	local hull = convex_hull.BuildFromTriangles(create_box_source_mesh(Vec3(1, 1, 1)))
	local left_ent = Entity.New({Name = "rigid_ccd_dynamic_convex_left"})
	left_ent:AddComponent("transform")
	left_ent.transform:SetPosition(Vec3(-4, 1, 0))
	local left = left_ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(hull),
			ConvexHull = hull,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Restitution = 0,
		}
	)
	local right_ent = Entity.New({Name = "rigid_ccd_dynamic_convex_right"})
	right_ent:AddComponent("transform")
	right_ent.transform:SetPosition(Vec3(4, 1, 0))
	local right = right_ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(hull),
			ConvexHull = hull,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Restitution = 0,
		}
	)
	left:SetVelocity(Vec3(140, 0, 0))
	right:SetVelocity(Vec3(-140, 0, 0))
	physics.Update(1 / 30)
	local left_pos = left_ent.transform:GetPosition()
	local right_pos = right_ent.transform:GetPosition()
	local separation = (right_pos - left_pos):GetLength()
	left_ent:Remove()
	right_ent:Remove()
	T(separation)[">="](0.95)
	T(left_pos.x)["<="](right_pos.x)
end)

T.Test3D("Fast rigid convex and box bodies do not tunnel through each other", function()
	local hull = convex_hull.BuildFromTriangles(create_box_source_mesh(Vec3(1, 1, 1)))
	local convex_ent = Entity.New({Name = "rigid_ccd_dynamic_convex_vs_box"})
	convex_ent:AddComponent("transform")
	convex_ent.transform:SetPosition(Vec3(-4, 1, 0))
	local convex = convex_ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(hull),
			ConvexHull = hull,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Restitution = 0,
		}
	)
	local box_ent = Entity.New({Name = "rigid_ccd_dynamic_box_vs_convex"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(4, 1, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(1, 1, 1)),
			Size = Vec3(1, 1, 1),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Restitution = 0,
		}
	)
	convex:SetVelocity(Vec3(140, 0, 0))
	box:SetVelocity(Vec3(-140, 0, 0))
	physics.Update(1 / 30)
	local convex_pos = convex_ent.transform:GetPosition()
	local box_pos = box_ent.transform:GetPosition()
	local separation = (box_pos - convex_pos):GetLength()
	convex_ent:Remove()
	box_ent:Remove()
	T(separation)[">="](0.95)
	T(convex_pos.x)["<="](box_pos.x)
end)

T.Test3D("Fast rotating rigid convex body does not miss a thin static box", function()
	local blocker_ent = Entity.New({Name = "rigid_ccd_rotating_convex_target"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0.6, 1.6, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(0.3, 0.3, 1)),
			Size = Vec3(0.3, 0.3, 1),
			MotionType = "static",
		}
	)
	local hull = convex_hull.BuildFromTriangles(create_box_source_mesh(Vec3(0.15, 4, 0.15)))
	local rod_ent = Entity.New({Name = "rigid_ccd_rotating_convex_rod"})
	rod_ent:AddComponent("transform")
	rod_ent.transform:SetPosition(Vec3(0, 1, 0))
	local rod = rod_ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(hull),
			ConvexHull = hull,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxAngularSpeed = 1000,
			Restitution = 0,
		}
	)
	local enter_hits = 0

	rod_ent:AddLocalListener("OnCollisionEnter", function()
		enter_hits = enter_hits + 1
	end)

	rod:SetAngularVelocity(Vec3(0, 0, -16))
	physics.Update(1 / 10)
	local angles = rod_ent.transform:GetRotation():GetAngles()
	rod_ent:Remove()
	blocker_ent:Remove()
	T(enter_hits)[">"](0)
	T(math.abs(angles.z))["<"](1.45)
end)

T.Test3D("Fast rigid convex body does not tunnel through thin static box at smaller fixed steps", function()
	for _, fixed_dt in ipairs(CCD_FIXED_STEPS) do
		with_fixed_step(fixed_dt, function()
			local blocker_ent = Entity.New({Name = "rigid_ccd_box_blocker_for_convex_small_step"})
			blocker_ent:AddComponent("transform")
			blocker_ent.transform:SetPosition(Vec3(0, 1, 0))
			blocker_ent:AddComponent(
				"rigid_body",
				{
					Shape = box_shape(Vec3(6, 0.2, 6)),
					Size = Vec3(6, 0.2, 6),
					MotionType = "static",
				}
			)
			local hull = convex_hull.BuildFromTriangles(create_box_source_mesh(Vec3(1, 1, 1)))
			local convex_ent = Entity.New({Name = "rigid_ccd_fast_convex_small_step"})
			convex_ent:AddComponent("transform")
			convex_ent.transform:SetPosition(Vec3(0, 8, 0))
			local convex = convex_ent:AddComponent(
				"rigid_body",
				{
					Shape = convex_shape(hull),
					ConvexHull = hull,
					LinearDamping = 0,
					AngularDamping = 0,
					MaxLinearSpeed = 1000,
				}
			)
			convex:SetVelocity(Vec3(0, -320, 0))
			physics.Update(1 / 10)
			local position = convex_ent.transform:GetPosition()
			blocker_ent:Remove()
			convex_ent:Remove()
			T(position.y)[">="](1.45)
			T(math.abs(position.x))["<"](0.15)
			T(math.abs(position.z))["<"](0.15)
		end)
	end
end)

T.Test3D("Fast rotating rigid convex body remains detectable at smaller fixed steps", function()
	for _, fixed_dt in ipairs(CCD_FIXED_STEPS) do
		with_fixed_step(fixed_dt, function()
			local blocker_ent = Entity.New({Name = "rigid_ccd_rotating_convex_target_small_step"})
			blocker_ent:AddComponent("transform")
			blocker_ent.transform:SetPosition(Vec3(0.6, 1.6, 0))
			blocker_ent:AddComponent(
				"rigid_body",
				{
					Shape = box_shape(Vec3(0.3, 0.3, 1)),
					Size = Vec3(0.3, 0.3, 1),
					MotionType = "static",
				}
			)
			local hull = convex_hull.BuildFromTriangles(create_box_source_mesh(Vec3(0.15, 4, 0.15)))
			local rod_ent = Entity.New({Name = "rigid_ccd_rotating_convex_rod_small_step"})
			rod_ent:AddComponent("transform")
			rod_ent.transform:SetPosition(Vec3(0, 1, 0))
			local rod = rod_ent:AddComponent(
				"rigid_body",
				{
					Shape = convex_shape(hull),
					ConvexHull = hull,
					GravityScale = 0,
					LinearDamping = 0,
					AngularDamping = 0,
					MaxAngularSpeed = 1000,
					Restitution = 0,
				}
			)
			local enter_hits = 0

			rod_ent:AddLocalListener("OnCollisionEnter", function()
				enter_hits = enter_hits + 1
			end)

			rod:SetAngularVelocity(Vec3(0, 0, -16))
			physics.Update(1 / 10)
			local angles = rod_ent.transform:GetRotation():GetAngles()
			rod_ent:Remove()
			blocker_ent:Remove()
			T(enter_hits)[">"](0)
			T(math.abs(angles.z))["<"](1.45)
		end)
	end
end)
