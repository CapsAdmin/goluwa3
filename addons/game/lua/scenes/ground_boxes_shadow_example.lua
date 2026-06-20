local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("lua/shapes.lua")
local ROOT_KEY = "ground_boxes_shadow_example_scene"
local BOX_MODEL_PATH = "models/box.lua"
local SCENE_OFFSET = Vec3(0, 0, 0)
local SHARED_BOX_PRIMITIVE = nil

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

local function get_shared_box_primitive()
	local entry = assets.GetModel(BOX_MODEL_PATH)
	assert(
		entry and entry.value and entry.value.create_primitives,
		("failed to load model asset %q"):format(BOX_MODEL_PATH)
	)
	local primitives = entry.value.create_primitives()
	assert(primitives[1], "box model did not return any primitives")
	return primitives[1]
end

local function add_scaled_box(parent, name, position, size, material, rotation)
	local ent = create_entity(parent, name, position, rotation)
	ent:AddComponent("visual")
	ent.visual:SetUseOcclusionCulling(false)
	local primitive = SHARED_BOX_PRIMITIVE
	local primitive_entity = ent.visual:CreatePrimitiveEntity(
		primitive.mesh or primitive.polygon3d or primitive,
		material or primitive.material,
		name .. "_primitive"
	)
	primitive_entity.transform:SetScale(size)
	ent.visual:BuildAABB()
	return ent
end

local function frame_camera()
	local camera = render3d.GetCamera and render3d.GetCamera()

	if not camera then return end

	camera:SetPosition(Vec3(0, 36, 148) + SCENE_OFFSET)
	camera:SetAngles(Deg3(-14, 180, 0))
	camera:SetFOV(math.rad(68))
	camera:SetNearZ(0.05)
	camera:SetFarZ(700)
end

local function disable_non_sun_lights(root)
	for _, light in ipairs(render3d.GetLights()) do
		if light.Owner ~= root and light.LightType ~= "sun" then
			if light:GetCastShadows() then light:SetCastShadows(false) end

			light:SetIntensity(0)
		end
	end
end

local function spawn_ground(root, material)
	add_scaled_box(root, "ground_plane", Vec3(0, -1, 0), Vec3(320, 2, 320), material)
	add_scaled_box(
		root,
		"shadow_backstop",
		Vec3(0, 18, -132),
		Vec3(180, 36, 4),
		material,
		make_rotation(0, 0, 0)
	)
end

local function spawn_box_rows(root, palette)
	local columns = {
		{size = Vec3(0.18, 0.24, 0.18), material = palette.tiny, pitch = 0, yaw = 8},
		{size = Vec3(0.35, 0.55, 0.35), material = palette.small, pitch = 0, yaw = -10},
		{size = Vec3(0.75, 1.2, 0.75), material = palette.small, pitch = 0, yaw = 14},
		{size = Vec3(1.5, 2.8, 1.5), material = palette.medium, pitch = 0, yaw = -18},
		{size = Vec3(3.5, 5.0, 3.5), material = palette.medium, pitch = 0, yaw = 12},
		{size = Vec3(7.0, 9.0, 7.0), material = palette.large, pitch = 0, yaw = -8},
		{size = Vec3(13.0, 18.0, 13.0), material = palette.large, pitch = 0, yaw = 6},
	}
	local row_count = 5
	local spacing_x = 28
	local spacing_z = 30
	local origin_x = -((#columns - 1) * spacing_x) * 0.5
	local origin_z = -((row_count - 1) * spacing_z) * 0.5

	for row = 1, row_count do
		for column = 1, #columns do
			local spec = columns[column]
			local size = spec.size
			local x = origin_x + (column - 1) * spacing_x
			local z = origin_z + (row - 1) * spacing_z
			local height_offset = size.y * 0.5
			local yaw = spec.yaw + (row - 3) * 7
			local pitch = spec.pitch + (column % 2 == 0 and 0 or -3)
			local roll = row % 2 == 0 and 0 or 2
			add_scaled_box(
				root,
				("box_r%d_c%d"):format(row, column),
				Vec3(x, height_offset, z),
				size,
				spec.material,
				make_rotation(pitch, yaw, roll)
			)
		end
	end

	add_scaled_box(
		root,
		"wide_low_box",
		Vec3(-92, 2, 68),
		Vec3(18, 4, 42),
		palette.accent,
		make_rotation(0, 24, 0)
	)
	add_scaled_box(
		root,
		"tall_thin_box",
		Vec3(96, 16, 24),
		Vec3(5, 32, 5),
		palette.accent,
		make_rotation(0, -18, 0)
	)
	add_scaled_box(
		root,
		"hero_box",
		Vec3(0, 20, -86),
		Vec3(22, 40, 22),
		palette.hero,
		make_rotation(0, 18, 0)
	)
end

local root = Entity.World:Ensure{
	Key = ROOT_KEY,
	Name = ROOT_KEY,
}
root:RemoveChildren()
disable_non_sun_lights(root)
local ground_material = shapes.Material{
	Color = Color(0.17, 0.18, 0.20, 1),
	Roughness = 0.96,
	Metallic = 0.01,
}
local tiny_material = shapes.Material{
	Color = Color(0.74, 0.79, 0.84, 1),
	Roughness = 0.90,
	Metallic = 0.02,
}
local small_material = shapes.Material{
	Color = Color(0.49, 0.64, 0.83, 1),
	Roughness = 0.74,
	Metallic = 0.06,
}
local medium_material = shapes.Material{
	Color = Color(0.72, 0.58, 0.34, 1),
	Roughness = 0.62,
	Metallic = 0.05,
}
local large_material = shapes.Material{
	Color = Color(0.69, 0.43, 0.31, 1),
	Roughness = 0.58,
	Metallic = 0.04,
}
local accent_material = shapes.Material{
	Color = Color(0.28, 0.66, 0.55, 1),
	Roughness = 0.48,
	Metallic = 0.08,
}
local hero_material = shapes.Material{
	Color = Color(0.86, 0.88, 0.92, 1),
	Roughness = 0.26,
	Metallic = 0.92,
}
SHARED_BOX_PRIMITIVE = get_shared_box_primitive()
spawn_ground(root, ground_material)
spawn_box_rows(
	root,
	{
		tiny = tiny_material,
		small = small_material,
		medium = medium_material,
		large = large_material,
		accent = accent_material,
		hero = hero_material,
	}
)
frame_camera()
