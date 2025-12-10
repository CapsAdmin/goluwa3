local ffi = require("ffi")
local render = require("graphics.render")
local VertexBuffer = {}
VertexBuffer.__index = VertexBuffer

-- Calculate vertex stride from vertex attributes
local function calculate_stride(vertex_attributes)
	local max_offset = 0
	local last_size = 0

	for _, attr in ipairs(vertex_attributes) do
		if attr.offset >= max_offset then
			max_offset = attr.offset
			-- Handle both lua_type (for structured data) and format (for raw data)
			if attr.lua_type then
				last_size = ffi.sizeof(attr.lua_type)
			elseif attr.format then
				-- Calculate size from Vulkan format string
				-- e.g., "r32g32b32_sfloat" = vec3 = 3 floats = 12 bytes
				-- e.g., "r32g32_sfloat" = vec2 = 2 floats = 8 bytes
				-- e.g., "r32g32b32a32_sfloat" = vec4 = 4 floats = 16 bytes
				local components = 0
				if attr.format:match("r32g32b32a32") then
					components = 4
				elseif attr.format:match("r32g32b32") then
					components = 3
				elseif attr.format:match("r32g32") then
					components = 2
				elseif attr.format:match("r32") then
					components = 1
				end
				last_size = components * ffi.sizeof("float")
			else
				error("Attribute must have either lua_type or format", 2)
			end
		end
	end

	return max_offset + last_size
end

function VertexBuffer.New(vertices, vertex_attributes)
	local self = setmetatable({}, VertexBuffer)

	if not vertex_attributes then
		error("vertex_attributes parameter is required", 2)
	end

	self.vertex_attributes = vertex_attributes
	self.stride = calculate_stride(vertex_attributes)

	if type(vertices) == "number" then
		-- Allocate zeroed vertex data
		local count = vertices
		self.vertex_count = count
		self.byte_size = self.stride * count
		self.data = ffi.new("uint8_t[?]", self.byte_size)
	elseif type(vertices) == "table" then
		-- Check if it's a raw float array or structured vertex array
		local is_raw_floats = type(vertices[1]) == "number"
		
		if is_raw_floats then
			-- Raw float array - copy directly
			self.vertex_count = #vertices / (self.stride / ffi.sizeof("float"))
			self.byte_size = #vertices * ffi.sizeof("float")
			self.data = ffi.new("uint8_t[?]", self.byte_size)
			local float_ptr = ffi.cast("float*", self.data)
			
			for i, v in ipairs(vertices) do
				float_ptr[i - 1] = v
			end
		else
			-- Structured vertex array
			local count = #vertices
			self.vertex_count = count
			self.byte_size = self.stride * count
			self.data = ffi.new("uint8_t[?]", self.byte_size)

			-- Fill data
			for i, vertex in ipairs(vertices) do
				local base_offset = (i - 1) * self.stride

				for _, attr in ipairs(vertex_attributes) do
					local dst_ptr = self.data + base_offset + attr.offset
					local src_value = vertex[attr.lua_name]

					if src_value then
						local val = src_value:GetFloatCopy()
						ffi.copy(dst_ptr, val, ffi.sizeof(val))
					end
				end
			end
		end
	else
		error("vertices must be a number or table", 2)
	end

	do
		local sorted_attrs = {}

		for _, attr in ipairs(vertex_attributes) do
			table.insert(sorted_attrs, attr)
		end

		table.sort(sorted_attrs, function(a, b)
			return a.offset < b.offset
		end)

		-- Only create structured vertex accessor if attributes have lua_type
		if sorted_attrs[1] and sorted_attrs[1].lua_type then
			-- Build struct definition with $ placeholders and collect types
			local fields = {}
			local types = {}

			for _, attr in ipairs(sorted_attrs) do
				table.insert(fields, string.format("$ %s;", attr.lua_name))
				table.insert(types, attr.lua_type)
			end

			local struct_def = "struct { " .. table.concat(fields, " ") .. " }"
			local vertex_type = ffi.typeof(struct_def .. "*", unpack(types))
			self.vertices = ffi.cast(vertex_type, self.data)
		else
			-- For raw vertex data, just provide a float pointer
			self.vertices = ffi.cast("float*", self.data)
		end
	end

	-- Create GPU buffer
	self.buffer = render.CreateBuffer(
		{
			buffer_usage = "vertex_buffer",
			data_type = "float",
			data = self.data,
			byte_size = self.byte_size,
		}
	)
	return self
end

function VertexBuffer:Upload()
	self.buffer:CopyData(self.data, self.byte_size)
end

function VertexBuffer:GetBuffer()
	return self.buffer
end

function VertexBuffer:GetVertexCount()
	return self.vertex_count
end

function VertexBuffer:GetVertices()
	return self.vertices
end

function VertexBuffer:SetVertex(index, val)
	self.vertices[index] = val
end

function VertexBuffer:Draw(index_buffer, count)
	local render2d = require("graphics.render2d")
	count = count or self.vertex_count

	if not render2d.cmd then
		error(
			"Cannot draw without active command buffer. Must be called during Draw2D event.",
			2
		)
	end

	render2d.cmd:BindVertexBuffer(self.buffer, 0)

	if index_buffer then
		render2d.cmd:BindIndexBuffer(index_buffer:GetBuffer(), 0, index_buffer:GetIndexType())
		render2d.cmd:DrawIndexed(count, 1, 0, 0, 0)
	else
		render2d.cmd:Draw(count, 1, 0, 0)
	end
end

return VertexBuffer
