local ffi = require("ffi")
local render = require("render.render")
local UniformBuffer = {}
UniformBuffer.__index = UniformBuffer
local id = 0

function UniformBuffer.New(decl)
	local struct = ffi.typeof(decl)
	local self = setmetatable({}, UniformBuffer)
	self.data = struct()
	self.struct = struct
	self.buffer = render.CreateBuffer(
		{
			data = self.data,
			byte_size = ffi.sizeof(struct),
			buffer_usage = {"uniform_buffer"},
			memory_property = {"host_visible", "host_coherent"},
		}
	)
	self.size = ffi.sizeof(self.struct)
	self.glsl_declaration = [[
        layout(std140, binding = BINDING_INDEX) uniform ubo_type_]] .. id .. [[ {
            ]] .. decl:match("%b{}"):sub(2, -2) .. [[
        } VARIABLE_NAME;
    ]]
	id = id + 1
	return self
end

function UniformBuffer:GetGLSLDeclaration(binding_index, variable_name)
	local decl = self.glsl_declaration:gsub("BINDING_INDEX", binding_index):gsub("VARIABLE_NAME", variable_name)
	return decl
end

function UniformBuffer:GetData()
	return self.data
end

function UniformBuffer:Upload()
	self.buffer:CopyData(self.data, self.size)
end

return UniformBuffer
