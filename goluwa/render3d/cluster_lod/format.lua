local ffi = require("ffi")
local format = {}
format.NO_PARENT_ERROR = 1e30
format.CLUSTER_GLSL = [[
	struct cluster_record {
		vec4 lod;
		vec4 parent;
		vec4 bounds;
		float error;
		float parent_error;
		uint first_index;
		uint index_count;
	};
]]
format.ClusterRecord = ffi.typeof([[struct {
	float lod[4];
	float parent[4];
	float bounds[4];
	float error;
	float parent_error;
	uint32_t first_index;
	uint32_t index_count;
}]])
format.RECORD_SIZE = ffi.sizeof(format.ClusterRecord)
assert(format.RECORD_SIZE == 64)
return format
