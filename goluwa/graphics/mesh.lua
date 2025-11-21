local ffi = require("ffi")
local VertexBuffer = require("graphics.vertex_buffer")
local IndexBuffer = require("graphics.index_buffer")
local render = require("graphics.render")
local Mesh = {}
Mesh.__index = Mesh

function Mesh.New(vertex_attributes, vertices, indices)
	local self = setmetatable({}, Mesh)
	self.vertex_buffer = VertexBuffer.New(vertices, vertex_attributes)

	if indices then self.index_buffer = IndexBuffer.New(indices) end

	return self
end

function Mesh:Bind(cmd, binding_position)
	binding_position = binding_position or 0
	cmd:BindVertexBuffer(self.vertex_buffer:GetBuffer(), binding_position)

	if self.index_buffer then
		cmd:BindIndexBuffer(self.index_buffer:GetBuffer(), binding_position, self.index_buffer:GetIndexType())
	end
end

function Mesh:DrawIndexed(cmd, index_count, instance_count, first_index, vertex_offset, first_instance)
	cmd:DrawIndexed(
		index_count or self.index_buffer:GetIndexCount(),
		instance_count or 1,
		first_index or 0,
		vertex_offset or 0,
		first_instance or 0
	)
end

function Mesh:Draw(cmd, vertex_count, instance_count, first_vertex, first_instance)
	cmd:Draw(
		vertex_count or self.vertex_buffer:GetVertexCount(),
		instance_count or 1,
		first_vertex or 0,
		first_instance or 0
	)
end

function Mesh:GetVertices()
	return self.vertex_buffer:GetVertices()
end

function Mesh:Upload()
	self.vertex_buffer:Upload()
end

function Mesh:UploadIndices(indices, index_type)
	if not self.index_buffer then
		self.index_buffer = IndexBuffer.New(indices, index_type)
	else
		-- Update existing index buffer
		self.index_buffer.indices = indices
		self.index_buffer.index_count = #indices
		local ffi = require("ffi")
		local index_data = ffi.new(self.index_buffer.index_type .. "[?]", #indices)

		for i, idx in ipairs(indices) do
			index_data[i - 1] = idx
		end

		local byte_size = ffi.sizeof(self.index_buffer.index_type) * #indices
		self.index_buffer.byte_size = byte_size

		if not self.index_buffer.buffer or self.index_buffer.buffer_size ~= byte_size then
			self.index_buffer.buffer = render.CreateBuffer(
				{
					buffer_usage = "index_buffer",
					data_type = self.index_buffer.index_type,
					data = index_data,
					byte_size = byte_size,
				}
			)
			self.index_buffer.buffer_size = byte_size
		else
			self.index_buffer.buffer:CopyData(index_data, byte_size)
		end
	end
end

return Mesh
