local ffi = require("ffi")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local brush_list = {}
local HEADER_SIZE = 11
local BRUSH_SIZE = 76
local MATERIAL_NAME_SIZE = 64
local GEOM_NAME_SIZE = 128
local u32 = ffi.typeof("uint32_t *")
local i32 = ffi.typeof("int32_t *")
local f32 = ffi.typeof("float *")
local brush_type = ffi.typeof([[struct {
	uint32_t zero;
	uint32_t id;
	uint32_t geom;
	int32_t material;
	uint32_t flags;
	uint32_t reserved;
	float matrix[12];
	uint8_t view_distance_ratio;
	uint8_t lod_ratio;
	uint16_t unknown;
}]])
local brush_array_type = ffi.typeof("$ *", brush_type)
assert(ffi.sizeof(brush_type) == BRUSH_SIZE)

local function read_string(data, offset, size)
	local text = data:sub(offset + 1, offset + size)
	return text:match("^[^%z]*")
end

function brush_list.Parse(data)
	if data:sub(1, 3) ~= "CRY" then return nil, "not a brush list" end

	local base = ffi.cast("const uint8_t *", data)
	local position = HEADER_SIZE

	local function read_u32()
		local value = ffi.cast(u32, base + position)[0]
		position = position + 4
		return value
	end

	local function read_table(name_size)
		local records = {}

		for i = 1, read_u32() do
			local record_start = position
			local size = read_u32()
			records[i] = {offset = position, name = read_string(data, position, name_size)}
			position = record_start + size
		end

		return records
	end

	local materials = read_table(MATERIAL_NAME_SIZE)
	local geoms = read_table(GEOM_NAME_SIZE)

	for _, geom in ipairs(geoms) do
		geom.flags = ffi.cast(u32, base + geom.offset + GEOM_NAME_SIZE)[0]
		local bounds = ffi.cast(f32, base + geom.offset + GEOM_NAME_SIZE + 4)
		geom.min = {bounds[0], bounds[1], bounds[2]}
		geom.max = {bounds[3], bounds[4], bounds[5]}
	end

	local count = read_u32()

	if position + count * BRUSH_SIZE > #data then
		return nil, "brush list is truncated"
	end

	local brushes = {}
	local array = ffi.cast(brush_array_type, base + position)

	for i = 1, count do
		local brush = array[i - 1]
		local matrix = Matrix44():Identity()

		for row = 0, 2 do
			matrix["m0" .. row] = brush.matrix[row * 4]
			matrix["m1" .. row] = brush.matrix[row * 4 + 1]
			matrix["m2" .. row] = brush.matrix[row * 4 + 2]
			matrix["m3" .. row] = brush.matrix[row * 4 + 3]
		end

		brushes[i] = {
			geom = geoms[brush.geom + 1],
			material = brush.material >= 0 and materials[brush.material + 1] or nil,
			flags = brush.flags,
			view_distance_ratio = brush.view_distance_ratio,
			lod_ratio = brush.lod_ratio,
			world_matrix = matrix,
		}
	end

	return {materials = materials, geoms = geoms, brushes = brushes}
end

return brush_list
