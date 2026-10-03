local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local assets = import("goluwa/assets.lua")
local Entity = import("goluwa/entities/entity.lua")
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
local BOX_MODEL_PATH = "models/box.lua"
local SPHERE_MODEL_PATH = "models/sphere.lua"
local CONE_MODEL_PATH = "models/cone.lua"
local CAPSULE_MODEL_PATH = "models/capsule.lua"

local function get(config, name)
	if not config then return nil end

	local value = config[name]

	if value == nil then value = config[name:lower()] end

	return value
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

function shapes.Texture(source, shared)
	return import("goluwa/render3d/material.lua").ResolveTexture(source, shared)
end

-- Material.New with the defaults of a dull dielectric. a plain Material is a fully
-- metallic, mirror like surface unless a texture says otherwise, which suits
-- loaded assets but not a shape made from a color
function shapes.Material(config)
	if not RENDER_3D then return end

	if is_material(config) then return config end

	config = config or {}
	local material = import("goluwa/render3d/material.lua").New(config)

	if config.Metallic == nil and config.MetallicMultiplier == nil then
		material:SetMetallicMultiplier(0)
	end

	if config.Roughness == nil and config.RoughnessMultiplier == nil then
		material:SetRoughnessMultiplier(0.6)
	end

	return material
end

local build_plane

do
	local up_axis = Vec3(0, 1, 0)
	local forward_axis = Vec3(0, 0, 1)

	-- a plane facing normal. right and up come from the up hint, the world up
	-- axis unless the normal is parallel to it
	function shapes.BuildPlane(poly, pos, normal, size_x, size_y, texture_scale, segments_x, segments_y, up_hint)
		normal = normal:GetNormalized()
		up_hint = up_hint or up_axis

		if math.abs(up_hint:GetDot(normal)) > 0.999 then up_hint = forward_axis end

		local up = (up_hint - normal * up_hint:GetDot(normal)):GetNormalized()
		local right = up:GetCross(normal)
		build_plane(poly, pos, normal, right, up, size_x, size_y, texture_scale, segments_x, segments_y)
	end

	-- the face is visible from the side its normal points to when right x up = normal
	function build_plane(poly, pos, normal, right, up, size_x, size_y, texture_scale, segments_x, segments_y)
		right = right:GetNormalized()
		up = up:GetNormalized()

		if right:GetCross(up):GetDot(normal) <= 0 then
			error("plane right x up must point the same way as its normal", 3)
		end

		local tangent = {
			x = right.x,
			y = right.y,
			z = right.z,
			w = normal:GetCross(right):GetDot(up) < 0 and -1 or 1,
		}
		size_x = size_x or 1
		size_y = size_y or 1
		texture_scale = texture_scale or 1
		segments_x = math.max(math.floor(segments_x or 1), 1)
		segments_y = math.max(math.floor(segments_y or 1), 1)

		for ix = 0, segments_x - 1 do
			local u0 = ix / segments_x
			local u1 = (ix + 1) / segments_x
			local x0 = -size_x + u0 * (size_x * 2)
			local x1 = -size_x + u1 * (size_x * 2)

			for iy = 0, segments_y - 1 do
				local v0 = iy / segments_y
				local v1 = (iy + 1) / segments_y
				local y0 = -size_y + v0 * (size_y * 2)
				local y1 = -size_y + v1 * (size_y * 2)
				local p1 = pos + right * x0 + up * y0
				local p2 = pos + right * x1 + up * y0
				local p3 = pos + right * x1 + up * y1
				local p4 = pos + right * x0 + up * y1
				local uv1 = Vec2(u0 * texture_scale, v0 * texture_scale)
				local uv2 = Vec2(u1 * texture_scale, v0 * texture_scale)
				local uv3 = Vec2(u1 * texture_scale, v1 * texture_scale)
				local uv4 = Vec2(u0 * texture_scale, v1 * texture_scale)
				poly:AddVertex{pos = p1, uv = uv1, normal = normal, tangent = tangent}
				poly:AddVertex{pos = p3, uv = uv3, normal = normal, tangent = tangent}
				poly:AddVertex{pos = p2, uv = uv2, normal = normal, tangent = tangent}
				poly:AddVertex{pos = p1, uv = uv1, normal = normal, tangent = tangent}
				poly:AddVertex{pos = p4, uv = uv4, normal = normal, tangent = tangent}
				poly:AddVertex{pos = p3, uv = uv3, normal = normal, tangent = tangent}
			end
		end
	end
end

function shapes.BuildCube(poly, size, texture_scale, subdivisions)
	size = size or 1
	texture_scale = texture_scale or 1
	local segments_x, segments_y, segments_z = 1, 1, 1

	if type(subdivisions) == "number" then
		local count = math.max(math.floor(subdivisions), 1)
		segments_x, segments_y, segments_z = count, count, count
	elseif type(subdivisions) == "table" then
		segments_x = math.max(math.floor(subdivisions.x or subdivisions[1] or 1), 1)
		segments_y = math.max(math.floor(subdivisions.y or subdivisions[2] or segments_x), 1)
		segments_z = math.max(math.floor(subdivisions.z or subdivisions[3] or segments_x), 1)
	end

	-- +Z, -Z, +Y, -Y, +X, -X
	build_plane(poly, Vec3(0, 0, size), Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0), size, size, texture_scale, segments_x, segments_y)
	build_plane(poly, Vec3(0, 0, -size), Vec3(0, 0, -1), Vec3(-1, 0, 0), Vec3(0, 1, 0), size, size, texture_scale, segments_x, segments_y)
	build_plane(poly, Vec3(0, size, 0), Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, -1), size, size, texture_scale, segments_x, segments_z)
	build_plane(poly, Vec3(0, -size, 0), Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1), size, size, texture_scale, segments_x, segments_z)
	build_plane(poly, Vec3(size, 0, 0), Vec3(1, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0), size, size, texture_scale, segments_z, segments_y)
	build_plane(poly, Vec3(-size, 0, 0), Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 1, 0), size, size, texture_scale, segments_z, segments_y)
end

do
	local function sphere_tangent(normal)
		local tangent = Vec3(normal.z, 0, -normal.x)

		if tangent:GetLength() <= 0.0001 then tangent = Vec3(1, 0, 0) end

		tangent = tangent:GetNormalized()
		return {x = tangent.x, y = tangent.y, z = tangent.z, w = -1}
	end

	-- a UV sphere for Y up, counter clockwise winding seen from outside
	function shapes.BuildSphere(poly, radius, segments, rings, texture_scale)
		radius = radius or 1
		segments = segments or 32
		rings = rings or 16
		texture_scale = texture_scale or 1

		for ring = 0, rings - 1 do
			local theta1 = (ring / rings) * math.pi
			local theta2 = ((ring + 1) / rings) * math.pi

			for seg = 0, segments - 1 do
				local phi1 = (seg / segments) * 2 * math.pi
				local phi2 = ((seg + 1) / segments) * 2 * math.pi
				local x1 = radius * math.sin(theta1) * math.sin(phi1)
				local y1 = radius * math.cos(theta1)
				local z1 = radius * math.sin(theta1) * math.cos(phi1)
				local x2 = radius * math.sin(theta1) * math.sin(phi2)
				local y2 = radius * math.cos(theta1)
				local z2 = radius * math.sin(theta1) * math.cos(phi2)
				local x3 = radius * math.sin(theta2) * math.sin(phi2)
				local y3 = radius * math.cos(theta2)
				local z3 = radius * math.sin(theta2) * math.cos(phi2)
				local x4 = radius * math.sin(theta2) * math.sin(phi1)
				local y4 = radius * math.cos(theta2)
				local z4 = radius * math.sin(theta2) * math.cos(phi1)
				local u1 = (seg / segments) * texture_scale
				local u2 = ((seg + 1) / segments) * texture_scale
				local v1 = (ring / rings) * texture_scale
				local v2 = ((ring + 1) / rings) * texture_scale
				local n1 = Vec3(x1, y1, z1):GetNormalized()
				local n2 = Vec3(x2, y2, z2):GetNormalized()
				local n3 = Vec3(x3, y3, z3):GetNormalized()
				local n4 = Vec3(x4, y4, z4):GetNormalized()
				local t1 = sphere_tangent(n1)
				local t2 = sphere_tangent(n2)
				local t3 = sphere_tangent(n3)
				local t4 = sphere_tangent(n4)

				-- the poles would give degenerate triangles
				if ring > 0 then
					poly:AddVertex{pos = Vec3(x1, y1, z1), uv = Vec2(u1, v1), normal = n1, tangent = t1}
					poly:AddVertex{pos = Vec3(x2, y2, z2), uv = Vec2(u2, v1), normal = n2, tangent = t2}
					poly:AddVertex{pos = Vec3(x3, y3, z3), uv = Vec2(u2, v2), normal = n3, tangent = t3}
				end

				if ring < rings - 1 then
					poly:AddVertex{pos = Vec3(x1, y1, z1), uv = Vec2(u1, v1), normal = n1, tangent = t1}
					poly:AddVertex{pos = Vec3(x3, y3, z3), uv = Vec2(u2, v2), normal = n3, tangent = t3}
					poly:AddVertex{pos = Vec3(x4, y4, z4), uv = Vec2(u1, v2), normal = n4, tangent = t4}
				end
			end
		end
	end
end

do
	local function get_color(tex, x, y, pow)
		local r, g, b, a = tex:GetRawPixelColor(x, y)
		return (((r + g + b + a) / 4) / 255) ^ pow
	end

	function shapes.BuildHeightmap(poly, tex, size, res, uv_scale, height, pow)
		size = size or Vec2(1024, 1024)
		res = res or Vec2(128, 128)
		height = height or -64
		pow = pow or 1
		local s = size / res
		local s2 = s / 2
		local pixel_advance = (Vec2(1, 1) / res) * tex:GetSize()
		local offset = -Vec3(size.x, height, size.y) / 2

		local function add(x, y, z, u, v)
			poly:AddVertex{pos = Vec3(x, y, z) + offset, uv = Vec2(u, v) * uv_scale}
		end

		for x = 0, res.x - 1 do
			local x2 = (x / res.x) * tex:GetSize().x

			for y = 0, res.y - 1 do
				local y2 = (y / res.y) * tex:GetSize().y
				local z3 = get_color(tex, x2, y2, pow) * height
				local z4 = get_color(tex, x2 + pixel_advance.x, y2, pow) * height
				local z1 = get_color(tex, x2, y2 + pixel_advance.y, pow) * height
				local z2 = get_color(tex, x2 + pixel_advance.x, y2 + pixel_advance.y, pow) * height
				local z5 = (z1 + z2 + z3 + z4) / 4
				local wx = x * s.x
				local wz = y * s.y
				add(wx, z1, wz + s.y, x / res.x, (y + 1) / res.y)
				add(wx + s2.x, z5, wz + s2.y, (x + 0.5) / res.x, (y + 0.5) / res.y)
				add(wx + s.x, z2, wz + s.y, (x + 1) / res.x, (y + 1) / res.y)
				add(wx, z1, wz + s.y, x / res.x, (y + 1) / res.y)
				add(wx, z3, wz, x / res.x, y / res.y)
				add(wx + s2.x, z5, wz + s2.y, (x + 0.5) / res.x, (y + 0.5) / res.y)
				add(wx, z3, wz, x / res.x, y / res.y)
				add(wx + s.x, z4, wz, (x + 1) / res.x, y / res.y)
				add(wx + s2.x, z5, wz + s2.y, (x + 0.5) / res.x, (y + 0.5) / res.y)
				add(wx + s2.x, z5, wz + s2.y, (x + 0.5) / res.x, (y + 0.5) / res.y)
				add(wx + s.x, z4, wz, (x + 1) / res.x, y / res.y)
				add(wx + s.x, z2, wz + s.y, (x + 1) / res.x, (y + 1) / res.y)
			end
		end
	end
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

	if RENDER_3D then
		ent:AddComponent("visual")
		polygon:Upload()
		local primitive_entity = Entity.New{Name = (ent.Name or "shape") .. "_primitive", Parent = ent}
		primitive_entity:AddComponent("transform")
		local visual_primitive = primitive_entity:AddComponent("visual_primitive")
		visual_primitive:SetPolygon3D(polygon)
		visual_primitive:SetMaterial(material)
		ent.visual:BuildAABB()
	end

	return material
end

local function create_model_asset_primitives(model_asset, asset_options)
	if type(model_asset) ~= "table" or type(model_asset.create_primitives) ~= "function" then
		error("model asset must return a descriptor with create_primitives()", 2)
	end

	local primitives = model_asset.create_primitives(asset_options or {})
	assert(
		type(primitives) == "table",
		"model asset create_primitives() must return a table"
	)
	return primitives
end

local function add_model_asset(ent, path, material, asset_options)
	local entry = assets.GetModel(path)
	assert(entry and entry.value, ("failed to load model asset %q"):format(path))
	local shared_material = shapes.Material(material)

	if RENDER_3D then ent:AddComponent("visual") end

	for index, primitive in ipairs(create_model_asset_primitives(entry.value, asset_options)) do
		local polygon = primitive.mesh or primitive.polygon3d or primitive
		local primitive_material = primitive.material ~= nil and primitive.material or shared_material
		local primitive_entity = Entity.New{
			Name = (ent.Name or "shape") .. "_primitive_" .. index,
			Parent = ent,
		}
		primitive_entity:AddComponent("transform")

		if primitive.position then
			primitive_entity.transform:SetPosition(primitive.position)
		end

		if primitive.rotation then
			primitive_entity.transform:SetRotation(primitive.rotation)
		end

		if primitive.scale then
			primitive_entity.transform:SetScale(primitive.scale)
		end

		if RENDER_3D then
			local visual_primitive = primitive_entity:AddComponent("visual_primitive")
			visual_primitive:SetPolygon3D(polygon)
			visual_primitive:SetMaterial(shapes.Material(primitive_material))
		end
	end

	if RENDER_3D then ent.visual:BuildAABB() end

	return shared_material
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

	local rigid_body_config = get(config, "RigidBody")

	if rigid_body_config == false then return nil end

	local rigid_body = copy_table(rigid_body_config)

	if shape ~= nil and rigid_body.Shape == nil then rigid_body.Shape = shape end

	if next(rigid_body) == nil then return nil end

	return ent:AddComponent("rigid_body", rigid_body)
end

function shapes.Box(config)
	config = config or {}
	local size = get(config, "Size") or Vec3(1, 1, 1)
	local ent = create_entity(config)
	local material = add_model_asset(
		ent,
		BOX_MODEL_PATH,
		get(config, "Material"),
		{
			size = size,
			subdivisions = get(config, "Subdivisions") or get(config, "Segments"),
		}
	)
	local body = add_rigid_body(ent, config, resolve_body_shape(config, box_shape, size))
	return ent, body, material
end

function shapes.Sphere(config)
	config = config or {}
	local radius = get(config, "Radius") or 0.5
	local ent = create_entity(config)
	local material = add_model_asset(ent, SPHERE_MODEL_PATH, get(config, "Material"), {radius = radius})
	local body = add_rigid_body(ent, config, resolve_body_shape(config, sphere_shape, radius))
	return ent, body, material
end

function shapes.Cone(config)
	config = config or {}
	local radius = get(config, "Radius") or 0.5
	local height = get(config, "Height") or 1
	local ent = create_entity(config)
	local material = add_model_asset(
		ent,
		CONE_MODEL_PATH,
		get(config, "Material"),
		{
			radius = radius,
			height = height,
		}
	)
	return ent, nil, material
end

function shapes.Capsule(config)
	config = config or {}
	local radius = get(config, "Radius") or 0.5
	local height = get(config, "Height") or radius * 2
	local ent = create_entity(config)
	local material = add_model_asset(
		ent,
		CAPSULE_MODEL_PATH,
		get(config, "Material"),
		{
			radius = radius,
			height = math.max(height, radius * 2),
		}
	)
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
