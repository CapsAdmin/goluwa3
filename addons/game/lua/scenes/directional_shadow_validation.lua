local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local shapes = import("lua/shapes.lua")
local ROOT_KEY = "directional_shadow_validation_scene"
local VALIDATION_MODE = rawget(_G, "DIRECTIONAL_SHADOW_VALIDATION_MODE") or "perspective"
local BOX_MODEL_PATH = "models/box.lua"
local SPHERE_MODEL_PATH = "models/sphere.lua"
local CAPSULE_MODEL_PATH = "models/capsule.lua"

local function make_rotation(pitch, yaw, roll)
	return Quat():SetAngles(Deg3(pitch or 0, yaw or 0, roll or 0))
end

local function create_entity(parent, name, position, rotation)
	local ent = Entity.New{
		Parent = parent,
		Name = name,
	}
	ent:AddComponent("transform")
	ent.transform:SetPosition(position or Vec3())
	ent.transform:SetRotation(rotation or make_rotation())
	return ent
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
			Name = (ent.Name or "directional_shadow_validation") .. "_primitive_" .. index,
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

		local visual_primitive = primitive_entity:AddComponent("visual_primitive")
		visual_primitive:SetPolygon3D(primitive.mesh or primitive.polygon3d or primitive)
		visual_primitive:SetMaterial(primitive.material or material)
	end

	ent.visual:BuildAABB()
	return ent
end

local function spawn_box(parent, name, position, size, material, rotation)
	local ent = create_entity(parent, name, position, rotation)
	return add_asset_model(ent, BOX_MODEL_PATH, material, {size = size})
end

local function spawn_sphere(parent, name, position, radius, material)
	local ent = create_entity(parent, name, position)
	return add_asset_model(ent, SPHERE_MODEL_PATH, material, {radius = radius, segments = 20, rings = 12})
end

local function spawn_capsule(parent, name, position, radius, height, material, rotation)
	local ent = create_entity(parent, name, position, rotation)
	return add_asset_model(
		ent,
		CAPSULE_MODEL_PATH,
		material,
		{
			radius = radius,
			height = math.max(height, radius * 2),
			segments = 18,
			rings = 8,
		}
	)
end

local function frame_camera(position, target, fov)
	local camera = render3d.GetCamera and render3d.GetCamera()

	if not camera then return end

	camera:SetPosition(position)
	local to_target = (target - position)
	local flat = Vec3(to_target.x, 0, to_target.z)
	local yaw = math.deg(math.atan2(-flat.x, -flat.z))
	local pitch = math.deg(math.atan2(to_target.y, flat:GetLength()))
	camera:SetAngles(Deg3(pitch, yaw, 0))
	camera:SetFOV(math.rad(fov or 55))
	camera:SetNearZ(0.1)
	camera:SetFarZ(400)
end

local function spawn_directional_light(parent, name, position, pitch, yaw, shadow_config)
	local light = create_entity(parent, name, position, make_rotation(pitch, yaw, 0))
	local component = light:AddComponent("light_directional")
	component:SetColor(Color(1.0, 0.95, 0.85, 1.0))
	component:SetIntensity(30.0)
	component:SetRange(shadow_config.range)
	ShadowMap.New{
		mode = "directional",
		light = light,
		size = shadow_config.size,
		max_shadow_distance = shadow_config.range,
		ortho_size = shadow_config.ortho_size,
		near_plane = shadow_config.near_plane,
		far_plane = shadow_config.range,
		directional_projection_mode = shadow_config.projection,
		perspective_fov = shadow_config.perspective_fov,
	}
	return light
end

local function spawn_point_light(parent, name, position, color, intensity, range)
	local light = create_entity(parent, name, position)
	local component = light:AddComponent("light_point")
	component:SetColor(color)
	component:SetIntensity(intensity)
	component:SetRange(range)
	-- keep the low-res light occlusion mask out of this validation so the
	-- shadow map path can be tested in isolation
	component.OcclusionMap = false
	ShadowMap.New{
		mode = "point",
		light = light,
		size = Vec2() + 1024,
		near_plane = 0.05,
		far_plane = range,
	}
	return light
end

local root = Entity.World:Ensure{
	Key = ROOT_KEY,
	Name = ROOT_KEY,
}
root:RemoveChildren()

for _, light in ipairs(render3d.GetLights()) do
	if light.Owner ~= root then
		for _, shadow_map in ipairs(ShadowMap.GetActiveMaps()) do
			if shadow_map.light == light.Owner then shadow_map:SetEnabled(false) end
		end

		light:SetIntensity(0)
	end
end

local floor_material = shapes.Material{Color = Color(0.36, 0.36, 0.38, 1), Roughness = 0.9, Metallic = 0}
local wall_material = shapes.Material{Color = Color(0.52, 0.52, 0.55, 1), Roughness = 0.85, Metallic = 0.01}
local warm_material = shapes.Material{Color = Color(0.72, 0.44, 0.26, 1), Roughness = 0.6, Metallic = 0.02}
local cool_material = shapes.Material{Color = Color(0.26, 0.48, 0.74, 1), Roughness = 0.5, Metallic = 0.05}
local accent_material = shapes.Material{Color = Color(0.30, 0.72, 0.60, 1), Roughness = 0.4, Metallic = 0.03}
local metal_material = shapes.Material{Color = Color(0.78, 0.80, 0.84, 1), Roughness = 0.24, Metallic = 1.0}
spawn_box(root, "floor", Vec3(0, -1, 8), Vec3(90, 2, 90), floor_material)

if VALIDATION_MODE == "point" then
	local point_position = Vec3(0, 11, 16)
	spawn_point_light(root, "point_light", point_position, Color(1.0, 0.72, 0.44, 1.0), 30, 45)
	spawn_box(
		root,
		"point_occluder_1",
		point_position + Vec3(7, -4.5, 3),
		Vec3(2.6, 7.0, 2.6),
		warm_material
	)
	spawn_box(
		root,
		"point_occluder_2",
		point_position + Vec3(-6.5, -4.0, 5),
		Vec3(3.4, 6.0, 3.4),
		cool_material,
		make_rotation(0, 18, 0)
	)
	spawn_box(
		root,
		"point_occluder_3",
		point_position + Vec3(4.5, -3.5, -7),
		Vec3(4.4, 5.0, 2.2),
		accent_material,
		make_rotation(0, -22, 0)
	)
	spawn_box(
		root,
		"point_occluder_4",
		point_position + Vec3(-5.5, -5.0, -6),
		Vec3(2.4, 6.5, 4.4),
		cool_material,
		make_rotation(10, 8, 0)
	)
	spawn_sphere(
		root,
		"point_occluder_sphere",
		point_position + Vec3(2.5, -6.2, 6.5),
		1.6,
		metal_material
	)
	spawn_capsule(
		root,
		"point_occluder_capsule",
		point_position + Vec3(-8.5, -5.5, -1.5),
		1.0,
		5.4,
		warm_material,
		make_rotation(0, 40, 0)
	)
	spawn_box(
		root,
		"point_plinth",
		point_position + Vec3(0, -4.5, 0),
		Vec3(3.0, 3.0, 3.0),
		metal_material
	)
	spawn_box(root, "point_wall_back", Vec3(0, 6, -24), Vec3(70, 14, 2), wall_material)
	spawn_box(root, "point_wall_left", Vec3(-34, 6, 8), Vec3(2, 14, 70), wall_material)
	frame_camera(Vec3(30, 22, 52), Vec3(0, 0, 16), 55)
else
	-- Directional light (flashlight) shining down at ~20 deg tilt toward -z
	local light_position = Vec3(0, 22, 30)
	local light_pitch = -70
	local light_yaw = 0
	local range = 60
	local shadow_config = {
		range = range,
		size = Vec2() + 1024,
		near_plane = 0.5,
	}

	if VALIDATION_MODE == "perspective" then
		shadow_config.projection = "perspective"
		shadow_config.perspective_fov = math.rad(100)
	else
		shadow_config.projection = "orthographic"
		shadow_config.ortho_size = 20
	end

	spawn_directional_light(root, "directional_light", light_position, light_pitch, light_yaw, shadow_config)
	-- occluders standing on the floor. They are placed at very different
	-- distances from the light (the row is ~26 units away, the near pair is
	-- ~11) so bias scaling with distance is visible in perspective mode
	local row_z = 20
	local row_x = {-15, -9, -3, 3, 9, 15}
	local row_sizes = {1.6, 2.2, 2.8, 3.4, 4.0, 4.6}

	for i = 1, #row_x do
		local size = row_sizes[i]
		local material = i % 2 == 1 and warm_material or cool_material
		spawn_box(
			root,
			("row_box_%d"):format(i),
			Vec3(row_x[i], size * 0.5, row_z),
			Vec3(size, size, size),
			material
		)
	end

	spawn_box(root, "near_box_a", Vec3(-6, 1.1, 30), Vec3(2.2, 2.2, 2.2), cool_material)
	spawn_box(
		root,
		"near_box_b",
		Vec3(4, 1.4, 29),
		Vec3(2.8, 2.8, 2.8),
		warm_material,
		make_rotation(0, 15, 0)
	)
	spawn_sphere(root, "mid_sphere", Vec3(6, 2.0, 13), 2.0, metal_material)
	spawn_capsule(
		root,
		"mid_capsule",
		Vec3(-7, 2.4, 11),
		1.2,
		5.6,
		accent_material,
		make_rotation(0, 24, 0)
	)
	spawn_box(
		root,
		"tilted_box",
		Vec3(11, 1.0, 12),
		Vec3(3.0, 1.2, 3.0),
		metal_material,
		make_rotation(16, -12, 0)
	)
	spawn_box(
		root,
		"far_box",
		Vec3(-12, 1.5, 6),
		Vec3(3.0, 3.0, 3.0),
		warm_material,
		make_rotation(0, -20, 0)
	)
	spawn_box(root, "rear_wall", Vec3(0, 5, -30), Vec3(70, 10, 2), wall_material)
	frame_camera(Vec3(28, 13, 52), Vec3(0, 1, 17), 55)
end
