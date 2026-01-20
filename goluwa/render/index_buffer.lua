local ffi = require("ffi")
local render = require("render.render")
local prototype = require("prototype")
local IndexBuffer = prototype.CreateTemplate("render_index_buffer")

-- Convert indices to appropriate format
local function indices_to_array(indices, index_type)
	index_type = index_type or "uint16_t"

	if index_type == "uint16" then index_type = "uint16_t" end

	local index_data = ffi.new(index_type .. "[?]", #indices)

	for i, idx in ipairs(indices) do
		index_data[i - 1] = idx
	end

	local byte_size = ffi.sizeof(index_type) * #indices
	return index_data, byte_size
end

function IndexBuffer.New(indices, index_type)
	local self = IndexBuffer:CreateObject()
	self.index_type = index_type or "uint16_t"

	-- If indices is nil, create an empty buffer for dynamic usage
	if not indices then
		self.indices = {}
		self.index_count = 0
		return self
	end

	self.indices = indices
	self.index_count = #indices
	-- Convert to array for initial upload
	local index_data, byte_size = indices_to_array(indices, self.index_type)
	self.byte_size = byte_size
	-- Create the GPU buffer
	self.buffer = render.CreateBuffer(
		{
			buffer_usage = {"index_buffer", "storage_buffer", "shader_device_address"},
			data_type = self.index_type,
			data = index_data,
			byte_size = byte_size,
		}
	)
	return self
end

function IndexBuffer.FromPointer(ptr, len, index_type)
	local self = IndexBuffer:CreateObject()
	self.index_type = index_type or "uint16_t"
	self.indices = ptr
	self.index_count = len
	-- Calculate byte size
	local byte_size = ffi.sizeof(self:GetIndexTypeFFI()) * len
	self.byte_size = byte_size
	-- Create the GPU buffer directly from the pointer
	self.buffer = render.CreateBuffer(
		{
			buffer_usage = {"index_buffer", "storage_buffer", "shader_device_address"},
			data_type = self.index_type,
			data = ptr,
			byte_size = byte_size,
		}
	)
	return self
end

function IndexBuffer:GetIndexType()
	local t = self.index_type

	if t == "uint16_t" then t = "uint16" end

	if t == "uint32_t" then t = "uint32" end

	return t
end

function IndexBuffer:GetIndexTypeFFI()
	local t = self.index_type

	if t == "uint16" then t = "uint16_t" end

	if t == "uint32" then t = "uint32_t" end

	return t
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

function IndexBuffer:LoadIndices(count)
	-- Create sequential indices array
	self.indices = {}

	for i = 1, count do
		self.indices[i] = i - 1
	end

	self.index_count = count
	-- Calculate byte size
	self.byte_size = ffi.sizeof(self.index_type) * count
	-- Convert to array for upload
	local index_data, byte_size = indices_to_array(self.indices, self.index_type)

	-- Create or recreate the GPU buffer
	if not self.buffer or self.buffer_size ~= byte_size then
		self.buffer = render.CreateBuffer(
			{
				buffer_usage = {"index_buffer", "storage_buffer", "shader_device_address"},
				data_type = self.index_type,
				data = index_data,
				byte_size = byte_size,
			}
		)
		self.buffer_size = byte_size
	else
		self.buffer:CopyData(index_data, byte_size)
	end
end

return IndexBuffer:Register()
