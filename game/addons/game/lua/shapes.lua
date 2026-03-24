local Vec3 = import("goluwa/structs/vec3.lua")
local MaterialClass = import("goluwa/render3d/material.lua")
local TextureClass = import("goluwa/render/texture.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local box_shape = BoxShape.New
local sphere_shape = SphereShape.New
local capsule_shape = CapsuleShape.New
local convex_shape = ConvexShape.New
local shapes = {}

local function get(config, name)
	if not config then return nil end

	return config[name] or config[name:lower()]
end

local function copy_table(tbl)
	local out = {}

	if not tbl then return out end

	for k, v in pairs(tbl) do
		out[k] = v
	end

	return out
end

local function is_material(value)
	return type(value) == "table" and (value.SetAlbedoTexture or value.GetAlbedoTexture)
end

local function is_color(value)
	local value_type = type(value)

	if value_type ~= "table" and value_type ~= "cdata" and value_type ~= "userdata" then
		return false
	end

	return value.r ~= nil and value.g ~= nil and value.b ~= nil
end

local function color_to_shader(color)
	return string.format(
		"return vec4(%f, %f, %f, %f);",
		color.r or 0,
		color.g or 0,
		color.b or 0,
		color.a or 1
	)
end

local function scalar_to_shader(value)
	return string.format("return vec4(%f);", value or 0)
end

local function resolve_texture(source, shared)
	if source == nil then return nil end

	if is_color(source) then
		local tex = TextureClass.New{
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
		tex:Shade(color_to_shader(source), {custom_declarations = shared})
		return tex
	end

	if type(source) == "number" then
		local tex = TextureClass.New{
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
		tex:Shade(scalar_to_shader(source), {custom_declarations = shared})
		return tex
	end

	if type(source) ~= "string" then return source end

	local tex = TextureClass.New{
		width = 1024,
		height = 1024,
		format = "r8g8b8a8_unorm",
		mip_map_levels = "auto",
		image = {
			usage = {"storage", "sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "repeat",
			wrap_t = "clamp_to_edge",
		},
	}
	tex:Shade(source, {custom_declarations = shared})
	return tex
end

function shapes.Texture(source, shared)
	return resolve_texture(source, shared)
end

function shapes.Material(config)
	if not config then return MaterialClass.New() end

	if is_material(config) then return config end

	local material = MaterialClass.New()
	local shared = config.Shared
	local consumed = {
		Shared = true,
		Color = true,
	}

	if config.Color and not config.Albedo then
		material:SetAlbedoTexture(resolve_texture(config.Color, shared))
	end

	for k, v in pairs(config) do
		if not consumed[k] then
			local texture_setter = material["Set" .. k .. "Texture"]

			if texture_setter then
				texture_setter(material, resolve_texture(v, shared))
			elseif material["Set" .. k] then
				material["Set" .. k](material, v)
			else
				error("unknown material key: " .. tostring(k))
			end
		end
	end

	return material
end

local function create_entity(config)
	local ent = Entity.New{Name = get(config, "Name") or "shape"}
	local physics_no_collision = get(config, "PhysicsNoCollision")

	if physics_no_collision ~= nil then
		ent.PhysicsNoCollision = physics_no_collision
	end

	ent:AddComponent("transform")
	local position = get(config, "Position")
	local rotation = get(config, "Rotation")
	local scale = get(config, "Scale")

	if position then ent.transform:SetPosition(position) end

	if rotation then ent.transform:SetRotation(rotation) end

	if scale then ent.transform:SetScale(scale) end

	return ent
end

local function add_model(ent, polygon, material)
	if not polygon then return nil end

	if
		getmetatable(material) == nil and
		type(material) == "table" and
		not is_material(material)
	then
		material = shapes.Material(material)
	else
		material = shapes.Material(material)
	end

	ent:AddComponent("model")
	polygon:Upload()
	ent.model:AddPrimitive(polygon, material)
	ent.model:BuildAABB()
	return material
end

local function resolve_body_shape(config, default_shape, ...)
	local override = get(config, "CollisionShape")

	if override == nil then override = get(config, "Shape") end

	if override == nil then return default_shape(...) end

	if override == false then return nil end

	if type(override) == "function" then return override(...) end

	if override == "convex" then return convex_shape() end

	if override == "mesh" then return default_shape(...) end

	return override
end

local function add_rigid_body(ent, config, shape)
	if get(config, "Collision") == false then return nil end

	local rigid_body = copy_table(get(config, "RigidBody"))

	if rigid_body == false then return nil end

	if shape ~= nil and rigid_body.Shape == nil then rigid_body.Shape = shape end

	if next(rigid_body) == nil then return nil end

	return ent:AddComponent("rigid_body", rigid_body)
end

function shapes.Box(config)
	config = config or {}
	local size = get(config, "Size") or Vec3(1, 1, 1)
	local ent = create_entity(config)
	ent.transform:SetScale(size)
	local polygon = Polygon3D.New()
	polygon:CreateCube(0.5)
	local material = add_model(ent, polygon, get(config, "Material"))
	local body = add_rigid_body(ent, config, resolve_body_shape(config, box_shape, size))
	return ent, body, material
end

function shapes.Sphere(config)
	config = config or {}
	local radius = get(config, "Radius") or 0.5
	local ent = create_entity(config)
	local polygon = Polygon3D.New()
	polygon:CreateSphere(radius)
	local material = add_model(ent, polygon, get(config, "Material"))
	local body = add_rigid_body(ent, config, resolve_body_shape(config, sphere_shape, radius))
	return ent, body, material
end

function shapes.Capsule(config)
	config = config or {}
	local radius = get(config, "Radius") or 0.5
	local height = get(config, "Height") or radius * 2
	local ent = create_entity(config)
	ent.transform:SetScale(Vec3(radius * 2, math.max(height, radius * 2), radius * 2))
	local polygon = Polygon3D.New()
	polygon:CreateSphere(0.5)
	local material = add_model(ent, polygon, get(config, "Material"))
	local body = add_rigid_body(ent, config, resolve_body_shape(config, capsule_shape, radius, height))
	return ent, body, material
end

function shapes.Polygon(config)
	config = config or {}
	local ent = create_entity(config)
	local polygon = get(config, "Polygon")

	if type(polygon) == "function" then
		local poly = Polygon3D.New()
		polygon = polygon(poly, config) or poly
	elseif polygon == nil then
		local builder = get(config, "BuildPolygon") or get(config, "CreatePolygon")
		local poly = Polygon3D.New()
		polygon = builder and (builder(poly, config) or poly) or poly
	end

	if get(config, "BuildBoundingBox") ~= false and polygon.BuildBoundingBox then
		polygon:BuildBoundingBox()
	end

	local material = add_model(ent, polygon, get(config, "Material"))
	local collision_shape = get(config, "CollisionShape")

	if collision_shape == nil or collision_shape == "mesh" then
		collision_shape = MeshShape.New(polygon)
	elseif collision_shape == "convex" then
		collision_shape = convex_shape()
	elseif type(collision_shape) == "function" then
		collision_shape = collision_shape(polygon, config)
	end

	local body = add_rigid_body(ent, config, collision_shape)
	return ent, body, material, polygon
end

return shapes
