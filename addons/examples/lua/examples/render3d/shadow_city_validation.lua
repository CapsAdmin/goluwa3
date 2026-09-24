local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("lua/shapes.lua")
local ROOT_KEY = "shadow_city_validation_scene"
local BOX_MODEL_PATH = "models/box.lua"
local SPHERE_MODEL_PATH = "models/sphere.lua"
local CAPSULE_MODEL_PATH = "models/capsule.lua"
local CITY_CENTER_Z = -110
local SCENE_OFFSET = Vec3(0, 10, 0)

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
			Name = (ent.Name or "shadow_city_validation") .. "_primitive_" .. index,
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

local function spawn_sphere(parent, name, position, radius, material, rotation)
	local ent = create_entity(parent, name, position, rotation)
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

local function build_plane_polygon(width, height)
	local half_width = width * 0.5
	local half_height = height * 0.5
	local poly = Polygon3D.New()
	local normal = Vec3(0, 0, 1)
	poly:AddVertex{pos = Vec3(-half_width, -half_height, 0), uv = Vec2(0, 1), normal = normal}
	poly:AddVertex{pos = Vec3(half_width, -half_height, 0), uv = Vec2(1, 1), normal = normal}
	poly:AddVertex{pos = Vec3(half_width, half_height, 0), uv = Vec2(1, 0), normal = normal}
	poly:AddVertex{pos = Vec3(-half_width, -half_height, 0), uv = Vec2(0, 1), normal = normal}
	poly:AddVertex{pos = Vec3(half_width, half_height, 0), uv = Vec2(1, 0), normal = normal}
	poly:AddVertex{pos = Vec3(-half_width, half_height, 0), uv = Vec2(0, 0), normal = normal}
	poly:Upload()
	return poly
end

local function spawn_plane(parent, name, position, width, height, material, rotation)
	local ent = create_entity(parent, name, position, rotation)
	ent:AddComponent("visual")
	local primitive_entity = Entity.New{
		Name = name .. "_primitive",
		Parent = ent,
	}
	primitive_entity:AddComponent("transform")
	local visual_primitive = primitive_entity:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(build_plane_polygon(width, height))
	visual_primitive:SetMaterial(material)
	ent.visual:BuildAABB()
	return ent
end

local function frame_camera()
	local camera = render3d.GetCamera and render3d.GetCamera()

	if not camera then return end

	camera:SetPosition(Vec3(0, 22, 58) + SCENE_OFFSET)
	camera:SetAngles(Deg3(-14, 180, 0))
	camera:SetFOV(math.rad(72))
	camera:SetNearZ(0.05)
	camera:SetFarZ(1800)
end

local root = Entity.World:Ensure{
	Key = ROOT_KEY,
	Name = ROOT_KEY,
}
root:RemoveChildren()
local ground_material = shapes.Material{Color = Color(0.18, 0.18, 0.19, 1), Roughness = 0.96, Metallic = 0}
local road_material = shapes.Material{Color = Color(0.10, 0.10, 0.11, 1), Roughness = 0.92, Metallic = 0}
local tower_material = shapes.Material{Color = Color(0.46, 0.48, 0.52, 1), Roughness = 0.78, Metallic = 0.02}
local tower_alt_material = shapes.Material{Color = Color(0.56, 0.52, 0.46, 1), Roughness = 0.82, Metallic = 0.01}
local accent_material = shapes.Material{Color = Color(0.70, 0.28, 0.18, 1), Roughness = 0.62, Metallic = 0.0}
local small_prop_material = shapes.Material{Color = Color(0.74, 0.76, 0.80, 1), Roughness = 0.36, Metallic = 1.0}
local small_prop_alt_material = shapes.Material{Color = Color(0.20, 0.63, 0.88, 1), Roughness = 0.24, Metallic = 0.08}
local fence_frame_material = shapes.Material{Color = Color(0.30, 0.22, 0.16, 1), Roughness = 0.88, Metallic = 0.0}
local fence_material = Material.New()
local coarse_fence_material = Material.New()
fence_material:SetAlbedoTexture(
	shapes.Texture([[
			vec2 tiled = uv * vec2(20.0, 12.0);
			vec2 local = abs(fract(tiled) - 0.5);
			float wire = 1.0 - step(0.055, min(local.x, local.y));
			vec3 wire_color = vec3(0.72, 0.76, 0.78);
			return vec4(wire_color, wire);
		]])
)
fence_material:SetRoughnessTexture(shapes.Texture("return vec4(0.78);"))
fence_material:SetMetallicTexture(shapes.Texture("return vec4(0.12);"))
fence_material:SetAlphaTest(true)
fence_material:SetAlphaCutoff(0.5)
fence_material:SetDoubleSided(true)
coarse_fence_material:SetAlbedoTexture(
	shapes.Texture([[
			vec2 tiled = uv * vec2(4.0, 2.0);
			vec2 local = fract(tiled);
			float vertical_bar = step(0.34, local.x);
			float horizontal_bar = step(0.34, local.y);
			float alpha = max(vertical_bar, horizontal_bar);
			vec3 bar_color = vec3(0.76, 0.80, 0.82);
			return vec4(bar_color, alpha);
		]])
)
coarse_fence_material:SetRoughnessTexture(shapes.Texture("return vec4(0.78);"))
coarse_fence_material:SetMetallicTexture(shapes.Texture("return vec4(0.12);"))
coarse_fence_material:SetAlphaTest(true)
coarse_fence_material:SetAlphaCutoff(0.5)
coarse_fence_material:SetDoubleSided(true)
spawn_box(
	root,
	"shadow_city_validation_ground",
	Vec3(0, -1.0, CITY_CENTER_Z),
	Vec3(420, 2, 520),
	ground_material
)
spawn_box(
	root,
	"shadow_city_validation_road_main",
	Vec3(0, 0.02, CITY_CENTER_Z),
	Vec3(26, 0.08, 360),
	road_material
)
spawn_box(
	root,
	"shadow_city_validation_road_cross",
	Vec3(0, 0.025, CITY_CENTER_Z - 80),
	Vec3(220, 0.09, 20),
	road_material
)

do
	local index = 0

	for row = 1, 8 do
		for column = 1, 9 do
			local x = -128 + (column - 1) * 32
			local z = CITY_CENTER_Z + 72 - (row - 1) * 42
			local near_corridor = math.abs(x) < 26 and z > CITY_CENTER_Z + 8

			if not near_corridor then
				index = index + 1
				local width = 14 + ((row + column) % 3) * 5.0
				local depth = 14 + ((row * 2 + column) % 3) * 6.0
				local height = 42 + ((row * 3 + column * 5) % 7) * 18
				local material = index % 2 == 0 and tower_material or tower_alt_material
				spawn_box(
					root,
					("shadow_city_validation_tower_%02d"):format(index),
					Vec3(x, height * 0.5, z),
					Vec3(width, height, depth),
					material,
					make_rotation(0, (index % 4) * 7, 0)
				)

				if index % 3 == 0 then
					spawn_box(
						root,
						("shadow_city_validation_annex_%02d"):format(index),
						Vec3(x + width * 0.42, height * 0.2, z + depth * 0.45),
						Vec3(width * 0.46, height * 0.4, depth * 0.42),
						accent_material
					)
				end

				if index % 5 == 0 then
					spawn_box(
						root,
						("shadow_city_validation_podium_%02d"):format(index),
						Vec3(x, height * 0.08, z),
						Vec3(width * 1.28, height * 0.16, depth * 1.22),
						road_material
					)
				end
			end
		end
	end
end

spawn_box(
	root,
	"shadow_city_validation_courtyard",
	Vec3(0, 0.45, -18),
	Vec3(30, 0.9, 30),
	ground_material
)
spawn_box(
	root,
	"shadow_city_validation_plinth_a",
	Vec3(-5.5, 0.9, -2.0),
	Vec3(3.4, 1.8, 3.4),
	accent_material
)
spawn_box(
	root,
	"shadow_city_validation_plinth_b",
	Vec3(4.5, 0.7, -3.8),
	Vec3(2.6, 1.4, 2.6),
	tower_material
)
spawn_box(
	root,
	"shadow_city_validation_small_box_a",
	Vec3(-5.5, 2.5, -2.0),
	Vec3(1.6, 3.2, 1.6),
	small_prop_material,
	make_rotation(4, 18, 0)
)
spawn_box(
	root,
	"shadow_city_validation_small_box_b",
	Vec3(-1.5, 0.75, 1.5),
	Vec3(1.2, 1.5, 1.2),
	small_prop_alt_material,
	make_rotation(0, 30, 0)
)
spawn_box(
	root,
	"shadow_city_validation_small_box_c",
	Vec3(2.6, 1.1, -0.6),
	Vec3(2.0, 2.2, 1.0),
	accent_material,
	make_rotation(0, -24, 0)
)
spawn_sphere(
	root,
	"shadow_city_validation_sphere",
	Vec3(4.5, 2.25, -3.8),
	1.5,
	small_prop_material
)
spawn_capsule(
	root,
	"shadow_city_validation_capsule",
	Vec3(7.8, 1.6, -1.2),
	0.8,
	3.2,
	small_prop_alt_material,
	make_rotation(0, 22, 0)
)
spawn_box(
	root,
	"shadow_city_validation_fence_left_post",
	Vec3(-2.05, 2.0, 4.0),
	Vec3(0.18, 4.0, 0.18),
	fence_frame_material
)
spawn_box(
	root,
	"shadow_city_validation_fence_right_post",
	Vec3(2.05, 2.0, 4.0),
	Vec3(0.18, 4.0, 0.18),
	fence_frame_material
)
spawn_box(
	root,
	"shadow_city_validation_fence_top",
	Vec3(0, 3.92, 4.0),
	Vec3(4.3, 0.14, 0.14),
	fence_frame_material
)
spawn_plane(
	root,
	"shadow_city_validation_fence",
	Vec3(0, 1.95, 4.0),
	4.0,
	3.8,
	fence_material,
	make_rotation()
)
spawn_plane(
	root,
	"shadow_city_validation_fence_coarse",
	Vec3(7.5, 1.95, 4.0),
	4.0,
	3.8,
	coarse_fence_material,
	make_rotation()
)
spawn_box(
	root,
	"shadow_city_validation_fence_shadow_box",
	Vec3(0.0, 1.25, 7.2),
	Vec3(2.2, 2.5, 1.4),
	tower_alt_material
)
spawn_box(
	root,
	"shadow_city_validation_fence_shadow_receiver",
	Vec3(0.0, 0.2, 10.0),
	Vec3(8.0, 0.4, 3.6),
	ground_material
)
spawn_box(
	root,
	"shadow_city_validation_fence_coarse_shadow_receiver",
	Vec3(7.5, 0.2, 10.0),
	Vec3(8.0, 0.4, 3.6),
	ground_material
)
frame_camera()
logn("loaded scene: shadow_city_validation")
