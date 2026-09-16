local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")
local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local shapes = import("lua/shapes.lua")
local ROOT_KEY = "point_light_faces_validation_scene"
local BOX_MODEL_PATH = "models/box.lua"
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
			Name = (ent.Name or "point_light_faces_validation") .. "_primitive_" .. index,
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

local function spawn_point_light(parent, name, position, color, intensity, range)
	local ent = create_entity(parent, name, position)
	local light = ent:AddComponent("light_point")
	light:SetColor(color)
	light:SetIntensity(intensity)
	light:SetRange(range)
	light:SetOcclusionMap(false)
	local shadow = ent:AddComponent("shadow_map_point")
	shadow:SetSize(Vec2() + 1024)
	shadow:SetNearPlane(0.05)
	shadow:SetFarPlane(range)
	return component
end

local function frame_camera()
	local camera = render3d.GetCamera()
	camera:SetPosition(Vec3(23.790546, 28.174023, 22.774307))
	camera:SetRotation(Quat(-0.134459, 0.358074, 0.052192, 0.922486))
	camera:SetFOV(math.rad(68))

	Screenshot(
		function(texture)
			texture:Save("tmp/point_shadows.png")
			print("saved to tmp/point_shadows.png")
			system.ShutDown(0)
		end,
		{camera = camera, update_events = 50}
	)
end

local function spawn_room(parent, center, half_size, floor_material, wall_material, ceiling_material)
	local wall_thickness = 2.0
	spawn_box(
		parent,
		"room_floor",
		center + Vec3(0, -half_size.y, 0),
		Vec3(half_size.x * 2, wall_thickness, half_size.z * 2),
		floor_material
	)
	spawn_box(
		parent,
		"room_ceiling",
		center + Vec3(0, half_size.y, 0),
		Vec3(half_size.x * 2, wall_thickness, half_size.z * 2),
		ceiling_material
	)
	spawn_box(
		parent,
		"room_wall_pos_x",
		center + Vec3(half_size.x, 0, 0),
		Vec3(wall_thickness, half_size.y * 2, half_size.z * 2),
		wall_material
	)
	spawn_box(
		parent,
		"room_wall_neg_x",
		center + Vec3(-half_size.x, 0, 0),
		Vec3(wall_thickness, half_size.y * 2, half_size.z * 2),
		wall_material
	)
	spawn_box(
		parent,
		"room_wall_pos_z",
		center + Vec3(0, 0, half_size.z),
		Vec3(half_size.x * 2, half_size.y * 2, wall_thickness),
		wall_material
	)
	spawn_box(
		parent,
		"room_wall_neg_z",
		center + Vec3(0, 0, -half_size.z),
		Vec3(half_size.x * 2, half_size.y * 2, wall_thickness),
		wall_material
	)
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

local floor_material = shapes.Material{Color = Color(0.18, 0.19, 0.21, 1), Roughness = 0.95, Metallic = 0}
local wall_material = shapes.Material{Color = Color(0.58, 0.59, 0.62, 1), Roughness = 0.86, Metallic = 0.01}
local ceiling_material = shapes.Material{Color = Color(0.50, 0.50, 0.52, 1), Roughness = 0.88, Metallic = 0.01}
local occluder_x_material = shapes.Material{Color = Color(0.66, 0.38, 0.30, 1), Roughness = 0.60, Metallic = 0.03}
local occluder_y_material = shapes.Material{Color = Color(0.28, 0.56, 0.72, 1), Roughness = 0.52, Metallic = 0.05}
local occluder_z_material = shapes.Material{Color = Color(0.34, 0.72, 0.54, 1), Roughness = 0.48, Metallic = 0.04}
local room_center = Vec3(0, 12, 0)
local room_half_size = Vec3(28, 12, 28)
local light_position = room_center
spawn_room(
	root,
	room_center,
	room_half_size,
	floor_material,
	wall_material,
	ceiling_material
)
spawn_point_light(
	root,
	"point_light_faces_light",
	light_position,
	Color(1.0, 0.72, 0.44, 1.0),
	60,
	200
)
spawn_box(
	root,
	"occluder_pos_x",
	light_position + Vec3(10, 0, 0),
	Vec3(3.2, 9.5, 8.5),
	occluder_x_material
)
spawn_box(
	root,
	"occluder_neg_x",
	light_position + Vec3(-10, 0, 0),
	Vec3(3.2, 7.5, 10.0),
	occluder_x_material,
	make_rotation(0, 10, 0)
)
spawn_box(
	root,
	"occluder_pos_z",
	light_position + Vec3(0, 0, 10),
	Vec3(9.0, 8.2, 3.0),
	occluder_z_material,
	make_rotation(0, 14, 0)
)
spawn_box(
	root,
	"occluder_neg_z",
	light_position + Vec3(0, 0, -10),
	Vec3(7.0, 10.0, 3.2),
	occluder_z_material,
	make_rotation(0, -18, 0)
)
spawn_box(
	root,
	"occluder_pos_y",
	light_position + Vec3(0, 8.5, 0),
	Vec3(8.0, 2.0, 8.0),
	occluder_y_material,
	make_rotation(18, 12, 0)
)
spawn_box(
	root,
	"occluder_neg_y",
	light_position + Vec3(0, -8.5, 0),
	Vec3(7.0, 2.6, 7.0),
	occluder_y_material,
	make_rotation(-12, -16, 0)
)
spawn_box(
	root,
	"support_column_near",
	room_center + Vec3(-16, -4, 14),
	Vec3(3.0, 16.0, 3.0),
	wall_material
)
spawn_box(
	root,
	"support_column_far",
	room_center + Vec3(15, -3, -15),
	Vec3(3.0, 18.0, 3.0),
	wall_material
)
spawn_box(
	root,
	"rear_plinth",
	room_center + Vec3(18, -8.5, 16),
	Vec3(6.0, 5.0, 6.0),
	floor_material
)--frame_camera()
