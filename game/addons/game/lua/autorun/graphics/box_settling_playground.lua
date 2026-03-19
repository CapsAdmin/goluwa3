local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local box_shape = BoxShape.New
local convex_shape = ConvexShape.New
local ORIGIN = Vec3(70, 0, -8)

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

local function add_triangle(poly, a, b, c)
	poly:AddVertex({pos = a, uv = Vec2(0, 0), normal = Vec3(0, -1, 0)})
	poly:AddVertex({pos = b, uv = Vec2(1, 0), normal = Vec3(0, -1, 0)})
	poly:AddVertex({pos = c, uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)})
	return poly
end

local function spawn_triangle_platform(position, material)
	local ent = Entity.New({Name = "box_settling_triangle_platform"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetRotation(make_rotation())
	ent:AddComponent("model")
	local poly = Polygon3D.New()
	add_triangle(poly, Vec3(-4, 0, -3), Vec3(4, 0, -3), Vec3(-4, 0, 3))
	add_triangle(poly, Vec3(4, 0, -3), Vec3(4, 0, 3), Vec3(-4, 0, 3))
	poly:BuildBoundingBox()
	poly:Upload()
	ent.model:AddPrimitive(poly, material)
	ent.model:BuildAABB()
	ent:AddComponent(
		"rigid_body",
		{
			Shape = MeshShape.New(poly),
			MotionType = "static",
			Friction = 0.85,
			Restitution = 0,
		}
	)
	return ent
end

local function spawn_static_box(position, size, material, rotation)
	local ent = Entity.New({Name = "box_settling_static_box"})
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

local function spawn_dynamic_box(def)
	def = def or {}
	local position = def.position or ORIGIN
	local size = def.size or Vec3(1, 1, 1)
	local material = def.material or make_material(Color(0.8, 0.8, 0.8, 1), 0.65, 0)
	local rotation = def.rotation or make_rotation()
	local options = def.options or {}
	options = options or {}
	options.LinearDamping = 0
	options.AngularDamping = 0
	options.AirLinearDamping = 0
	options.AirAngularDamping = 0
	local ent = Entity.New{Name = options.Name or "box_settling_dynamic_box"}
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetRotation(rotation or make_rotation())
	add_cube_model(ent, size, material)
	ent:AddComponent(
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
		}
	)
	return ent
end

local function spawn_dynamic_convex_cube(position, size, material, rotation, options)
	options = options or {}
	options.LinearDamping = 0
	options.AngularDamping = 0
	options.AirLinearDamping = 0
	options.AirAngularDamping = 0
	local ent = Entity.New{Name = options.Name or "box_settling_dynamic_convex_cube"}
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetRotation(rotation or make_rotation())
	add_cube_model(ent, size, material)
	ent:AddComponent(
		"rigid_body",
		{
			Shape = convex_shape(),
			Mass = options.Mass,
			AutomaticMass = options.AutomaticMass,
			LinearDamping = options.LinearDamping or 0.05,
			AngularDamping = options.AngularDamping or 0.12,
			AirLinearDamping = options.AirLinearDamping or 0.02,
			AirAngularDamping = options.AirAngularDamping or 0.05,
			Friction = options.Friction or 0.7,
			Restitution = options.Restitution or 0,
		}
	)
	return ent
end

local ground_material = make_material(Color(0.20, 0.18, 0.16, 1), 0.92, 0)
local steel_material = make_material(Color(0.72, 0.77, 0.84, 1), 0.22, 1)
local payload_material = make_material(Color(0.94, 0.44, 0.20, 1), 0.38, 0)
local accent_material = make_material(Color(0.20, 0.72, 1.00, 1), 0.18, 0.1)
local wood_material = make_material(Color(0.49, 0.31, 0.16, 1), 0.88, 0)
local triangle_material = make_material(Color(0.92, 0.18, 0.16, 1), 0.8, 0)
spawn_static_box(ORIGIN + Vec3(0, -0.75, 0), Vec3(20, 1.5, 12), ground_material)
spawn_triangle_platform(ORIGIN + Vec3(0, 0.02, -10), triangle_material)
	spawn_dynamic_box{
		position = ORIGIN + Vec3(-6.0, 2.2, 0),
		size = Vec3(0.9, 0.9, 0.9),
		rotation = make_rotation(8, 20, -6),
		material = steel_material,
		options = {Name = "box_settling_steel_box", Mass = 1.2, AutomaticMass = false, Friction = 0.65, AngularDamping = 0.08},
	}
	spawn_dynamic_box{
		position = ORIGIN + Vec3(-2.0, 2.8, 0),
		size = Vec3(0.7, 2.0, 0.7),
		rotation = make_rotation(0, 32, 14),
		material = wood_material,
		options = {Name = "box_settling_wood_tall_box", Mass = 1.6, AutomaticMass = false, Friction = 0.82, AngularDamping = 0.12},
	}
	_G.BLUE_BOX = spawn_dynamic_box{
		position = ORIGIN + Vec3(2.0, 2.0, 0),
		size = Vec3(1.8, 0.45, 1.0),
		rotation = make_rotation(-6, -18, 9),
		material = accent_material,
		options = {Name = "box_settling_blue_box", Mass = 1.1, AutomaticMass = false, Friction = 0.55, AngularDamping = 0.09},
	}
	spawn_dynamic_box{
		position = ORIGIN + Vec3(6.0, 2.6, 0),
		size = Vec3(1.2, 1.4, 0.5),
		rotation = make_rotation(12, -26, -12),
		material = payload_material,
		options = {Name = "box_settling_payload_box", Mass = 1.45, AutomaticMass = false, Friction = 0.58, AngularDamping = 0.1},
	}



spawn_dynamic_convex_cube(
	ORIGIN + Vec3(0, 2.2, -10),
	Vec3(1.0, 1.0, 1.0),
	triangle_material,
	make_rotation(7, 18, -5),
	{Name = "box_settling_dynamic_convex_compare", Mass = 1.2, AutomaticMass = false, Friction = 0.65, AngularDamping = 0.08}
)
