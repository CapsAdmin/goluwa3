local objects = import("goluwa/objects/objects.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Mesh = RENDER_2D and import("goluwa/render/mesh.lua")
local IndexBuffer = RENDER_2D and import("goluwa/render/index_buffer.lua")
local ffi = require("ffi")
local tasks = import("goluwa/tasks.lua")
local Polygon3D = objects.CreateTemplate("render3d_polygon_3d")

function Polygon3D.New()
	local self = Polygon3D:CreateObject()
	self.Vertices = {}
	self.i = 1
	self.mesh = NULL
	self:SetAABB(AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge))
	return self
end

function Polygon3D:__tostring2()
	return ("[%i vertices]"):format(#self.Vertices)
end

Polygon3D:GetSet("Vertices")
Polygon3D:GetSet("BendHeight", 0)
Polygon3D:GetSet("MaterialSlot", nil)
Polygon3D:GetSet(
	"AABB",
	AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)
)
Polygon3D.i = nil

function Polygon3D:AddVertex(vertex)
	self.Vertices[self.i] = vertex

	if vertex.pos then self.AABB:ExpandVec3(vertex.pos) end

	self.i = self.i + 1
end

function Polygon3D:Clear()
	self.i = 1
	list.clear(self.Vertices)
	self:SetAABB(AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge))
end

function Polygon3D:UnreferenceVertices()
	self.mesh = NULL
	self:Clear()
end

function Polygon3D:GetMesh()
	return self.mesh
end

local VertexType = ffi.typeof([[
	struct {
		float position[3];
		float normal[3];
		float uv[2];
		float tangent[4];
		float texture_blend;
		float vertex_color[4];
	}[?]
]])
Polygon3D.VertexType = VertexType
local VERTEX_ATTRIBUTES = {
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
	{
		binding = 0,
		location = 4,
		format = "r32_sfloat",
		offset = ffi.sizeof("float") * 12,
	},
	{
		binding = 0,
		location = 5,
		format = "r32g32b32a32_sfloat",
		offset = ffi.sizeof("float") * 13,
	},
}

function Polygon3D:UploadVertexArray(vertices, vertex_count, indices, index_count)
	local aabb = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for i = 0, vertex_count - 1 do
		local position = vertices[i].position
		local x, y, z = position[0], position[1], position[2]

		if x < aabb.min_x then aabb.min_x = x end

		if y < aabb.min_y then aabb.min_y = y end

		if z < aabb.min_z then aabb.min_z = z end

		if x > aabb.max_x then aabb.max_x = x end

		if y > aabb.max_y then aabb.max_y = y end

		if z > aabb.max_z then aabb.max_z = z end
	end

	self:SetAABB(aabb)
	self.indices = nil

	if Mesh then
		self.mesh = Mesh.NewDeduped(
			VERTEX_ATTRIBUTES,
			vertices,
			indices,
			vertex_count > 65535 and "uint32_t" or "uint16_t",
			index_count
		)
	end
end

function Polygon3D:Upload(indices)
	self.indices = indices

	if indices and type(indices) == "table" then
		local gpu_indices = {}

		for i = 1, #indices do
			gpu_indices[i] = indices[i] - 1
		end

		indices = gpu_indices
	end

	local vertex_count = #self.Vertices

	if vertex_count == 0 then return end

	self:BuildBoundingBox()

	if not self.Vertices[1].uv then self:BuildUVsPlanar() end

	if not self.Vertices[1].normal then self:BuildNormals() end

	if not self.Vertices[1].tangent then self:BuildTangents() end

	local vertices = VertexType(vertex_count)

	for i = 1, vertex_count do
		local v = self.Vertices[i]
		local idx = i - 1

		if v.pos then
			vertices[idx].position[0] = v.pos.x or v.pos[1] or 0
			vertices[idx].position[1] = v.pos.y or v.pos[2] or 0
			vertices[idx].position[2] = v.pos.z or v.pos[3] or 0
		end

		if v.normal then
			vertices[idx].normal[0] = v.normal.x or v.normal[1] or 0
			vertices[idx].normal[1] = v.normal.y or v.normal[2] or 0
			vertices[idx].normal[2] = v.normal.z or v.normal[3] or 0
		else
			vertices[idx].normal[0] = 0
			vertices[idx].normal[1] = 0
			vertices[idx].normal[2] = 1
		end

		if v.uv then
			vertices[idx].uv[0] = v.uv.x or v.uv[1] or 0
			vertices[idx].uv[1] = v.uv.y or v.uv[2] or 0
		end

		if v.tangent then
			vertices[idx].tangent[0] = v.tangent.x or v.tangent[1] or 0
			vertices[idx].tangent[1] = v.tangent.y or v.tangent[2] or 0
			vertices[idx].tangent[2] = v.tangent.z or v.tangent[3] or 0
			vertices[idx].tangent[3] = v.tangent.w or v.tangent[4] or 1
		else
			vertices[idx].tangent[0] = 0
			vertices[idx].tangent[1] = 0
			vertices[idx].tangent[2] = 0
			vertices[idx].tangent[3] = 1
		end

		vertices[idx].texture_blend = v.texture_blend or 0
		local vertex_color = v.vertex_color or v.color

		if vertex_color then
			vertices[idx].vertex_color[0] = vertex_color.r or vertex_color[1] or 0
			vertices[idx].vertex_color[1] = vertex_color.g or vertex_color[2] or 0
			vertices[idx].vertex_color[2] = vertex_color.b or vertex_color[3] or 0
			vertices[idx].vertex_color[3] = vertex_color.a or vertex_color[4] or 0
		else
			vertices[idx].vertex_color[0] = 0
			vertices[idx].vertex_color[1] = 0
			vertices[idx].vertex_color[2] = 0
			vertices[idx].vertex_color[3] = 0
		end
	end

	local vertex_attributes = VERTEX_ATTRIBUTES
	local index_type = "uint16_t"

	if vertex_count > 65535 then index_type = "uint32_t" end

	local index_count

	if indices then
		index_count = #indices
		indices = IndexBuffer.IndicesToArray(indices, index_type)
	end

	if Mesh then
		self.mesh = Mesh.NewDeduped(vertex_attributes, vertices, indices, index_type, index_count)
	end
end

function Polygon3D:CloneDynamic(vertex_buffer)
	local clone = Polygon3D.New()
	clone:SetAABB(self.AABB)
	clone:SetBendHeight(self.BendHeight)
	clone:SetMaterialSlot(self.MaterialSlot)
	clone.indices = self.indices
	clone.Skin = self.Skin
	clone.Dynamic = true
	clone.mesh = self.mesh:CloneDynamic(vertex_buffer)
	return clone
end

function Polygon3D:Draw()
	local mesh = self.mesh

	if not mesh:IsValid() then return end

	mesh:Draw()
end

do
	function Polygon3D:BuildBoundingBox()
		self:SetAABB(AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge))

		for _, vtx in ipairs(self.Vertices) do
			if vtx and vtx.pos then self.AABB:ExpandVec3(vtx.pos) end
		end
	end

	function Polygon3D:BuildUVsPlanar(scale, axis)
		scale = scale or 1
		axis = axis or "auto"

		for _, vertex in ipairs(self.Vertices) do
			local u, v

			if axis == "auto" then
				local n = vertex.normal or Vec3(0, 1, 0)
				local absX, absY, absZ = math.abs(n.x), math.abs(n.y), math.abs(n.z)

				if absY >= absX and absY >= absZ then
					u, v = vertex.pos.x, vertex.pos.z
				elseif absX >= absZ then
					u, v = vertex.pos.z, vertex.pos.y
				else
					u, v = vertex.pos.x, vertex.pos.y
				end
			elseif axis == "x" then
				u, v = vertex.pos.z, vertex.pos.y
			elseif axis == "y" then
				u, v = vertex.pos.x, vertex.pos.z
			else
				u, v = vertex.pos.x, vertex.pos.y
			end

			vertex.uv = Vec2(u * scale, v * scale)
		end
	end

	function Polygon3D:BuildUVsBox(scale)
		scale = scale or 1

		if not self.Vertices[1].normal then self:BuildNormals() end

		local indices = self.indices or {}

		if not self.indices then
			for i = 1, #self.Vertices do
				indices[i] = i
			end
		end

		for i = 1, #indices - 2, 3 do
			local ai = indices[i + 0]
			local bi = indices[i + 1]
			local ci = indices[i + 2]
			local a = self.Vertices[ai]
			local b = self.Vertices[bi]
			local c = self.Vertices[ci]
			local edge1 = b.pos - a.pos
			local edge2 = c.pos - a.pos
			local faceNormal = edge1:Cross(edge2):Normalize()
			local absX = math.abs(faceNormal.x)
			local absY = math.abs(faceNormal.y)
			local absZ = math.abs(faceNormal.z)

			for _, idx in ipairs({ai, bi, ci}) do
				local v = self.Vertices[idx]
				local u, vCoord

				if absY >= absX and absY >= absZ then
					u, vCoord = v.pos.x, v.pos.z
				elseif absX >= absZ then
					u, vCoord = v.pos.z, v.pos.y
				else
					u, vCoord = v.pos.x, v.pos.y
				end

				v.uv = Vec2(u * scale, vCoord * scale)
			end
		end
	end

	function Polygon3D:BuildNormals(flipped)
		local indices = self.indices or {}

		if not self.indices then
			for i = 1, #self.Vertices do
				indices[i] = i
			end
		end

		for i = 1, #indices - 2, 3 do
			local a = self.Vertices[indices[i + 0]]
			local b = self.Vertices[indices[i + 1]]
			local c = self.Vertices[indices[i + 2]]

			if a and b and c then
				local normal

				if flipped then
					normal = (c.pos - a.pos):Cross(b.pos - a.pos):GetNormalized()
				else
					normal = (b.pos - a.pos):Cross(c.pos - a.pos):GetNormalized()
				end

				a.normal = normal
				b.normal = normal
				c.normal = normal
			end
		end
	end

	function Polygon3D:BuildTangents()
		local tan1 = {}
		local tan2 = {}
		local indices = self.indices or {}
		local tangent_epsilon = 1e-9

		if not self.indices then
			for i = 1, #self.Vertices do
				indices[i] = i
			end
		end

		for i = 1, #indices - 2, 3 do
			local ai = indices[i + 0]
			local bi = indices[i + 1]
			local ci = indices[i + 2]
			local a = self.Vertices[ai]
			local b = self.Vertices[bi]
			local c = self.Vertices[ci]

			if a and b and c and a.uv and b.uv and c.uv then
				local x1 = b.pos.x - a.pos.x
				local x2 = c.pos.x - a.pos.x
				local y1 = b.pos.y - a.pos.y
				local y2 = c.pos.y - a.pos.y
				local z1 = b.pos.z - a.pos.z
				local z2 = c.pos.z - a.pos.z
				local s1 = b.uv.x - a.uv.x
				local s2 = c.uv.x - a.uv.x
				local t1 = b.uv.y - a.uv.y
				local t2 = c.uv.y - a.uv.y
				local denom = (s1 * t2 - s2 * t1)

				if math.abs(denom) > tangent_epsilon then
					local r = 1 / denom
					local sdir = Vec3(
						(t2 * x1 - t1 * x2) * r,
						(t2 * y1 - t1 * y2) * r,
						(t2 * z1 - t1 * z2) * r
					)
					local tdir = Vec3(
						(s1 * x2 - s2 * x1) * r,
						(s1 * y2 - s2 * y1) * r,
						(s1 * z2 - s2 * z1) * r
					)
					tan1[ai] = (tan1[ai] or Vec3()) + sdir
					tan1[bi] = (tan1[bi] or Vec3()) + sdir
					tan1[ci] = (tan1[ci] or Vec3()) + sdir
					tan2[ai] = (tan2[ai] or Vec3()) + tdir
					tan2[bi] = (tan2[bi] or Vec3()) + tdir
					tan2[ci] = (tan2[ci] or Vec3()) + tdir
				end
			end
		end

		for i = 1, #self.Vertices do
			local vertex = self.Vertices[i]

			if not vertex.tangent and vertex.normal then
				local normal = vertex.normal:GetNormalized()
				local tangent = tan1[i]
				local bitangent = tan2[i]

				if tangent then tangent = tangent - normal * normal:GetDot(tangent) end

				if not tangent or tangent:GetLengthSquared() <= tangent_epsilon then
					local projected_bitangent = bitangent and (bitangent - normal * normal:GetDot(bitangent)) or nil

					if projected_bitangent and projected_bitangent:GetLengthSquared() > tangent_epsilon then
						tangent = projected_bitangent:GetCross(normal)
					end
				end

				if not tangent or tangent:GetLengthSquared() <= tangent_epsilon then
					local reference = math.abs(normal.y) < 0.999 and Vec3(0, 1, 0) or Vec3(1, 0, 0)
					tangent = reference:GetCross(normal)
				end

				tangent = tangent:GetNormalized()
				local handedness = 1

				if bitangent and bitangent:GetLengthSquared() > tangent_epsilon then
					if normal:GetCross(tangent):GetDot(bitangent) < 0 then handedness = -1 end
				end

				vertex.tangent = {
					x = tangent.x,
					y = tangent.y,
					z = tangent.z,
					w = handedness,
				}
			end
		end
	end

	function Polygon3D:IterateFaces(cb)
		local indices = self.indices or {}

		if not self.indices then
			for i = 1, #self.Vertices do
				indices[i] = i
			end
		end

		for i = 1, #indices - 2, 3 do
			local ai = indices[i + 0]
			local bi = indices[i + 1]
			local ci = indices[i + 2]
			cb(self.Vertices[ai], self.Vertices[bi], self.Vertices[ci])
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
end

Polygon3D:Register()
return Polygon3D
