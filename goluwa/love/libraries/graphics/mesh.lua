return function(ctx)
	local love = ctx.love
	local line = ctx.line
	local render = ctx.render
	local render2d = ctx.render2d
	local RenderMesh = ctx.RenderMesh
	local IndexBuffer = ctx.IndexBuffer
	local get_api_default_alpha = ctx.get_api_default_alpha
	local Mesh = line.TypeTemplate("Mesh")
	local attribute_translation = {
		VertexPosition = "pos",
		VertexTexCoord = "uv",
		VertexColor = "color",
	}
	local reverse_attribute_translation = {
		pos = "VertexPosition",
		uv = "VertexTexCoord",
		color = "VertexColor",
	}

	local function get_attribute_name_from_info(info)
		return attribute_translation[info[1]] or info[1]
	end

	local function get_vertex_format_component_count(info)
		return info[3] or 1
	end

	local function get_vertex_attribute_format(component_count)
		if component_count == 4 then return "r32g32b32a32_sfloat" end

		if component_count == 3 then return "r32g32b32_sfloat" end

		if component_count == 2 then return "r32g32_sfloat" end

		return "r32_sfloat"
	end

	local function build_render_vertex_attributes(vertex_format)
		local out = {}
		local offset = 0

		for i, info in ipairs(vertex_format) do
			local component_count = get_vertex_format_component_count(info)
			out[i] = {
				lua_name = get_attribute_name_from_info(info),
				offset = offset,
				format = get_vertex_attribute_format(component_count),
			}
			offset = offset + component_count * 4
		end

		return out
	end

	local function triangle_list_indices(mode, source_indices)
		mode = mode or "triangles"

		if mode == "triangles" or mode == "triangle_list" then
			return source_indices
		elseif mode == "triangle_strip" or mode == "strip" then
			local out = {}

			for i = 1, #source_indices - 2 do
				local a = source_indices[i]
				local b = source_indices[i + 1]
				local c = source_indices[i + 2]

				if i % 2 == 0 then a, b = b, a end

				list.insert(out, a)
				list.insert(out, b)
				list.insert(out, c)
			end

			return out
		elseif mode == "triangle_fan" or mode == "fan" then
			local out = {}
			local first = source_indices[1]

			for i = 2, #source_indices - 1 do
				list.insert(out, first)
				list.insert(out, source_indices[i])
				list.insert(out, source_indices[i + 1])
			end

			return out
		end

		return source_indices
	end

	local function rebuild_index_buffer(self)
		local source_indices = self.vertex_map or {}
		local draw_indices = triangle_list_indices(self.draw_mode, source_indices)
		self.index_buffer.indices = draw_indices
		self.index_buffer.index_count = #draw_indices
		self.index_buffer:UpdateBuffer()
	end

	local function is_vertex_format_table(tbl)
		if type(tbl) ~= "table" then return false end

		local first = tbl[1]
		return type(first) == "table" and
			type(first[1]) == "string" and
			type(first[2]) == "string" and
			type(first[3]) == "number"
	end

	function love.graphics.newMesh(...)
		local vertices
		local vertex_count
		local vertex_format
		local mode
		local usage
		local texture

		if
			type(select(1, ...)) == "table" and
			(
				line.Type(select(2, ...)) == "Image" or
				line.Type(select(2, ...)) == "Canvas"
			)
		then
			vertices, texture, mode = ...
			vertex_count = #vertices
		elseif is_vertex_format_table(select(1, ...)) and type(select(2, ...)) == "table" then
			vertex_format, vertices, mode, usage = ...
			vertex_count = #vertices
		elseif is_vertex_format_table(select(1, ...)) and type(select(2, ...)) == "number" then
			vertex_format, vertex_count, mode, usage = ...
		elseif type(select(1, ...)) == "number" then
			vertex_count, mode, usage = ...
		elseif type(select(1, ...)) == "table" then
			vertices, mode, usage = ...
			vertex_count = #vertices
		end

		local self = line.CreateObject("Mesh")
		local resolved_vertex_format = vertex_format or
			{
				{"VertexPosition", "float", 2},
				{"VertexTexCoord", "float", 2},
				{"VertexColor", "float", 4},
			}

		if vertex_format then
			self.vertex_buffer = RenderMesh.New(build_render_vertex_attributes(resolved_vertex_format), vertex_count)
		else
			self.vertex_buffer = render2d.CreateMesh(vertex_count)
		end

		local mesh_idx = IndexBuffer.New()
		mesh_idx:LoadIndices(vertex_count)
		self.index_buffer = mesh_idx
		self.draw_mode = "triangles"
		self.vertex_map = {}

		for i = 1, vertex_count do
			self.vertex_map[i] = i - 1
		end

		self.vertex_format = resolved_vertex_format
		self.vertex_buffer:SetDrawHint(usage)
		self:setDrawMode(mode)

		if vertices then self:setVertices(vertices) end

		if texture then self:setTexture(texture) end

		return self
	end

	function Mesh:setTexture(tex)
		self.img = tex
	end

	function Mesh:getTexture()
		return self.img
	end

	Mesh.setImage = Mesh.setTexture
	Mesh.getImage = Mesh.getTexture

	function Mesh:setVertices(vertices)
		for i, v in ipairs(vertices) do
			self:setVertex(i, v)
		end

		self.vertex_buffer:UpdateBuffer()
	end

	function Mesh:getVertices()
		local out = {}

		for i = 1, self.vertex_buffer:GetVertexCount() do
			out[i] = {self:getVertex(i)}
		end

		return out
	end

	function Mesh:setVertex(index, vertex, ...)
		if type(vertex) == "number" then vertex = {vertex, ...} end

		local source_index = 1

		for _, info in ipairs(self.vertex_format) do
			local component_count = get_vertex_format_component_count(info)
			local values = {}

			for component_index = 1, component_count do
				values[component_index] = vertex and vertex[source_index] or nil
				source_index = source_index + 1
			end

			if not vertex then
				for component_index = 1, component_count do
					values[component_index] = 0
				end
			elseif component_count == 2 and values[1] ~= nil and values[2] == nil then
				values[2] = values[1]
			end

			if info[1] == "VertexColor" then
				for component_index = 1, 4 do
					local value = values[component_index]

					if value == nil then
						value = component_index == 4 and get_api_default_alpha() or get_api_default_alpha()
					end

					if value > 1 then
						values[component_index] = value / 255
					else
						values[component_index] = value
					end
				end
			else
				for component_index = 1, component_count do
					values[component_index] = values[component_index] or 0
				end
			end

			self.vertex_buffer:SetVertex(index, get_attribute_name_from_info(info), unpack(values, 1, component_count))
		end

		self._line_dirty_buffers = true
	end

	function Mesh:getVertex(index)
		local out = {}

		for _, info in ipairs(self.vertex_format) do
			local values = {self.vertex_buffer:GetVertex(index, get_attribute_name_from_info(info))}

			for component_index = 1, get_vertex_format_component_count(info) do
				out[#out + 1] = values[component_index]
			end
		end

		return unpack(out)
	end

	function Mesh:setDrawRange(min, max)
		self.draw_range_min = min
		self.draw_range_max = max
	end

	function Mesh:getDrawRange()
		return self.draw_range_min, self.draw_range_max
	end

	function Mesh:Draw()
		local count = self.draw_range_max or self.index_buffer:GetIndexCount()
		self.vertex_buffer:Draw(self.index_buffer, count)
	end

	function Mesh:DrawInstanced(instance_count, extra_vertex_buffers)
		instance_count = instance_count or 1
		local count = self.draw_range_max or
			(
				(
					self.index_buffer and
					self.index_buffer:GetIndexCount()
				) or
				self.vertex_buffer:GetVertexCount()
			)

		if self.index_buffer then
			if not render2d.cmd then
				error(
					"Cannot draw without active command buffer. Must be called during Draw2D event.",
					2
				)
			end

			self.vertex_buffer:BindInstanced(render2d.cmd, extra_vertex_buffers, 0)
			render2d.cmd:BindIndexBuffer(self.index_buffer:GetBuffer(), 0, self.index_buffer:GetIndexType())
			render2d.cmd:DrawIndexed(count, instance_count, 0, 0, 0)
			return
		end

		self.vertex_buffer:DrawInstanced(instance_count, extra_vertex_buffers, count)
	end

	function Mesh:setVertexColors() end

	function Mesh:hasVertexColors()
		return true
	end

	function Mesh:setVertexMap(...)
		local indices = type(...) == "table" and ... or {...}
		self.vertex_map = {}

		for i, i2 in ipairs(indices) do
			self.vertex_map[i] = i2 - 1
		end

		rebuild_index_buffer(self)
	end

	function Mesh:getVertexMap()
		local out = {}
		local data = self.vertex_map

		for i = 1, #data do
			out[i] = data[i] + 1
		end

		return out
	end

	function Mesh:getVertexCount()
		return self.vertex_buffer:GetVertexCount()
	end

	do
		local function get_attribute_name(self, pos)
			local info = self.vertex_format[pos]

			if not info then
				error("unknown vertex attribute index: " .. tostring(pos), 2)
			end

			return get_attribute_name_from_info(info)
		end

		function Mesh:setVertexAttribute(index, pos, ...)
			self.vertex_buffer:SetVertex(index, get_attribute_name(self, pos), ...)
			self._line_dirty_buffers = true
		end

		function Mesh:getVertexAttribute(index, pos)
			return self.vertex_buffer:GetVertex(index, get_attribute_name(self, pos))
		end
	end

	function Mesh:setAttributeEnabled(name, enable) end

	function Mesh:isAttributeEnabled() end

	function Mesh:attachAttribute(name, mesh, step)
		self.attached_attributes = self.attached_attributes or {}
		self.attached_attributes[name] = {
			mesh = mesh,
			step = step,
		}
	end

	function Mesh:getVertexAttributeByName(index, name)
		return self.vertex_buffer:GetVertex(index, name)
	end

	do
		function Mesh:getVertexFormat()
			local out = {}

			for _, info in ipairs(self.vertex_format) do
				list.insert(out, {reverse_attribute_translation[info[1]] or info[1], info[2], info[3]})
			end

			return out
		end
	end

	function Mesh:UpdateBuffers()
		self.vertex_buffer:UpdateBuffer()
		rebuild_index_buffer(self)
		self._line_dirty_buffers = false
	end

	function Mesh:flush()
		self:UpdateBuffers()
	end

	do
		local tr = {
			triangles = "triangle_list",
			fan = "triangle_fan",
			strip = "triangle_strip",
			points = "point_list",
			lines = "line_list",
		}

		function Mesh:setDrawMode(mode)
			self.draw_mode = tr[mode] or mode or "triangles"
			self.vertex_buffer:SetMode(self.draw_mode)
			rebuild_index_buffer(self)
		end

		local tr2 = {}

		for k, v in pairs(tr) do
			tr2[v] = k
		end

		function Mesh:getDrawMode()
			local mode = self.draw_mode or self.vertex_buffer:GetMode()
			return tr2[mode] or mode
		end
	end

	line.RegisterType(Mesh)
end
