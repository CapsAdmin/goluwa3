local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local assets = import("goluwa/assets.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local sphere_shape = SphereShape.New
local box_shape = BoxShape.New
local capsule_shape = CapsuleShape.New
local BOX_MODEL_PATH = "models/box.lua"
local SPHERE_MODEL_PATH = "models/sphere.lua"
local CAPSULE_MODEL_PATH = "models/capsule.lua"
local convex_shape = ConvexShape.New
local ORIGIN = Vec3(70, 0, -8)
local TOTAL_BODIES = 50
local GRID_COLUMNS = 10
local GRID_ROWS = 5
local GRID_SPACING_X = 3.3
local GRID_SPACING_Z = 3.3
local SPAWN_HEIGHT = 18
local TYPE_SEQUENCE = {"sphere", "box", "capsule", "convex"}
local MATERIALS = {}

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

local function add_asset_model(ent, path, material, options)
	local entry = assets.GetModel(path)
	assert(
		entry and entry.value and entry.value.create_primitives,
		("failed to load model asset %q"):format(path)
	)
	ent:AddComponent("visual")

	for index, primitive in ipairs(entry.value.create_primitives(options or {})) do
		local primitive_entity = Entity.New{
			Name = (ent.Name or "perf_test") .. "_primitive_" .. index,
			Parent = ent,
		}
		primitive_entity:AddComponent("transform")
		local visual_primitive = primitive_entity:AddComponent("visual_primitive")
		visual_primitive:SetPolygon3D(primitive.mesh or primitive.polygon3d or primitive)
		visual_primitive:SetMaterial(primitive.material or material)
	end

	ent.visual:BuildAABB()
	return ent
end

local function add_cube_model(ent, size, material)
	return add_asset_model(ent, BOX_MODEL_PATH, material, {size = size})
end

local function add_sphere_model(ent, radius, material)
	return add_asset_model(ent, SPHERE_MODEL_PATH, material, {radius = radius, segments = 16, rings = 12})
end

local function add_capsule_model(ent, radius, height, material)
	return add_asset_model(
		ent,
		CAPSULE_MODEL_PATH,
		material,
		{
			radius = radius,
			height = math.max(height, radius * 2),
			segments = 16,
			rings = 8,
		}
	)
end

local function create_dynamic_body_entity(name, position, rotation)
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetRotation(rotation or make_rotation())
	return ent
end

local function add_common_body(ent, body_data)
	ent:AddComponent("rigid_body", body_data)
	return ent
end

local function spawn_dynamic_sphere(position, radius, material, rotation, options)
	options = options or {}
	local ent = create_dynamic_body_entity(options.Name or "mixed_shape_desert_sphere", position, rotation)
	add_sphere_model(ent, radius, material)
	return add_common_body(
		ent,
		{
			Shape = sphere_shape(radius),
			Radius = radius,
			Mass = options.Mass,
			AutomaticMass = options.AutomaticMass,
			LinearDamping = options.LinearDamping or 0.04,
			AngularDamping = options.AngularDamping or 0.08,
			AirLinearDamping = options.AirLinearDamping or 0.02,
			AirAngularDamping = options.AirAngularDamping or 0.04,
			Friction = options.Friction or 0.48,
			Restitution = options.Restitution or 0.02,
			MaxLinearSpeed = options.MaxLinearSpeed or 1000,
			MaxAngularSpeed = options.MaxAngularSpeed or 1000,
		}
	)
end

local function spawn_dynamic_box(position, size, material, rotation, options)
	options = options or {}
	local ent = create_dynamic_body_entity(options.Name or "mixed_shape_desert_box", position, rotation)
	add_cube_model(ent, size, material)
	return add_common_body(
		ent,
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
			MaxLinearSpeed = options.MaxLinearSpeed or 1000,
			MaxAngularSpeed = options.MaxAngularSpeed or 1000,
		}
	)
end

local function spawn_dynamic_capsule(position, radius, height, material, rotation, options)
	options = options or {}
	local ent = create_dynamic_body_entity(options.Name or "mixed_shape_desert_capsule", position, rotation)
	add_capsule_model(ent, radius, height, material)
	return add_common_body(
		ent,
		{
			Shape = capsule_shape(radius, height),
			Radius = radius,
			Height = height,
			Mass = options.Mass,
			AutomaticMass = options.AutomaticMass,
			LinearDamping = options.LinearDamping or 0.04,
			AngularDamping = options.AngularDamping or 0.08,
			AirLinearDamping = options.AirLinearDamping or 0.02,
			AirAngularDamping = options.AirAngularDamping or 0.04,
			Friction = options.Friction or 0.5,
			Restitution = options.Restitution or 0,
			MaxLinearSpeed = options.MaxLinearSpeed or 1000,
			MaxAngularSpeed = options.MaxAngularSpeed or 1000,
		}
	)
end

local function spawn_dynamic_convex_box(position, size, material, rotation, options)
	options = options or {}
	local ent = create_dynamic_body_entity(options.Name or "mixed_shape_desert_convex_box", position, rotation)
	add_cube_model(ent, size, material)
	return add_common_body(
		ent,
		{
			Shape = convex_shape(),
			Mass = options.Mass,
			AutomaticMass = options.AutomaticMass,
			LinearDamping = options.LinearDamping or 0.05,
			AngularDamping = options.AngularDamping or 0.12,
			AirLinearDamping = options.AirLinearDamping or 0.02,
			AirAngularDamping = options.AirAngularDamping or 0.05,
			Friction = options.Friction or 0.68,
			Restitution = options.Restitution or 0,
			MaxLinearSpeed = options.MaxLinearSpeed or 1000,
			MaxAngularSpeed = options.MaxAngularSpeed or 1000,
		}
	)
end

local function get_material(index)
	return MATERIALS[((index - 1) % #MATERIALS) + 1]
end

local function get_grid_position(index)
	local column = (index - 1) % GRID_COLUMNS
	local row = math.floor((index - 1) / GRID_COLUMNS)
	local x = (column - (GRID_COLUMNS - 1) * 0.5) * GRID_SPACING_X
	local z = (row - (GRID_ROWS - 1) * 0.5) * GRID_SPACING_Z
	local y = SPAWN_HEIGHT + row * 1.25 + (column % 2) * 0.35
	return ORIGIN + Vec3(x, y, z)
end

local function get_grid_rotation(index)
	local pitch = ((index * 11) % 18) - 9
	local yaw = (index * 23) % 360
	local roll = ((index * 7) % 20) - 10
	return make_rotation(pitch, yaw, roll)
end

local function spawn_shape_for_index(index)
	local shape_type = TYPE_SEQUENCE[((index - 1) % #TYPE_SEQUENCE) + 1]
	local position = get_grid_position(index)
	local rotation = get_grid_rotation(index)
	local material = get_material(index)
	local mass = 0.75 + (index % 5) * 0.2
	local options = {
		Name = string.format("mixed_shape_desert_%s_%02d", shape_type, index),
		Mass = mass,
		AutomaticMass = false,
	}

	if shape_type == "sphere" then
		local radius = 0.35 + (index % 4) * 0.12
		return spawn_dynamic_sphere(position, radius, material, rotation, options)
	end

	if shape_type == "box" then
		local sx = 0.65 + (index % 3) * 0.22
		local sy = 0.55 + ((index + 1) % 4) * 0.18
		local sz = 0.65 + ((index + 2) % 3) * 0.2
		return spawn_dynamic_box(position, Vec3(sx, sy, sz), material, rotation, options)
	end

	if shape_type == "capsule" then
		local radius = 0.28 + (index % 3) * 0.08
		local height = math.max(radius * 2, 1.1 + ((index + 2) % 4) * 0.35)
		return spawn_dynamic_capsule(position, radius, height, material, rotation, options)
	end

	local sx = 0.7 + (index % 4) * 0.18
	local sy = 0.6 + ((index + 1) % 3) * 0.2
	local sz = 0.7 + ((index + 2) % 4) * 0.16
	return spawn_dynamic_convex_box(position, Vec3(sx, sy, sz), material, rotation, options)
end

MATERIALS = {
	make_material(Color(0.92, 0.38, 0.22, 1), 0.42, 0),
	make_material(Color(0.21, 0.73, 0.97, 1), 0.2, 0.08),
	make_material(Color(0.76, 0.80, 0.86, 1), 0.24, 1),
	make_material(Color(0.49, 0.31, 0.16, 1), 0.88, 0),
	make_material(Color(0.56, 0.83, 0.38, 1), 0.6, 0),
}

for i = 1, TOTAL_BODIES do
	spawn_shape_for_index(i)
end
