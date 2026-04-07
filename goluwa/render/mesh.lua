local ffi = require("ffi")
local VertexBuffer = import("goluwa/render/vertex_buffer.lua")
local IndexBuffer = import("goluwa/render/index_buffer.lua")
local render = import("goluwa/render/render.lua")
local prototype = import("goluwa/prototype.lua")
local Mesh = prototype.CreateTemplate("render_mesh")

local function get_attribute_component_count(attribute)
	if attribute.lua_type then
		return math.max(1, ffi.sizeof(attribute.lua_type) / ffi.sizeof("float"))
	end

	if attribute.format then
		if attribute.format:find("r32g32b32a32", 1, true) then return 4 end

		if attribute.format:find("r32g32b32", 1, true) then return 3 end

		if attribute.format:find("r32g32", 1, true) then return 2 end
	end

	return 1
end

local function normalize_vertex_index(index)
	if index == 0 then return 0 end

	return index - 1
end

local function get_vertex_field(vertex_buffer, attribute, index)
	local normalized_index = normalize_vertex_index(index)
	local vertex = vertex_buffer:GetVertices()[normalized_index]

	if type(vertex) == "number" then
		local base_offset = normalized_index * vertex_buffer.stride + attribute.offset
		return ffi.cast("float*", vertex_buffer.data + base_offset)
	end

	return vertex[attribute.lua_name]
end

local function is_command_buffer(obj)
	return type(obj) == "table" and obj.BindVertexBuffer and obj.Draw
end

local function is_index_buffer(obj)
	return type(obj) == "table" and obj.GetBuffer and obj.GetIndexType and obj.GetIndexCount
end

local function normalize_primitive_topology(mode)
	local tr = {
		triangles = "triangle_list",
		triangle = "triangle_list",
		triangle_list = "triangle_list",
		strip = "triangle_strip",
		triangle_strip = "triangle_strip",
		fan = "triangle_fan",
		triangle_fan = "triangle_fan",
		lines = "line_list",
		line = "line_list",
		line_list = "line_list",
		line_strip = "line_strip",
		points = "point_list",
		point = "point_list",
		point_list = "point_list",
	}
	return tr[mode] or mode or "triangle_list"
end

function Mesh:GetVertexAttributeInfo(name)
	if not self.vertex_attribute_lookup then
		self.vertex_attribute_lookup = {}

		for _, attribute in ipairs(self.vertex_buffer.vertex_attributes) do
			self.vertex_attribute_lookup[attribute.lua_name] = attribute
		end
	end

	local attribute = self.vertex_attribute_lookup[name]

	if not attribute then
		error("unknown vertex attribute: " .. tostring(name), 2)
	end

	return attribute
end

function Mesh.New(vertex_attributes, vertices, indices, index_type, index_count)
	local self = Mesh:CreateObject()
	self.vertex_buffer = VertexBuffer.New(vertices, vertex_attributes)
	self.mode = "triangle_list"

	if indices then
		-- Check if indices is FFI cdata and we have a count
		if type(indices) == "cdata" and index_count then
			self.index_buffer = IndexBuffer.FromPointer(indices, index_count, index_type)
		else
			self.index_buffer = IndexBuffer.New(indices, index_type)
		end
	end

	return self
end

function Mesh:Bind(cmd, binding_position)
	binding_position = binding_position or 0
	cmd:BindVertexBuffer(self.vertex_buffer:GetBuffer(), binding_position)

	if self.index_buffer then
		cmd:BindIndexBuffer(self.index_buffer:GetBuffer(), 0, self.index_buffer:GetIndexType())
	end
end

function Mesh:BindInstanced(cmd, extra_vertex_buffers, binding_position)
	binding_position = binding_position or 0

	if not extra_vertex_buffers or #extra_vertex_buffers == 0 then
		return self:Bind(cmd, binding_position)
	end

	local buffers = {self.vertex_buffer:GetBuffer()}

	for _, extra in ipairs(extra_vertex_buffers) do
		if extra and extra.vertex_buffer then extra = extra.vertex_buffer end

		if extra and extra.GetBuffer then extra = extra:GetBuffer() end

		buffers[#buffers + 1] = extra
	end

	cmd:BindVertexBuffers(binding_position, buffers)

	if self.index_buffer then
		cmd:BindIndexBuffer(self.index_buffer:GetBuffer(), 0, self.index_buffer:GetIndexType())
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
	if not is_command_buffer(cmd) then
		local index_buffer = is_index_buffer(cmd) and cmd or self.index_buffer
		local count = is_index_buffer(cmd) and vertex_count or cmd
		local active_cmd = render.GetCommandBuffer()

		if not active_cmd then
			error(
				"Cannot draw without active command buffer. Must be called during Draw2D event.",
				2
			)
		end

		self:Bind(active_cmd, 0)

		if index_buffer then
			active_cmd:BindIndexBuffer(index_buffer:GetBuffer(), 0, index_buffer:GetIndexType())
			active_cmd:DrawIndexed(count or index_buffer:GetIndexCount(), 1, 0, 0, 0)
		else
			active_cmd:Draw(count or self.vertex_buffer:GetVertexCount(), 1, 0, 0)
		end

		return
	end

	cmd:Draw(
		vertex_count or self.vertex_buffer:GetVertexCount(),
		instance_count or 1,
		first_vertex or 0,
		first_instance or 0
	)
end

function Mesh:DrawInstanced(
	cmd,
	instance_count,
	extra_vertex_buffers,
	index_count,
	first_index,
	vertex_offset,
	first_instance
)
	if not is_command_buffer(cmd) then
		first_instance = vertex_offset
		vertex_offset = first_index
		first_index = index_count
		index_count = extra_vertex_buffers
		extra_vertex_buffers = instance_count
		instance_count = cmd
		cmd = render.GetCommandBuffer()

		if not cmd then
			error(
				"Cannot draw without active command buffer. Must be called during Draw2D event.",
				2
			)
		end
	end

	self:BindInstanced(cmd, extra_vertex_buffers, 0)

	if self.index_buffer then
		cmd:DrawIndexed(
			index_count or self.index_buffer:GetIndexCount(),
			instance_count or 1,
			first_index or 0,
			vertex_offset or 0,
			first_instance or 0
		)
		return
	end

	cmd:Draw(
		self.vertex_buffer:GetVertexCount(),
		instance_count or 1,
		0,
		first_instance or 0
	)
end

function Mesh:GetVertices()
	return self.vertex_buffer:GetVertices()
end

function Mesh:GetVertexCount()
	return self.vertex_buffer:GetVertexCount()
end

function Mesh:SetVertex(index, name, ...)
	local attribute = self:GetVertexAttributeInfo(name)
	local field = get_vertex_field(self.vertex_buffer, attribute, index)
	local argc = select("#", ...)

	if argc == 1 then
		local value = select(1, ...)

		if type(value) == "table" then
			for i = 0, get_attribute_component_count(attribute) - 1 do
				field[i] = value[i + 1] or 0
			end
		else
			field[0] = value

			for i = 1, get_attribute_component_count(attribute) - 1 do
				field[i] = 0
			end
		end

		return
	end

	for i = 0, get_attribute_component_count(attribute) - 1 do
		field[i] = select(i + 1, ...) or 0
	end
end

function Mesh:GetVertex(index, name)
	local attribute = self:GetVertexAttributeInfo(name)
	local field = get_vertex_field(self.vertex_buffer, attribute, index)
	local component_count = get_attribute_component_count(attribute)
	local out = {}

	for i = 0, component_count - 1 do
		out[i + 1] = field[i]
	end

	return unpack(out, 1, component_count)
end

function Mesh:GetVertexBufferAddress()
	return self.vertex_buffer:GetBuffer():GetDeviceAddress()
end

function Mesh:GetIndexBufferAddress()
	if not self.index_buffer then return 0 end

	return self.index_buffer:GetBuffer():GetDeviceAddress()
end

function Mesh:Upload()
	self.vertex_buffer:Upload()
end

function Mesh:UpdateBuffer()
	return self:Upload()
end

function Mesh:SetMode(mode)
	self.mode = normalize_primitive_topology(mode)
end

function Mesh:GetMode()
	return normalize_primitive_topology(self.mode)
end

function Mesh:SetDrawHint(usage)
	self.draw_hint = usage
end

function Mesh:GetDrawHint()
	return self.draw_hint
end

-- Compute AABB from vertex positions
function Mesh:ComputeAABB()
	local AABB = import("goluwa/structs/aabb.lua")
	local vertices = self:GetVertices()

	if not vertices or self.vertex_buffer.vertex_count == 0 then
		return AABB(0, 0, 0, 0, 0, 0)
	end

	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
	-- Check if we have structured vertices or raw float array
	local attrs = self.vertex_buffer.vertex_attributes
	local has_lua_type = attrs[1] and attrs[1].lua_type

	if has_lua_type then
		-- Structured vertices with position accessor
		for i = 0, self.vertex_buffer.vertex_count - 1 do
			local v = vertices[i]
			-- Access position - assumes first attribute is position (vec3)
			local x, y, z = v.position[0], v.position[1], v.position[2]

			if x < min_x then min_x = x end

			if y < min_y then min_y = y end

			if z < min_z then min_z = z end

			if x > max_x then max_x = x end

			if y > max_y then max_y = y end

			if z > max_z then max_z = z end
		end
	else
		-- Raw float array - position is first 3 floats of each vertex
		local stride_floats = self.vertex_buffer.stride / require("ffi").sizeof("float")

		for i = 0, self.vertex_buffer.vertex_count - 1 do
			local base = i * stride_floats
			local x, y, z = vertices[base + 0], vertices[base + 1], vertices[base + 2]

			if x < min_x then min_x = x end

			if y < min_y then min_y = y end

			if z < min_z then min_z = z end

			if x > max_x then max_x = x end

			if y > max_y then max_y = y end

			if z > max_z then max_z = z end
		end
	end

	return AABB(min_x, min_y, min_z, max_x, max_y, max_z)
end

function Mesh:UploadIndices(indices, index_type)
	if not self.index_buffer then
		self.index_buffer = IndexBuffer.New(indices, index_type)
	else
		-- Update existing index buffer
		self.index_buffer.indices = indices
		self.index_buffer.index_count = #indices
		local index_data = ffi.new(self.index_buffer.index_type .. "[?]", #indices)

		for i, idx in ipairs(indices) do
			index_data[i - 1] = idx
		end

		local byte_size = ffi.sizeof(self.index_buffer.index_type) * #indices
		self.index_buffer.byte_size = byte_size

		if not self.index_buffer.buffer or self.index_buffer.buffer_size ~= byte_size then
			self.index_buffer.buffer = render.CreateBuffer{
				buffer_usage = "index_buffer",
				data_type = self.index_buffer.index_type,
				data = index_data,
				byte_size = byte_size,
			}
			self.index_buffer.buffer_size = byte_size
		else
			self.index_buffer.buffer:CopyData(index_data, byte_size)
		end
	end
end

return Mesh:Register()
