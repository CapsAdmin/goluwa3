local objects = import("goluwa/objects/objects.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local math3d = import("goluwa/render3d/math3d.lua")
local static_geometry = import("goluwa/source_engine/static_geometry.lua")
local world_pack = import("goluwa/source_engine/world_pack.lua")
local units = import("goluwa/source_engine/units.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("displacement")
META:StartStorable()
META:GetSet("Corners", nil, {Hidden = true})
META:GetSet("Positions", nil, {Hidden = true})
META:GetSet("Alphas", nil, {Hidden = true})
META:GetSet("Material", "", {asset = "materials", callback = "OnShapeChanged"})
META:GetSet("Vecs", nil, {Hidden = true})
META:EndStorable()
-- Positions are the points of the (2^power + 1) squared grid in source space as they were when the entity was
-- created, the entity's transform moves them from there. A static world below the displacement batches and collides it.
local REST_EPSILON = 1e-5
local MATRIX_FIELDS = {
	"m00",
	"m01",
	"m02",
	"m03",
	"m10",
	"m11",
	"m12",
	"m13",
	"m20",
	"m21",
	"m22",
	"m23",
	"m30",
	"m31",
	"m32",
	"m33",
}

-- the big tables are stored as packed float strings
function META:GetCorners()
	if not self.Corners then return nil end

	local flat = {}

	for i, corner in ipairs(self.Corners) do
		flat[i * 3 - 2], flat[i * 3 - 1], flat[i * 3] = corner.x, corner.y, corner.z
	end

	return world_pack.PackFloats(flat)
end

function META:SetCorners(value)
	local flat = world_pack.UnpackFloats(value)
	self.Corners = {}

	for i = 1, #flat / 3 do
		self.Corners[i] = Vec3(flat[i * 3 - 2], flat[i * 3 - 1], flat[i * 3])
	end
end

function META:GetPositions()
	return self.Positions and world_pack.PackFloats(self.Positions)
end

function META:SetPositions(value)
	self.Positions = world_pack.UnpackFloats(value)
	self.dims = nil
	self.polygons = nil
	self:OnShapeChanged()
end

function META:GetAlphas()
	return self.Alphas and world_pack.PackFloats(self.Alphas)
end

function META:SetAlphas(value)
	self.Alphas = world_pack.UnpackFloats(value)
	self.polygons = nil
end

-- the grid in engine space relative to its center, computed on first use
function META:EnsureGrid()
	if self.dims then return end

	local positions = self.Positions
	local dims = math.floor(math.sqrt(#positions / 3) + 0.5)
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for i = 1, dims * dims do
		local x, y, z = positions[i * 3 - 2], positions[i * 3 - 1], positions[i * 3]
		min_x, min_y, min_z = math.min(min_x, x), math.min(min_y, y), math.min(min_z, z)
		max_x, max_y, max_z = math.max(max_x, x), math.max(max_y, y), math.max(max_z, z)
	end

	self.center = units.PositionToEngine(Vec3((min_x + max_x) / 2, (min_y + max_y) / 2, (min_z + max_z) / 2))
	local local_points = {}

	for i = 1, dims * dims do
		local_points[i] = units.PositionToEngine(Vec3(positions[i * 3 - 2], positions[i * 3 - 1], positions[i * 3])) - self.center
	end

	self.local_points = local_points
	self.dims = dims
end

function META:GetCenter()
	self:EnsureGrid()
	return self.center
end

function META:OnShapeChanged()
	self.polygons = nil

	if self.world then self.world:MarkDirty(self) end
end

function META:CreateRecord()
	return {kind = "displacement", spans = {}}
end

function META:UpdateRecord(record)
	self:EnsureGrid()
	local dims, positions = self.dims, {}
	local transform = self.Owner.transform
	local flat = self.Positions
	local rotation = transform:GetRotation()
	local at_rest = (
			transform:GetPosition() - self.center
		):GetLength() < REST_EPSILON and
		math.abs(rotation.x) + math.abs(rotation.y) + math.abs(rotation.z) < REST_EPSILON and
		transform:GetScale() == Vec3(1, 1, 1)
		and
		transform:GetSize() == 1

	if at_rest then
		for i = 1, dims * dims do
			positions[i] = Vec3(flat[i * 3 - 2], flat[i * 3 - 1], flat[i * 3])
		end
	else
		local matrix = transform:GetWorldMatrix()

		for i = 1, dims * dims do
			positions[i] = units.PositionFromEngine(matrix:TransformVector(self.local_points[i]))
		end
	end

	record.dims = dims
	record.positions = positions
	record.alphas = self.Alphas
	record.corners = self.Corners
	record.texname = self.Material:match("^materials/(.*)%.vmt$")
	record.vecs = self.Vecs
	static_geometry.UpdateDisplacementBounds(record)
	local sum = Vec3(0, 0, 0)

	for _, normal in ipairs(static_geometry.ComputeDisplacementNormals(record)) do
		sum = sum + normal
	end

	record.normal = units.PositionFromEngine(sum):GetNormalized()
end

function META:Attach()
	local world = static_world.Find(self.Owner)

	if world then
		self.world = world
		world:AddSource(self)
	end
end

function META:OnDeserialized()
	self.Owner:SetTransient(false)
	self:Attach()
end

function META:OnRemove()
	if self.world and self.world:IsValid() then self.world:RemoveSource(self) end
end

-- the grid as a polygon in the entity's local space, for highlighting
function META:GetPolygons()
	if self.polygons then return self.polygons end

	self:EnsureGrid()
	local dims, local_points = self.dims, self.local_points
	local corners, vecs = self.Corners, self.Vecs
	local uvs, nx, ny, nz = {}, {}, {}, {}

	for y = 1, dims do
		for x = 1, dims do
			local i = (y - 1) * dims + x
			local flat = math3d.BilerpVec3(
				corners[1],
				corners[2],
				corners[3],
				corners[4],
				(y - 1) / (dims - 1),
				(x - 1) / (dims - 1)
			)
			uvs[i] = Vec2(
				vecs[1] * flat.x + vecs[2] * flat.y + vecs[3] * flat.z + vecs[4],
				vecs[5] * flat.x + vecs[6] * flat.y + vecs[7] * flat.z + vecs[8]
			)
			nx[i], ny[i], nz[i] = 0, 0, 0
		end
	end

	local triangles = {}

	for x = 1, dims - 1 do
		for y = 1, dims - 1 do
			local a = y * dims + x
			local b = (y - 1) * dims + x
			local c = a + 1
			local d = b + 1
			list.insert(triangles, {a, c, b})
			list.insert(triangles, {c, d, b})
		end
	end

	for _, triangle in ipairs(triangles) do
		local v1, v2, v3 = triangle[1], triangle[2], triangle[3]
		local normal = (local_points[v3] - local_points[v1]):Cross(local_points[v2] - local_points[v1])

		for _, index in ipairs(triangle) do
			nx[index], ny[index], nz[index] = nx[index] + normal.x, ny[index] + normal.y, nz[index] + normal.z
		end
	end

	local polygon = Polygon3D.New()

	for _, triangle in ipairs(triangles) do
		for _, index in ipairs(triangle) do
			polygon:AddVertex{
				pos = local_points[index],
				uv = uvs[index],
				normal = Vec3(nx[index], ny[index], nz[index]):GetNormalized(),
				texture_blend = math.clamp(self.Alphas[index] / 255, 0, 1),
			}
		end
	end

	polygon:BuildBoundingBox()
	polygon:BuildTangents()
	polygon:Upload(nil)
	self.polygons = {polygon}
	return self.polygons
end

-- watches the transform so moving the entity moves the displacement
function META:Activate()
	if self.active then return end

	self.active = true
	self.last_matrix = self.Owner.transform:GetWorldMatrix():Copy()
	self:AddGlobalEvent("Update")
end

function META:OnUpdate()
	local matrix = self.Owner.transform:GetWorldMatrix()
	local last = self.last_matrix

	for _, field in ipairs(MATRIX_FIELDS) do
		if matrix[field] ~= last[field] then
			self.last_matrix = matrix:Copy()
			self:OnShapeChanged()

			break
		end
	end
end

return META:Register()
