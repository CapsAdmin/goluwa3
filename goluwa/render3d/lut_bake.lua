local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local fs = import("goluwa/filesystem/fs.lua")
local crypto = import("goluwa/crypto.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local tonemappers = import("goluwa/render3d/tonemappers.lua")
local lut_bake = {}
lut_bake.CacheDirectory = "storage/cache/luts/"
local VERSION = 1
local GROUP_SIZE = 64
local DECLARATIONS = [[
	layout(set = 0, binding = 0, std430) buffer Dest { vec4 dest[]; };
	layout(set = 0, binding = 1, std430) buffer Params { float params[]; };
]]
local MAIN = [[
	void main() {
		uint id = gl_GlobalInvocationID.x;
		int size = int(params[0]);

		if (id >= uint(size * size * size)) return;

		int r = int(id) % size;
		int g = (int(id) / size) % size;
		int b = int(id) / (size * size);
		vec3 encoded = vec3(r, g, b) / float(size - 1);
		vec3 display = bake_transform(log_decode(encoded, int(params[1])));
		dest[id] = vec4(LinearToSRGB(clamp(display, 0.0, 1.0)), 1.0);
	}
]]

local function to_hex(raw)
	return (raw:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

local function check(config)
	assert(
		type(config.name) == "string" and config.name ~= "",
		"lut_bake: a table needs a name"
	)
	assert(
		type(config.glsl) == "string",
		"lut_bake: glsl must define vec3 bake_transform(vec3 x)"
	)
	local encoding = tonemappers.indices[config.encoding]
	assert(encoding == 5 or encoding == 6, "lut_bake: encoding must be slog3 or logc")
	assert(
		type(config.size) == "number" and config.size >= 2,
		"lut_bake: size must be at least 2"
	)
	return encoding
end

-- the key is everything the table depends on, including the shader helpers bake_transform can call
function lut_bake.GetPath(config)
	check(config)
	local key = table.concat(
		{
			VERSION,
			config.encoding,
			config.size,
			config.glsl,
			compute_helpers.GetColorHelpersGLSL(),
		},
		"\n"
	)
	return lut_bake.CacheDirectory .. config.name:gsub("[^%w]+", "_") .. "_" .. config.encoding .. "_" .. config.size .. "_" .. to_hex(crypto.SHA1(key)):sub(1, 16) .. ".cube"
end

local function create_buffer(byte_size, readback)
	return render.CreateBuffer{
		byte_size = byte_size,
		buffer_usage = {"storage_buffer"},
		memory_property = readback and
			{"host_visible", "host_coherent", "host_cached"} or
			{"host_visible", "host_coherent"},
		label = "lut_bake",
	}
end

-- Bakes a display transform into a .cube read like a camera table: red fastest, the input is the
-- scene encoded by `encoding` (slog3 or logc, see compute_helpers log_encode), the output is the
-- display image sRGB encoded. `glsl` defines `vec3 bake_transform(vec3 x)` from the exposed scene
-- (18% grey is 0.18) to display linear and may call anything in compute_helpers. Returns the path
-- and whether it was already cached.
function lut_bake.Bake(config)
	local encoding = check(config)
	local path = lut_bake.GetPath(config)

	if fs.is_file(path) then return path, true end

	local size = config.size
	local count = size * size * size
	local pipeline = EasyPipeline.Compute{
		name = "lut_bake_" .. config.name,
		DescriptorSetCount = 1,
		LocalSize = {x = GROUP_SIZE, y = 1, z = 1},
		storage_buffers = {{binding_index = 0}, {binding_index = 1}},
		custom_declarations = DECLARATIONS,
		shader = compute_helpers.GetColorHelpersGLSL() .. config.glsl .. MAIN,
	}
	local out = create_buffer(count * 16, true)
	local params = create_buffer(16 * 4)
	local mapped = ffi.cast("float*", params:Map())
	mapped[0] = size
	mapped[1] = encoding
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 0, 0, out, out:GetSize())
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 1, 0, params, params:GetSize())
	pipeline.pipeline:Dispatch(cmd, math.ceil(count / GROUP_SIZE), 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
	cmd:End()
	render.SubmitAndWait(cmd)
	local values = ffi.cast("float*", out:Map())
	local lines = {
		"# baked by goluwa render3d/lut_bake: " .. config.name,
		"TITLE \"" .. config.name .. "\"",
		"LUT_3D_SIZE " .. size,
		"DOMAIN_MIN 0.0 0.0 0.0",
		"DOMAIN_MAX 1.0 1.0 1.0",
	}

	for i = 0, count - 1 do
		lines[#lines + 1] = string.format("%.6f %.6f %.6f", values[i * 4], values[i * 4 + 1], values[i * 4 + 2])
	end

	out:Remove()
	params:Remove()
	pipeline:Remove()
	assert(fs.create_directory_recursive(lut_bake.CacheDirectory))
	assert(fs.write_file(path, table.concat(lines, "\n") .. "\n"))
	return path, false
end

return lut_bake
