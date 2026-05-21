local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/ecs/entity.lua")
local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("lua/shapes.lua")
local ROOT_KEY = "local_light_shadows_validation_scene"
local VALIDATION_MODE = rawget(_G, "LOCAL_LIGHT_SHADOWS_VALIDATION_MODE") or "combined"
local BOX_MODEL_PATH = "models/box.lua"
local SPHERE_MODEL_PATH = "models/sphere.lua"
local CAPSULE_MODEL_PATH = "models/capsule.lua"
local SCENE_OFFSET = Vec3(0, 8, 0)

local function make_rotation(pitch, yaw, roll)
	return Quat():SetAngles(Deg3(pitch or 0, yaw or 0, roll or 0))
end

local function create_entity(parent, name, position, rotation)
	local ent = Entity.New{
		Parent = parent,
		Name = name,
	}
	ent:AddComponent("transform")
	ent.transform:SetPosition((position or Vec3()) + SCENE_OFFSET)
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
			Name = (ent.Name or "local_light_shadows_validation") .. "_primitive_" .. index,
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

local function spawn_stage_floor(parent, name, center, size, material)
	spawn_box(
		parent,
		name .. "_floor",
		center + Vec3(0, -1.5, 0),
		Vec3(size.x, 3, size.z),
		material
	)
	spawn_box(
		parent,
		name .. "_lip_back",
		center + Vec3(0, 0.6, -size.z * 0.5),
		Vec3(size.x, 1.2, 1.5),
		material
	)
	spawn_box(
		parent,
		name .. "_lip_left",
		center + Vec3(-size.x * 0.5, 0.6, 0),
		Vec3(1.5, 1.2, size.z),
		material
	)
	spawn_box(
		parent,
		name .. "_lip_right",
		center + Vec3(size.x * 0.5, 0.6, 0),
		Vec3(1.5, 1.2, size.z),
		material
	)
end

local function spawn_point_chamber(parent, name, center, size, shell_material)
	spawn_stage_floor(parent, name, center, size, shell_material)
	spawn_box(
		parent,
		name .. "_wall_back",
		center + Vec3(0, 7, -size.z * 0.5),
		Vec3(size.x, 14, 1.6),
		shell_material
	)
	spawn_box(
		parent,
		name .. "_wall_front",
		center + Vec3(0, 7, size.z * 0.5),
		Vec3(size.x, 14, 1.6),
		shell_material
	)
	spawn_box(
		parent,
		name .. "_wall_left",
		center + Vec3(-size.x * 0.5, 7, 0),
		Vec3(1.6, 14, size.z),
		shell_material
	)
	spawn_box(
		parent,
		name .. "_wall_right",
		center + Vec3(size.x * 0.5, 7, 0),
		Vec3(1.6, 14, size.z),
		shell_material
	)
	spawn_box(
		parent,
		name .. "_roof",
		center + Vec3(0, 14.5, 0),
		Vec3(size.x, 1.4, size.z),
		shell_material
	)
end

local function spawn_directional_light(parent, position)
	local light = create_entity(
		parent,
		"local_shadow_directional",
		position or Vec3(0, 10, 0),
		make_rotation(52, -18, 0)
	)
	local component = light:AddComponent("light")
	component:SetLightType("directional")
	component:SetColor(Color(0.42, 0.72, 1.0, 1.0))
	component:SetIntensity(4.0)
	component:SetRange(42)
	component:SetInnerCone(0.72)
	component:SetOuterCone(0.42)
	component:SetCastShadows{
		size = Vec2() + 2048,
		cascade_count = 1,
		cascade_sizes = {Vec2() + 2048},
		cascade_split_lambda = 1,
		max_shadow_distance = 42,
		ortho_size = 18,
		near_plane = 0.1,
		far_plane = 42,
	}
	return component
end

local function spawn_point_light(parent, name, position, color, intensity, range)
	local light = create_entity(parent, name, position)
	local component = light:AddComponent("light")
	component:SetLightType("point")
	component:SetColor(color)
	component:SetIntensity(intensity)
	component:SetRange(range)
	component:SetCastShadows{
		size = Vec2() + 1024,
		near_plane = 0.05,
		far_plane = range,
	}
	return light
end

local function frame_camera()
	local camera = render3d.GetCamera and render3d.GetCamera()

	if not camera then return end

	camera:SetPosition(Vec3(0, 16, 58) + SCENE_OFFSET)
	camera:SetAngles(Deg3(-10, 180, 0))
	camera:SetFOV(math.rad(70))
	camera:SetNearZ(0.05)
	camera:SetFarZ(320)
end

local root = Entity.World:Ensure{
	Key = ROOT_KEY,
	Name = ROOT_KEY,
}
root:RemoveChildren()

for _, light in ipairs(render3d.GetLights()) do
	if
		light.Owner ~= root and
		(
			light.LightType == "sun" or
			light.LightType == "directional"
		)
	then
		if light.LightType == "sun" then
			if VALIDATION_MODE == "local_directional" then
				if light:GetCastShadows() then light:SetCastShadows(false) end

				light:SetIntensity(0)
			end
		else
			if light:GetCastShadows() then light:SetCastShadows(false) end
		end

		if light.LightType == "directional" then light:SetIntensity(0) end
	end
end

local floor_material = shapes.Material{Color = Color(0.14, 0.15, 0.17, 1), Roughness = 0.94, Metallic = 0}
local wall_material = shapes.Material{Color = Color(0.50, 0.50, 0.54, 1), Roughness = 0.82, Metallic = 0.01}
local warm_material = shapes.Material{Color = Color(0.63, 0.42, 0.28, 1), Roughness = 0.66, Metallic = 0.02}
local cool_material = shapes.Material{Color = Color(0.24, 0.46, 0.70, 1), Roughness = 0.44, Metallic = 0.08}
local metal_material = shapes.Material{Color = Color(0.78, 0.80, 0.84, 1), Roughness = 0.24, Metallic = 1.0}
local accent_material = shapes.Material{Color = Color(0.25, 0.68, 0.62, 1), Roughness = 0.36, Metallic = 0.04}
local directional_center = Vec3(-42, 0, 2)
local warm_center = Vec3(0, 0, -12)
local cool_center = Vec3(48, 0, -12)
local directional_light = spawn_directional_light(root, directional_center + Vec3(0, 12, 4))

if VALIDATION_MODE == "sun" then
	directional_light:SetCastShadows(false)
	directional_light:SetIntensity(0)
end

spawn_point_light(
	root,
	"local_shadow_point_warm",
	warm_center + Vec3(0, 6.8, 0),
	Color(1.0, 0.62, 0.34, 1.0),
	22,
	22
)
spawn_point_light(
	root,
	"local_shadow_point_cool",
	cool_center + Vec3(0, 6.2, -2),
	Color(0.42, 0.72, 1.0, 1.0),
	20,
	20
)
spawn_stage_floor(root, "directional_stage", directional_center, Vec3(30, 0, 28), floor_material)
spawn_box(
	root,
	"directional_stage_tall_block",
	directional_center + Vec3(-4, 6, -3),
	Vec3(7, 12, 7),
	warm_material,
	make_rotation(0, 18, 0)
)
spawn_box(
	root,
	"directional_stage_low_block",
	directional_center + Vec3(8, 2.5, 4),
	Vec3(5, 5, 5),
	cool_material,
	make_rotation(0, -16, 0)
)
spawn_capsule(
	root,
	"directional_stage_capsule",
	directional_center + Vec3(-8, 3.2, 6),
	1.3,
	6.8,
	accent_material,
	make_rotation(0, 26, 0)
)
spawn_sphere(
	root,
	"directional_stage_sphere",
	directional_center + Vec3(3, 2.2, 7),
	2.2,
	metal_material
)
spawn_point_chamber(root, "warm_point_stage", warm_center, Vec3(26, 0, 24), wall_material)
spawn_box(
	root,
	"warm_point_stage_block",
	warm_center + Vec3(0, 4.5, -5),
	Vec3(6, 9, 6),
	warm_material,
	make_rotation(0, 12, 0)
)
spawn_box(
	root,
	"warm_point_stage_plinth",
	warm_center + Vec3(7.5, 1.6, 4),
	Vec3(4.5, 3.2, 4.5),
	metal_material
)
spawn_sphere(
	root,
	"warm_point_stage_sphere",
	warm_center + Vec3(7.5, 5.6, 4),
	1.8,
	accent_material
)
spawn_capsule(
	root,
	"warm_point_stage_capsule",
	warm_center + Vec3(-7, 3.1, 5),
	1.0,
	6.2,
	cool_material,
	make_rotation(0, -20, 0)
)
spawn_point_chamber(root, "cool_point_stage", cool_center, Vec3(26, 0, 24), wall_material)
spawn_box(
	root,
	"cool_point_stage_tower",
	cool_center + Vec3(-6, 6.5, -4),
	Vec3(4.5, 13, 4.5),
	cool_material
)
spawn_box(
	root,
	"cool_point_stage_bridge",
	cool_center + Vec3(1.5, 8.5, 2),
	Vec3(11, 1.5, 3),
	metal_material
)
spawn_sphere(
	root,
	"cool_point_stage_sphere",
	cool_center + Vec3(6.5, 2.0, -6),
	2.0,
	metal_material
)
spawn_capsule(
	root,
	"cool_point_stage_capsule",
	cool_center + Vec3(6.5, 3.0, 5),
	1.1,
	6.0,
	accent_material,
	make_rotation(0, 30, 0)
)
frame_camera()
