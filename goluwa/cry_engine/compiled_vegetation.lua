local ffi = require("ffi")
local bit = require("bit")
local file_path = import("goluwa/filesystem/path.lua")
local compiled_vegetation = {}
local GROUP_TABLE_OFFSET = 36
local GROUP_COUNT = 1024
local GROUP_RECORD_SIZE = 332
local GROUP_NAME_OFFSET = 4
local GROUP_NAME_SIZE = 256
local GROUP_PARAMS_OFFSET = 260
local INSTANCE_SIZE = 62
local VEGETATION_FLAG = 0x800
local MAX_COORDINATE = 4200
local group_params_type = ffi.typeof([[struct {
	uint32_t hideable;
	float bending;
	uint32_t flags_a;
	uint32_t reserved_a;
	float brightness;
	float size;
	float max_view_distance_ratio;
	float sprite_distance_ratio;
	uint32_t reserved_b;
	float density;
	float elevation_max;
	float elevation_min;
	float ai_radius;
	float size_variation;
	float slope_max;
	float slope_min;
	uint32_t flags_b;
	uint32_t flags_c;
}]])
local instance_type = ffi.typeof([[struct __attribute__((packed)) {
	uint8_t type;
	float box_min[3];
	float box_max[3];
	uint32_t reserved;
	float max_view_distance;
	uint32_t flags;
	uint8_t view_distance_ratio;
	uint8_t lod_ratio;
	uint8_t unknown;
	float position[3];
	float scale;
	uint8_t group;
	uint8_t group_data;
	uint8_t angle;
	uint8_t padding[3];
}]])
local instance_pointer_type = ffi.typeof("$ *", instance_type)
local group_params_pointer_type = ffi.typeof("$ *", group_params_type)
assert(ffi.sizeof(group_params_type) == GROUP_RECORD_SIZE - GROUP_PARAMS_OFFSET)
assert(ffi.sizeof(instance_type) == INSTANCE_SIZE)
local CATEGORY_BY_FOLDER = {
	trees = "Trees",
	bushes = "Bushes",
	ground_plants = "Groundplants",
	plants = "Groundplants",
	fields = "Groundplants",
	rocks = "Rocks",
}

function compiled_vegetation.Parse(data, instances_offset)
	local base = ffi.cast("const uint8_t *", data)
	local prototypes = {list = {}, by_id = {}}

	for id = 0, GROUP_COUNT - 1 do
		local record = GROUP_TABLE_OFFSET + id * GROUP_RECORD_SIZE
		local name = data:sub(record + GROUP_NAME_OFFSET + 1, record + GROUP_NAME_OFFSET + GROUP_NAME_SIZE):match("^[^%z]+")

		if name and name:lower():ends_with(".cgf") then
			local params = ffi.cast(group_params_pointer_type, base + record + GROUP_PARAMS_OFFSET)[0]
			local model_path = file_path.FixPathSlashes(name)
			local folder = model_path:lower():match("^objects/natural/([^/]+)/")
			local prototype = {
				id = id,
				model_path = model_path,
				name = file_path.GetFileNameFromPath(model_path),
				category = CATEGORY_BY_FOLDER[folder],
				align_to_terrain = bit.band(params.flags_b, 1) ~= 0,
				use_terrain_color = bit.band(params.flags_b, 2) ~= 0,
				bending = params.bending,
				use_sprites = folder ~= "rocks" and not model_path:lower():find("/grass/", 1, true),
				size = params.size,
				size_var = params.size_variation,
			}
			prototypes.list[#prototypes.list + 1] = prototype
			prototypes.by_id[id] = prototype
		end
	end

	local instances = {}
	local last = #data - INSTANCE_SIZE
	local offset = instances_offset

	while offset <= last do
		local instance = ffi.cast(instance_pointer_type, base + offset)[0]
		local prototype = bit.band(instance.flags, VEGETATION_FLAG) ~= 0 and
			instance.reserved == 0 and
			prototypes.by_id[instance.group]
		local accepted = false

		if
			prototype and
			instance.scale > 0.05 and
			instance.scale < 20 and
			instance.max_view_distance > 0
		then
			accepted = instance.box_min[0] >= -1 and
				instance.box_min[0] <= MAX_COORDINATE and
				instance.box_min[1] >= -1 and
				instance.box_min[1] <= MAX_COORDINATE

			for axis = 0, 2 do
				accepted = accepted and
					instance.box_max[axis] > instance.box_min[axis] and
					instance.position[axis] >= instance.box_min[axis] - 1 and
					instance.position[axis] <= instance.box_max[axis] + 1
			end
		end

		if accepted then
			instances[#instances + 1] = {
				prototype_id = instance.group,
				x = instance.position[0],
				y = instance.position[1],
				z = instance.position[2],
				scale = instance.scale,
				angle = instance.angle,
			}
			offset = offset + INSTANCE_SIZE
		else
			offset = offset + 1
		end
	end

	return prototypes, instances
end

return compiled_vegetation
