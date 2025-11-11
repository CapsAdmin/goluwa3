local ffi = require("ffi")
local render = require("graphics.render")
local Vec3f = require("structs.vec3").Vec3f
local Vec2f = require("structs.vec2").Vec2f
local Colorf = require("structs.color").Colorf
local VertexBuffer = {}
VertexBuffer.__index = VertexBuffer

-- Helper to determine the size and type of a field
local function get_field_info(value)
	local t = type(value)

	if t == "cdata" then
		if ffi.istype(Vec3f, value) then
			return 3, "float", {"x", "y", "z"}
		elseif ffi.istype(Vec2f, value) then
			return 2, "float", {"x", "y"}
		elseif ffi.istype(Colorf, value) then
			return 4, "float", {"r", "g", "b", "a"}
		end
	elseif t == "table" then
		return #value, "float", nil
	end

	return 1, "float", nil
end

-- Convert structured vertex data to flat float array
local function vertices_to_flat_array(vertices, layout)
	-- Calculate total size
	local vertex_size = 0
	local field_info = {}

	for _, field_name in ipairs(layout) do
		local value = vertices[1][field_name]
		local size, dtype, accessors = get_field_info(value)
		vertex_size = vertex_size + size
		field_info[field_name] = {size = size, dtype = dtype, accessors = accessors}
	end

	local total_floats = vertex_size * #vertices
	local flat_data = ffi.new("float[?]", total_floats)
	local offset = 0

	for i, vertex in ipairs(vertices) do
		for _, field_name in ipairs(layout) do
			local value = vertex[field_name]
			local info = field_info[field_name]

			if info.accessors then
				-- It's a struct like Vec3f, Vec2f, Colorf
				for j, accessor in ipairs(info.accessors) do
					flat_data[offset] = tonumber(value[accessor])
					offset = offset + 1
				end
			elseif type(value) == "table" then
				-- It's a plain table
				for j = 1, info.size do
					flat_data[offset] = tonumber(value[j])
					offset = offset + 1
				end
			else
				-- It's a single value
				flat_data[offset] = tonumber(value)
				offset = offset + 1
			end
		end
	end

	return flat_data, ffi.sizeof("float") * total_floats, vertex_size, field_info
end

function VertexBuffer.New(vertices, layout)
	local self = setmetatable({}, VertexBuffer)
	self.layout = layout
	self.vertices = vertices
	self.vertex_count = #vertices
	-- Convert to flat array for initial upload
	local flat_data, byte_size, vertex_size, field_info = vertices_to_flat_array(vertices, layout)
	self.byte_size = byte_size
	self.vertex_size = vertex_size
	self.field_info = field_info
	-- Create the GPU buffer
	self.buffer = render.CreateBuffer(
		{
			buffer_usage = "vertex_buffer",
			data_type = "float",
			data = flat_data,
			byte_size = byte_size,
		}
	)
	return self
end

function VertexBuffer:GetData()
	return self.vertices
end

function VertexBuffer:Upload()
	-- Reflatten the vertex data and upload
	local flat_data = vertices_to_flat_array(self.vertices, self.layout)
	self.buffer:CopyData(flat_data, self.byte_size)
end

function VertexBuffer:GetBuffer()
	return self.buffer
end

function VertexBuffer:GetVertexCount()
	return self.vertex_count
end

return VertexBuffer
