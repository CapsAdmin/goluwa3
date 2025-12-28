local ffi = require("ffi")
local render = require("render.render")
local UniformBuffer = {}
UniformBuffer.__index = UniformBuffer

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
	return self
end

function UniformBuffer:GetData()
	return self.data
end

function UniformBuffer:Upload()
	self.buffer:CopyData(self.data, self.size)
end

return UniformBuffer
