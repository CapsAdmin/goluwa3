local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("lua/shapes.lua")
local ROOT_KEY = "culling_stress_10k_scene"
local BOX_MODEL_PATH = "models/box.lua"
local ENTITY_COUNT = 40000
local GRID_SPAN = 5000
local BOX_SIZE = Vec3(6, 6, 6)
local CHUNK_COLUMNS = 16
local CHUNK_ROWS = 16

local function get_layout()
	local columns = math.max(1, math.ceil(math.sqrt(ENTITY_COUNT)))
	local rows = math.max(1, math.ceil(ENTITY_COUNT / columns))
	local axis_count = math.max(columns, rows)
	local spacing = axis_count > 1 and GRID_SPAN / (axis_count - 1) or 0
	return columns, rows, spacing
end

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

local function create_chunk(parent, chunk_x, chunk_z, position)
	local ent = create_entity(parent, ("culling_stress_chunk_%d_%d"):format(chunk_x, chunk_z), position)
	ent:AddComponent("visual")
	ent.visual:SetUseOcclusionCulling(false)
	return ent
end

local function add_box_to_chunk(chunk, index, local_position, primitive, material)
	local primitive_entity = chunk.visual:CreatePrimitiveEntity(
		primitive.mesh or primitive.polygon3d or primitive,
		primitive.material or material,
		chunk.Name .. "_primitive_" .. index
	)

	if primitive.position then
		primitive_entity.transform:SetPosition(local_position + primitive.position)
	else
		primitive_entity.transform:SetPosition(local_position)
	end

	if primitive.rotation then
		primitive_entity.transform:SetRotation(primitive.rotation)
	end

	primitive_entity.transform:SetScale(BOX_SIZE)
end

local function frame_camera()
	local camera = render3d.GetCamera and render3d.GetCamera()

	if not camera then return end

	camera:SetPosition(Vec3(GRID_SPAN * 0.5, GRID_SPAN * 0.6, GRID_SPAN * 1.15))
	camera:SetAngles(Deg3(-24, 218, 0))
	camera:SetFOV(math.rad(72))
	camera:SetNearZ(0.05)
	camera:SetFarZ(GRID_SPAN * 3)
end

local GRID_COLUMNS, GRID_ROWS, GRID_SPACING = get_layout()
local root = Entity.World:Ensure{
	Key = ROOT_KEY,
	Name = ROOT_KEY,
}
root:RemoveChildren()
local box_material = shapes.Material{
	Color = Color(0.72, 0.74, 0.78, 1),
	Roughness = 0.88,
	Metallic = 0.02,
}
local shared_box_primitive = get_shared_box_primitive()
local chunk_world_width = CHUNK_COLUMNS > 0 and GRID_SPACING * CHUNK_COLUMNS or 0
local chunk_world_depth = CHUNK_ROWS > 0 and GRID_SPACING * CHUNK_ROWS or 0
local index = 0

for chunk_row = 0, math.ceil(GRID_ROWS / CHUNK_ROWS) - 1 do
	for chunk_column = 0, math.ceil(GRID_COLUMNS / CHUNK_COLUMNS) - 1 do
		local chunk_origin_x = chunk_column * chunk_world_width
		local chunk_origin_z = chunk_row * chunk_world_depth
		local chunk = create_chunk(root, chunk_column, chunk_row, Vec3(chunk_origin_x, 0, chunk_origin_z))

		for local_row = 0, CHUNK_ROWS - 1 do
			local row = chunk_row * CHUNK_ROWS + local_row

			if row >= GRID_ROWS then break end

			for local_column = 0, CHUNK_COLUMNS - 1 do
				local column = chunk_column * CHUNK_COLUMNS + local_column

				if column >= GRID_COLUMNS then break end

				index = index + 1

				if index > ENTITY_COUNT then break end

				add_box_to_chunk(
					chunk,
					index,
					Vec3(local_column * GRID_SPACING, BOX_SIZE.y * 0.5, local_row * GRID_SPACING),
					shared_box_primitive,
					box_material
				)
			end

			if index > ENTITY_COUNT then break end
		end

		chunk.visual:BuildAABB()

		if index > ENTITY_COUNT then break end
	end

	if index > ENTITY_COUNT then break end
end

frame_camera()
