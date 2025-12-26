local prototype = require("prototype")
local AABB = require("structs.aabb")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Mesh = require("render.mesh")
local ffi = require("ffi")
local tasks = require("tasks")
local Polygon3D = prototype.CreateTemplate("polygon_3d")

function Polygon3D.New()
	local self = Polygon3D:CreateObject()
	self.sub_meshes = {}
	return self
end

function Polygon3D:__tostring2()
	return ("[%i vertices]"):format(#self.Vertices)
end

Polygon3D:GetSet("Vertices", {})
Polygon3D:GetSet("AABB", AABB())
Polygon3D.i = 1

function Polygon3D:AddVertex(vertex)
	self.Vertices[self.i] = vertex
	self.i = self.i + 1
end

function Polygon3D:Clear()
	self.i = 1
	list.clear(self.Vertices)
end

function Polygon3D:UnreferenceVertices()
	if self.mesh then self.mesh = nil end

	self:Clear()
end

function Polygon3D:GetMesh()
	return self.mesh
end

function Polygon3D:Upload()
	-- Convert Lua table vertices to FFI structured array
	local vertex_count = #self.Vertices

	if vertex_count == 0 then return end

	-- Define vertex structure matching render3d pipeline: position (vec3), normal (vec3), uv (vec2)
	local VertexType = ffi.typeof([[
		struct {
			float position[3];
			float normal[3];
			float uv[2];
		}[?]
	]])
	local vertices = VertexType(vertex_count)

	-- Copy vertex data from Lua tables to FFI array
	for i = 1, vertex_count do
		local v = self.Vertices[i]
		local idx = i - 1

		-- Position
		if v.pos then
			vertices[idx].position[0] = v.pos.x or v.pos[1] or 0
			vertices[idx].position[1] = v.pos.y or v.pos[2] or 0
			vertices[idx].position[2] = v.pos.z or v.pos[3] or 0
		end

		-- Normal
		if v.normal then
			vertices[idx].normal[0] = v.normal.x or v.normal[1] or 0
			vertices[idx].normal[1] = v.normal.y or v.normal[2] or 0
			vertices[idx].normal[2] = v.normal.z or v.normal[3] or 0
		else
			vertices[idx].normal[0] = 0
			vertices[idx].normal[1] = 0
			vertices[idx].normal[2] = 1
		end

		-- UV
		if v.uv then
			vertices[idx].uv[0] = v.uv.x or v.uv[1] or 0
			vertices[idx].uv[1] = v.uv.y or v.uv[2] or 0
		end
	end

	-- Define vertex attributes matching the render3d pipeline
	local vertex_attributes = {
		{
			binding = 0,
			location = 0,
			format = "r32g32b32_sfloat",
			offset = 0,
		},
		{
			binding = 0,
			location = 1,
			format = "r32g32b32_sfloat",
			offset = ffi.sizeof("float") * 3,
		},
		{
			binding = 0,
			location = 2,
			format = "r32g32_sfloat",
			offset = ffi.sizeof("float") * 6,
		},
		{
			binding = 0,
			location = 3,
			format = "r32g32b32a32_sfloat",
			offset = ffi.sizeof("float") * 8,
		},
	}
	-- Collect indices from sub_meshes if they exist
	local indices = nil

	if #self.sub_meshes > 0 then
		local all_indices = {}
		local current_offset = 0

		for _, sub_mesh in ipairs(self.sub_meshes) do
			if sub_mesh.indices then
				sub_mesh.index_offset = current_offset
				sub_mesh.index_count = #sub_mesh.indices

				for _, idx in ipairs(sub_mesh.indices) do
					table.insert(all_indices, idx)
				end

				current_offset = current_offset + sub_mesh.index_count
			end
		end

		if #all_indices > 0 then indices = all_indices end
	end

	local index_type = "uint16_t"

	if vertex_count > 65535 then index_type = "uint32_t" end

	self.mesh = Mesh.New(vertex_attributes, vertices, indices, index_type)
end

function Polygon3D:AddSubMesh(val, data)
	-- Handle both vertex count/table (for generating sequential indices) or explicit indices (table of numbers)
	local indices

	if type(val) == "number" then
		-- Create sequential indices [0, 1, 2, ...]
		indices = {}

		for i = 1, val do
			indices[i] = i - 1
		end
	elseif type(val) == "table" then
		-- Check if it's a vertex table or indices table
		-- If first element is a table/vertex, treat it as vertices and generate indices
		if type(val[1]) == "table" then
			-- It's vertices, generate sequential indices
			indices = {}

			for i = 1, #val do
				indices[i] = i - 1
			end
		else
			-- It's already indices
			indices = val
		end
	else
		error(
			"AddSubMesh expects a number (vertex count), table of vertices, or table of indices"
		)
	end

	table.insert(self.sub_meshes, {indices = indices, data = data})
end

function Polygon3D:GetSubMeshes()
	return self.sub_meshes or {}
end

function Polygon3D:Draw(cmd, i)
	if not self.mesh then return end

	self.mesh:Bind(cmd)

	if i and self.sub_meshes[i] then
		local sub_mesh = self.sub_meshes[i]

		if self.mesh.index_buffer then
			self.mesh:DrawIndexed(cmd, sub_mesh.index_count, 1, sub_mesh.index_offset)
		else
			self.mesh:Draw(cmd)
		end
	else
		-- Draw entire mesh
		if self.mesh.index_buffer then
			self.mesh:DrawIndexed(cmd)
		else
			self.mesh:Draw(cmd)
		end
	end
end

do -- helpers
	function Polygon3D:BuildBoundingBox()
		for _, sub_mesh in ipairs(self:GetSubMeshes()) do
			for i = 1, #sub_mesh.indices do
				local idx = sub_mesh.indices[i]

				if idx then
					local vtx = self.Vertices[idx]

					if vtx then
						self.AABB:ExpandVec3(self.Vertices[sub_mesh.indices[i]].pos)
					end
				end
			end
		end
	end

	local function build_normal(a, b, c)
		if a.normal and b.normal and c.normal then return end

		-- For counter-clockwise winding: (B-A) × (C-A)
		local normal = (b.pos - a.pos):Cross(c.pos - a.pos):GetNormalized()
		a.normal = normal
		b.normal = normal
		c.normal = normal
		tasks.Wait()
	end

	function Polygon3D:BuildNormals()
		for _, sub_mesh in ipairs(self:GetSubMeshes()) do
			for i = 1, #sub_mesh.indices, 3 do
				local a = self.Vertices[sub_mesh.indices[i + 0] + 1]
				local b = self.Vertices[sub_mesh.indices[i + 1] + 1]
				local c = self.Vertices[sub_mesh.indices[i + 2] + 1]
				build_normal(a, b, c)
			end
		end
	end

	function Polygon3D:IterateFaces(cb)
		for _, sub_mesh in ipairs(self:GetSubMeshes()) do
			for i = 1, #sub_mesh.indices, 3 do
				local ai = sub_mesh.indices[i + 0] + 1
				local bi = sub_mesh.indices[i + 1] + 1
				local ci = sub_mesh.indices[i + 2] + 1
				cb(self.Vertices[ai], self.Vertices[bi], self.Vertices[ci])
			end
		end
	end

	function Polygon3D:SmoothNormals()
		local temp = {}
		local i = 1

		for _, vertex in ipairs(self.Vertices) do
			local x, y, z = vertex.pos.x, vertex.pos.y, vertex.pos.z
			temp[x] = temp[x] or {}
			temp[x][y] = temp[x][y] or {}
			temp[x][y][z] = temp[x][y][z] or {}
			temp[x][y][z][i] = vertex
			i = i + 1
		end

		for _, x in pairs(temp) do
			for _, y in pairs(x) do
				for _, z in pairs(y) do
					local normal = Vec3(0)

					for _, vertex in pairs(z) do
						normal = normal + vertex.normal
					end

					normal:Normalize()

					for _, vertex in pairs(z) do
						vertex.normal = normal
					end

					tasks.Wait()
				end
			end
		end
	end

	--[[
		2___1
		|  /
	   3|/
	]]
	function Polygon3D:LoadObj(data, generate_normals)
		local positions = {}
		local texcoords = {}
		local normals = {}
		local output = {}
		local lines = {}
		local i = 1

		for line in data:gmatch("(.-)\n") do
			local parts = line:gsub("%s+", " "):trim():split(" ")
			list.insert(lines, parts)
			tasks.ReportProgress("inserting lines", math.huge)
			tasks.Wait()
			i = i + 1
		end

		local vert_count = #lines

		for _, parts in pairs(lines) do
			if parts[1] == "v" and #parts >= 4 then
				list.insert(positions, Vec3(tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4])))
			elseif parts[1] == "vt" and #parts >= 3 then
				list.insert(texcoords, Vec2(tonumber(parts[2]), tonumber(parts[3])))
			elseif not generate_normals and parts[1] == "vn" and #parts >= 4 then
				list.insert(
					normals,
					Vec3(tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4])):GetNormalized()
				)
			end

			self:ReportProgress("parsing lines", vert_count)
			self:Wait()
		end

		for _, parts in pairs(lines) do
			if parts[1] == "f" and #parts > 3 then
				local first, previous

				for i = 2, #parts do
					local current = parts[i]:split("/")

					if i == 2 then first = current end

					if i >= 4 then
						local v1, v2, v3 = {}, {}, {}
						v1.pos_index = tonumber(first[1])
						v2.pos_index = tonumber(current[1])
						v3.pos_index = tonumber(previous[1])
						v1.pos = positions[tonumber(first[1])]
						v2.pos = positions[tonumber(current[1])]
						v3.pos = positions[tonumber(previous[1])]

						if #texcoords > 0 then
							v1.uv = texcoords[tonumber(first[2])]
							v2.uv = texcoords[tonumber(current[2])]
							v3.uv = texcoords[tonumber(previous[2])]
						end

						if #normals > 0 then
							v1.normal = normals[tonumber(first[3])]
							v2.normal = normals[tonumber(current[3])]
							v3.normal = normals[tonumber(previous[3])]
						end

						list.insert(output, v1)
						list.insert(output, v2)
						list.insert(output, v3)
					end

					previous = current
				end
			end

			tasks.ReportProgress("solving indices", vert_count)
			tasks.Wait()
		end

		if generate_normals then
			local vertex_normals = {}
			local count = #output / 3

			for i = 1, count do
				local a, b, c = output[1 + (i - 1) * 3 + 0], output[1 + (i - 1) * 3 + 1], output[1 + (i - 1) * 3 + 2]
				-- For counter-clockwise winding: (B-A) × (C-A)
				local normal = (b.pos - a.pos):Cross(c.pos - a.pos):GetNormalized()
				vertex_normals[a.pos_index] = vertex_normals[a.pos_index] or Vec3()
				vertex_normals[a.pos_index] = (vertex_normals[a.pos_index] + normal)
				vertex_normals[b.pos_index] = vertex_normals[b.pos_index] or Vec3()
				vertex_normals[b.pos_index] = (vertex_normals[b.pos_index] + normal)
				vertex_normals[c.pos_index] = vertex_normals[c.pos_index] or Vec3()
				vertex_normals[c.pos_index] = (vertex_normals[c.pos_index] + normal)
				tasks.ReportProgress("generating normals", count)
				tasks.Wait()
			end

			local default_normal = Vec3(0, 0, -1)

			for i = 1, count do
				local n = vertex_normals[output[i].pos_index] or default_normal
				n:Normalize()
				normals[i] = n
				output[i].normal = n
				tasks.ReportProgress("smoothing normals", count)
				tasks.Wait()
			end
		end

		return output
	end

	function Polygon3D:CreatePlane(pos, normal, right, up, size_x, size_y, texture_scale)
		size_x = size_x or 1
		size_y = size_y or 1
		texture_scale = texture_scale or 1
		local p1 = pos - right * size_x - up * size_y
		local p2 = pos + right * size_x - up * size_y
		local p3 = pos + right * size_x + up * size_y
		local p4 = pos - right * size_x + up * size_y
		-- Counter-clockwise winding when viewed from outside (along normal direction)
		-- Triangle 1: p1 -> p3 -> p2 (reversed to match sphere winding)
		self:AddVertex({pos = p1, uv = Vec2(0, 0), normal = normal})
		self:AddVertex({pos = p3, uv = Vec2(texture_scale, texture_scale), normal = normal})
		self:AddVertex({pos = p2, uv = Vec2(texture_scale, 0), normal = normal})
		-- Triangle 2: p1 -> p4 -> p3 (reversed to match sphere winding)
		self:AddVertex({pos = p1, uv = Vec2(0, 0), normal = normal})
		self:AddVertex({pos = p4, uv = Vec2(0, texture_scale), normal = normal})
		self:AddVertex({pos = p3, uv = Vec2(texture_scale, texture_scale), normal = normal})
	end

	function Polygon3D:CreateCube(size, texture_scale)
		size = size or 1
		texture_scale = texture_scale or 1
		-- Front face (+Z)
		self:CreatePlane(
			Vec3(0, 0, size),
			Vec3(0, 0, 1),
			Vec3(1, 0, 0),
			Vec3(0, 1, 0),
			size,
			size,
			texture_scale
		)
		-- Back face (-Z)
		self:CreatePlane(
			Vec3(0, 0, -size),
			Vec3(0, 0, -1),
			Vec3(-1, 0, 0),
			Vec3(0, 1, 0),
			size,
			size,
			texture_scale
		)
		-- Top face (+Y)
		self:CreatePlane(
			Vec3(0, size, 0),
			Vec3(0, 1, 0),
			Vec3(1, 0, 0),
			Vec3(0, 0, -1),
			size,
			size,
			texture_scale
		)
		-- Bottom face (-Y)
		self:CreatePlane(
			Vec3(0, -size, 0),
			Vec3(0, -1, 0),
			Vec3(1, 0, 0),
			Vec3(0, 0, 1),
			size,
			size,
			texture_scale
		)
		-- Right face (+X)
		self:CreatePlane(
			Vec3(size, 0, 0),
			Vec3(1, 0, 0),
			Vec3(0, 0, -1),
			Vec3(0, 1, 0),
			size,
			size,
			texture_scale
		)
		-- Left face (-X)
		self:CreatePlane(
			Vec3(-size, 0, 0),
			Vec3(-1, 0, 0),
			Vec3(0, 0, 1),
			Vec3(0, 1, 0),
			size,
			size,
			texture_scale
		)
	end

	function Polygon3D:CreateSphere(radius, segments, rings, texture_scale)
		radius = radius or 1
		segments = segments or 32 -- longitude divisions
		rings = rings or 16 -- latitude divisions
		texture_scale = texture_scale or 1

		-- ORIENTATION / TRANSFORMATION: Sphere for Y-up, X-right, Z-forward (right-handed)
		-- Uses UV sphere approach with counter-clockwise winding when viewed from outside
		for ring = 0, rings - 1 do
			local theta1 = (ring / rings) * math.pi
			local theta2 = ((ring + 1) / rings) * math.pi

			for seg = 0, segments - 1 do
				local phi1 = (seg / segments) * 2 * math.pi
				local phi2 = ((seg + 1) / segments) * 2 * math.pi
				-- Calculate positions for the quad corners
				-- Using Y-up coordinate system
				local x1 = radius * math.sin(theta1) * math.sin(phi1)
				local y1 = radius * math.cos(theta1)
				local z1 = radius * math.sin(theta1) * math.cos(phi1)
				local x2 = radius * math.sin(theta1) * math.sin(phi2)
				local y2 = radius * math.cos(theta1)
				local z2 = radius * math.sin(theta1) * math.cos(phi2)
				local x3 = radius * math.sin(theta2) * math.sin(phi2)
				local y3 = radius * math.cos(theta2)
				local z3 = radius * math.sin(theta2) * math.cos(phi2)
				local x4 = radius * math.sin(theta2) * math.sin(phi1)
				local y4 = radius * math.cos(theta2)
				local z4 = radius * math.sin(theta2) * math.cos(phi1)
				-- UV coordinates
				local u1 = (seg / segments) * texture_scale
				local u2 = ((seg + 1) / segments) * texture_scale
				local v1 = (ring / rings) * texture_scale
				local v2 = ((ring + 1) / rings) * texture_scale
				-- Normals (normalized position for a sphere centered at origin)
				local n1 = Vec3(x1, y1, z1):GetNormalized()
				local n2 = Vec3(x2, y2, z2):GetNormalized()
				local n3 = Vec3(x3, y3, z3):GetNormalized()
				local n4 = Vec3(x4, y4, z4):GetNormalized()

				-- First triangle (top-left, top-right, bottom-right)
				if ring > 0 then -- Skip degenerate triangles at top pole
					self:AddVertex({pos = Vec3(x1, y1, z1), uv = Vec2(u1, v1), normal = n1})
					self:AddVertex({pos = Vec3(x2, y2, z2), uv = Vec2(u2, v1), normal = n2})
					self:AddVertex({pos = Vec3(x3, y3, z3), uv = Vec2(u2, v2), normal = n3})
				end

				-- Second triangle (top-left, bottom-right, bottom-left)
				if ring < rings - 1 then -- Skip degenerate triangles at bottom pole
					self:AddVertex({pos = Vec3(x1, y1, z1), uv = Vec2(u1, v1), normal = n1})
					self:AddVertex({pos = Vec3(x3, y3, z3), uv = Vec2(u2, v2), normal = n3})
					self:AddVertex({pos = Vec3(x4, y4, z4), uv = Vec2(u1, v2), normal = n4})
				end
			end
		end
	end

	function Polygon3D:LoadHeightmap(tex, size, res, height, pow)
		size = size or Vec2(1024, 1024)
		res = res or Vec2(128, 128)
		height = height or -64
		pow = pow or 1
		local s = size / res
		local s2 = s / 2
		local pixel_advance = (Vec2(1, 1) / res) * tex:GetSize()

		local function get_color(x, y)
			local r, g, b, a = tex:GetRawPixelColor(x, y)
			return (((r + g + b + a) / 4) / 255) ^ pow
		end

		local offset = -Vec3(size.x, size.y, height) / 2

		for x = 0, res.x do
			local x2 = (x / res.x) * tex:GetSize().x

			for y = 0, res.y do
				local y2 = (y / res.y) * tex:GetSize().y
				y2 = -y2 + tex:GetSize().y -- fix me
				--[[
						  __
						|\ /|
						|/_\|
				]]
				local z3 = get_color(x2, y2) * height -- top left
				local z4 = get_color(x2 + pixel_advance.x, y2) * height -- top right
				local z1 = get_color(x2, y2 + pixel_advance.y) * height -- bottom left
				local z2 = get_color(x2 + pixel_advance.x, y2 + pixel_advance.y) * height -- bottom right
				local z5 = (z1 + z2 + z3 + z4) / 4
				local x = (x * s.x)
				local y = y * s.y
				--[[
					___
					\ /
				]]
				local a1 = {}
				a1.pos = Vec3(x, y, z1) + offset
				a1.uv = Vec2(a1.pos.x + offset.x, a1.pos.y + offset.y) / size
				self:AddVertex(a1)
				local b1 = {}
				b1.pos = Vec3(x + s.x, y, z2) + offset
				b1.uv = Vec2(b1.pos.x + offset.x, b1.pos.y + offset.y) / size
				self:AddVertex(b1)
				local c1 = {}
				c1.pos = Vec3(x + s2.x, y + s2.y, z5) + offset
				c1.uv = Vec2(c1.pos.x + offset.x, c1.pos.y + offset.y) / size
				self:AddVertex(c1)
				-- For counter-clockwise winding: (B-A) × (C-A)
				local normal = (b1.pos - a1.pos):Cross(c1.pos - a1.pos):GetNormalized()
				a1.normal = normal
				b1.normal = normal
				c1.normal = normal
				--[[
					 ___
					|\ /
					|/
				]]
				local a2 = {}
				a2.pos = Vec3(x, y, z1) + offset
				a2.uv = Vec2(a2.pos.x + offset.x, a2.pos.y + offset.y) / size
				self:AddVertex(a2)
				local b2 = {}
				b2.pos = Vec3(x + s2.x, y + s2.y, z5) + offset
				b2.uv = Vec2(b2.pos.x + offset.x, b2.pos.y + offset.y) / size
				self:AddVertex(b2)
				local c2 = {}
				c2.pos = Vec3(x, y + s.y, z3) + offset
				c2.uv = Vec2(c2.pos.x + offset.x, c2.pos.y + offset.y) / size
				self:AddVertex(c2)
				-- For counter-clockwise winding: (B-A) × (C-A)
				local normal = (b2.pos - a2.pos):Cross(c2.pos - a2.pos):GetNormalized()
				a2.normal = normal
				b2.normal = normal
				c2.normal = normal
				--[[
					___
				   |\_/
				   |/_\
				]]
				local a3 = {}
				a3.pos = Vec3(x, y + s.y, z3) + offset
				a3.uv = Vec2(a3.pos.x + offset.x, a3.pos.y + offset.y) / size
				self:AddVertex(a3)
				local b3 = {}
				b3.pos = Vec3(x + s2.x, y + s2.y, z5) + offset
				b3.uv = Vec2(b3.pos.x + offset.x, b3.pos.y + offset.y) / size
				self:AddVertex(b3)
				local c3 = {}
				c3.pos = Vec3(x + s.x, y + s.y, z4) + offset
				c3.uv = Vec2(c3.pos.x + offset.x, c3.pos.y + offset.y) / size
				self:AddVertex(c3)
				-- For counter-clockwise winding: (B-A) × (C-A)
				local normal = (b3.pos - a3.pos):Cross(c3.pos - a3.pos):GetNormalized()
				a3.normal = normal
				b3.normal = normal
				c3.normal = normal
				--[[
					___
				   |\_/|
				   |/_\|
				]]
				local a4 = {}
				a4.pos = Vec3(x + s2.x, y + s2.y, z5) + offset
				a4.uv = Vec2(a4.pos.x + offset.x, a4.pos.y + offset.y) / size
				self:AddVertex(a4)
				local b4 = {}
				b4.pos = Vec3(x + s.x, y, z2) + offset
				b4.uv = Vec2(b4.pos.x + offset.x, b4.pos.y + offset.y) / size
				self:AddVertex(b4)
				local c4 = {}
				c4.pos = Vec3(x + s.x, y + s.y, z4) + offset
				c4.uv = Vec2(c4.pos.x + offset.x, c4.pos.y + offset.y) / size
				self:AddVertex(c4)
				-- For counter-clockwise winding: (B-A) × (C-A)
				local normal = (b4.pos - a4.pos):Cross(c4.pos - a4.pos):GetNormalized()
				a4.normal = normal
				b4.normal = normal
				c4.normal = normal
				tasks.Wait()
			end
		end
	end
end

Polygon3D:Register()
return Polygon3D
