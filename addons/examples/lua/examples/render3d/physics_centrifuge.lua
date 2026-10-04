local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local ORIGIN = Vec3(-70, 0, -8)
local PER_SHAPE = 5
local RADIUS = 4
local HEIGHT = 6
local SIDES = 12
local THICKNESS = 0.5
local OMEGA = 3
local SPIN_UP_SECONDS = 2
local CENTER = ORIGIN + Vec3(0, 5, 0)
local seed = 4242

local function rand()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

local function yaw_quat(angle)
	return Quat(0, math.sin(angle * 0.5), 0, math.cos(angle * 0.5))
end

local ground_material = shapes.Material{Color = Color(0.22, 0.22, 0.25, 1), Roughness = 0.95, Metallic = 0}
local drum_material = shapes.Material{
	Color = Color(0.7, 0.82, 0.9, 0.25),
	Roughness = 0.1,
	Metallic = 0.2,
	Translucent = true,
}
local materials = {
	box = shapes.Material{Color = Color(0.94, 0.44, 0.2, 1), Roughness = 0.4, Metallic = 0},
	sphere = shapes.Material{Color = Color(0.2, 0.72, 1.0, 1), Roughness = 0.2, Metallic = 0.1},
	capsule = shapes.Material{Color = Color(0.4, 0.85, 0.45, 1), Roughness = 0.35, Metallic = 0},
	convex = shapes.Material{Color = Color(0.65, 0.45, 0.95, 1), Roughness = 0.2, Metallic = 0.3},
	compound = shapes.Material{Color = Color(1, 0.85, 0.25, 1), Roughness = 0.3, Metallic = 0.4},
}
shapes.Box{
	Name = "centrifuge_ground",
	Position = ORIGIN - Vec3(0, 0.5, 0),
	Size = Vec3(60, 1, 60),
	Material = ground_material,
	RigidBody = {MotionType = "static", Friction = 0.85, Restitution = 0},
}
local drum

do
	local children = {}
	local side = 2 * (RADIUS + THICKNESS) * math.tan(math.pi / SIDES) + 0.1
	local cap = RADIUS * 2 + THICKNESS * 2 + 1
	local cap_y = HEIGHT * 0.5 + THICKNESS * 0.5
	local parts = {}

	for i = 0, SIDES - 1 do
		local phi = i / SIDES * math.pi * 2
		local r = RADIUS + THICKNESS * 0.5
		parts[#parts + 1] = {
			size = Vec3(side, HEIGHT, THICKNESS),
			position = Vec3(math.sin(phi) * r, 0, math.cos(phi) * r),
			rotation = yaw_quat(phi),
		}
	end

	parts[#parts + 1] = {
		size = Vec3(cap, THICKNESS, cap),
		position = Vec3(0, -cap_y, 0),
		rotation = Quat(0, 0, 0, 1),
	}
	parts[#parts + 1] = {
		size = Vec3(cap, THICKNESS, cap),
		position = Vec3(0, cap_y, 0),
		rotation = Quat(0, 0, 0, 1),
	}

	for _, part in ipairs(parts) do
		children[#children + 1] = {
			Shape = BoxShape.New(part.size),
			Position = part.position,
			Rotation = part.rotation,
		}
	end

	drum = Entity.New{Name = "centrifuge_drum"}
	drum:AddComponent("transform")
	drum.transform:SetPosition(CENTER:Copy())
	drum:AddComponent(
		"rigid_body",
		{
			Shape = CompoundShape.New(children),
			MotionType = "kinematic",
			Friction = 0.8,
			Restitution = 0,
		}
	)

	for _, part in ipairs(parts) do
		shapes.Box{
			Name = "centrifuge_drum_wall",
			Position = part.position,
			Rotation = part.rotation,
			Size = part.size,
			Material = drum_material,
			Collision = false,
			PhysicsNoCollision = true,
			RigidBody = false,
		}:SetParent(drum)
	end
end

local function add_facet(poly, a, b, c)
	local normal = (b - a):GetCross(c - a):GetNormalized()

	if normal:Dot((a + b + c) * 0.333333) < 0 then
		b, c = c, b
		normal = normal * -1
	end

	poly:AddVertex{pos = c, uv = Vec2(0.5, 1), normal = normal}
	poly:AddVertex{pos = b, uv = Vec2(1, 0), normal = normal}
	poly:AddVertex{pos = a, uv = Vec2(0, 0), normal = normal}
	return poly
end

local function build_pyramid(poly)
	local a = Vec3(-0.4, -0.35, -0.4)
	local b = Vec3(0.4, -0.35, -0.4)
	local c = Vec3(0.4, -0.35, 0.4)
	local d = Vec3(-0.4, -0.35, 0.4)
	local apex = Vec3(0, 0.5, 0)
	add_facet(poly, a, b, apex)
	add_facet(poly, b, c, apex)
	add_facet(poly, c, d, apex)
	add_facet(poly, d, a, apex)
	add_facet(poly, a, d, c)
	add_facet(poly, a, c, b)
	return poly
end

local pyramid_hull = convex_hull.BuildFromTriangles(build_pyramid(Polygon3D.New()))
local spawners = {}

function spawners.box(position)
	return shapes.Box{
		Name = "centrifuge_box",
		Position = position,
		Size = Vec3(0.5, 0.5, 0.5),
		Material = materials.box,
		RigidBody = {Friction = 0.6, Restitution = 0.1},
	}
end

function spawners.sphere(position)
	return shapes.Sphere{
		Name = "centrifuge_sphere",
		Position = position,
		Radius = 0.3,
		Material = materials.sphere,
		RigidBody = {Radius = 0.3, Friction = 0.6, Restitution = 0.1},
	}
end

function spawners.capsule(position)
	return shapes.Capsule{
		Name = "centrifuge_capsule",
		Position = position,
		Radius = 0.22,
		Height = 0.7,
		Material = materials.capsule,
		RigidBody = {Radius = 0.22, Height = 0.7, Friction = 0.6, Restitution = 0.1},
	}
end

function spawners.convex(position)
	return shapes.Polygon{
		Name = "centrifuge_convex",
		Position = position,
		Material = materials.convex,
		BuildPolygon = build_pyramid,
		BuildBoundingBox = true,
		CollisionShape = ConvexShape.New(pyramid_hull),
		RigidBody = {ConvexHull = pyramid_hull, Friction = 0.6, Restitution = 0.1},
	}
end

function spawners.compound(position)
	local ent = shapes.Box{
		Name = "centrifuge_compound",
		Position = position,
		Size = Vec3(0.9, 0.15, 0.15),
		Material = materials.compound,
		CollisionShape = CompoundShape.New{
			{
				Shape = BoxShape.New(Vec3(0.9, 0.15, 0.15)),
				Position = Vec3(0, 0, 0),
				Rotation = Quat(0, 0, 0, 1),
			},
			{
				Shape = SphereShape.New(0.25),
				Position = Vec3(-0.45, 0, 0),
				Rotation = Quat(0, 0, 0, 1),
			},
			{
				Shape = SphereShape.New(0.25),
				Position = Vec3(0.45, 0, 0),
				Rotation = Quat(0, 0, 0, 1),
			},
		},
		RigidBody = {Friction = 0.6, Restitution = 0.1},
	}

	for _, x in ipairs{-0.45, 0.45} do
		shapes.Sphere{
			Name = "centrifuge_compound_end",
			Position = Vec3(x, 0, 0),
			Radius = 0.25,
			Material = materials.compound,
			Collision = false,
			PhysicsNoCollision = true,
			RigidBody = false,
		}:SetParent(ent)
	end

	return ent
end

for _, shape_name in ipairs{"box", "sphere", "capsule", "convex", "compound"} do
	for _ = 1, PER_SHAPE do
		local angle = rand() * math.pi * 2
		local r = rand() * (RADIUS - 1.2)
		spawners[shape_name](
			CENTER + Vec3(math.sin(angle) * r, (rand() - 0.5) * (HEIGHT - 2), math.cos(angle) * r)
		)
	end
end

local camera = render3d.GetCamera()
camera:SetPosition(ORIGIN + Vec3(0, 7, 16))
camera:SetRotation(QuatDeg3(-12, 0, 0))
local angle = 0
local elapsed = 0

event.AddListener("Update", "physics_centrifuge", function(dt)
	elapsed = elapsed + dt
	angle = angle + OMEGA * math.min(1, elapsed / SPIN_UP_SECONDS) * dt
	drum.transform:SetRotation(yaw_quat(angle))
end)
