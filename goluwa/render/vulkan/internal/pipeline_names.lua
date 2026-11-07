local ffi = require("ffi")
local fs = import("goluwa/filesystem/fs.lua")
local pipeline_names = {}
local enabled = os.getenv("GOLUWA_DUMP_SHADERS") == "1"
local directory = "./storage/shader_source/pipelines/"
local file

function pipeline_names.Register(kind, handle, name)
	if not enabled then return end

	if not file then
		fs.create_directory_recursive(directory)
		local stat = assert(io.open("/proc/self/stat"))
		local pid = stat:read("*n")
		stat:close()
		file = assert(io.open(directory .. pid .. ".tsv", "w"))
	end

	file:write(
		string.format(
			"0x%016x\t%s\t%s\n",
			tonumber(ffi.cast("uintptr_t", handle)),
			kind,
			name or "unnamed"
		)
	)
	file:flush()
end

return pipeline_names
