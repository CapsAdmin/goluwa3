local ffi = require("ffi")
local render = require("graphics.render")
local IndexBuffer = {}
IndexBuffer.__index = IndexBuffer

-- Convert indices to appropriate format
local function indices_to_array(indices, index_type)
	index_type = index_type or "uint16_t"
	local index_data = ffi.new(index_type .. "[?]", #indices)

	for i, idx in ipairs(indices) do
		index_data[i - 1] = idx
	end

	local byte_size = ffi.sizeof(index_type) * #indices
	return index_data, byte_size
end

function IndexBuffer.New(indices, index_type)
	local self = setmetatable({}, IndexBuffer)
	self.index_type = index_type or "uint16_t"
	self.indices = indices
	self.index_count = #indices
	-- Convert to array for initial upload
	local index_data, byte_size = indices_to_array(indices, self.index_type)
	self.byte_size = byte_size
	-- Create the GPU buffer
	self.buffer = render.CreateBuffer(
		{
			buffer_usage = "index_buffer",
			data_type = self.index_type,
			data = index_data,
			byte_size = byte_size,
		}
	)
	return self
end

function IndexBuffer:GetData()
	return self.indices
end

function IndexBuffer:Upload()
	-- Reflatten the indices and upload
	local index_data = indices_to_array(self.indices, self.index_type)
	self.buffer:CopyData(index_data, self.byte_size)
end

function IndexBuffer:GetBuffer()
	return self.buffer
end

function IndexBuffer:GetIndexCount()
	return self.index_count
end

function IndexBuffer:GetIndexType()
	return self.index_type
end

return IndexBuffer
