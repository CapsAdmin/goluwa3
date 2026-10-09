local objects = import("goluwa/objects/objects.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local static_geometry = import("goluwa/source_engine/static_geometry.lua")
local world_pack = import("goluwa/source_engine/world_pack.lua")
local units = import("goluwa/source_engine/units.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("static_mesh")
META:StartStorable()
META:GetSet("Vertices", nil, {Hidden = true})
META:GetSet("Material", "", {asset = "materials", callback = "OnShapeChanged"})
META:GetSet("Collide", true, {callback = "OnShapeChanged"})
META:EndStorable()
-- Vertices holds 9 floats per vertex, three vertices make a triangle: position in source space, uv, texture blend and the
-- engine space normal. The positions are as they were when the entity was created, the entity's transform moves them from
-- there. A static world below the mesh batches and collides it.
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

function META:GetVertices()
	return self.Vertices and world_pack.PackFloats(self.Vertices)
end

function META:SetVertices(value)
	self.Vertices = world_pack.UnpackFloats(value)
	self.local_points = nil
	self.polygons = nil
	self:OnShapeChanged()
end

-- the points in engine space relative to the center of their bounds, computed on first use
function META:EnsureLocalPoints()
	if self.local_points then return end

	local flat = self.Vertices
	local count = #flat / 9
	local points = {}
	local mins = Vec3(math.huge, math.huge, math.huge)
	local maxs = Vec3(-math.huge, -math.huge, -math.huge)

	for i = 1, count do
		local o = (i - 1) * 9
		points[i] = units.PositionToEngine(Vec3(flat[o + 1], flat[o + 2], flat[o + 3]))

		for _, axis in ipairs({"x", "y", "z"}) do
			mins[axis] = math.min(mins[axis], points[i][axis])
			maxs[axis] = math.max(maxs[axis], points[i][axis])
		end
	end

	self.center = (mins + maxs) / 2

	for i = 1, count do
		points[i] = points[i] - self.center
	end

	self.local_points = points
end

function META:GetCenter()
	self:EnsureLocalPoints()
	return self.center
end

function META:OnShapeChanged()
	self.polygons = nil

	if self.world then self.world:MarkDirty(self) end
end

function META:CreateRecord()
	return {kind = "mesh", spans = {}}
end

function META:UpdateRecord(record)
	self:EnsureLocalPoints()
	local flat = self.Vertices
	local count = #flat / 9
	local transform = self.Owner.transform
	local rotation = transform:GetRotation()
	local at_rest = (
			transform:GetPosition() - self.center
		):GetLength() < REST_EPSILON and
		math.abs(rotation.x) + math.abs(rotation.y) + math.abs(rotation.z) < REST_EPSILON and
		transform:GetScale() == Vec3(1, 1, 1)
		and
		transform:GetSize() == 1
	local positions, uvs, blends = {}, {}, {}
	local normals

	if at_rest then
		normals = {}
	else
		local matrix = transform:GetWorldMatrix()

		for i = 1, count do
			positions[i] = units.PositionFromEngine(matrix:TransformVector(self.local_points[i]))
		end
	end

	for i = 1, count do
		local o = (i - 1) * 9

		if at_rest then
			positions[i] = Vec3(flat[o + 1], flat[o + 2], flat[o + 3])
			normals[i] = Vec3(flat[o + 7], flat[o + 8], flat[o + 9])
		end

		uvs[i * 2 - 1], uvs[i * 2] = flat[o + 4], flat[o + 5]
		blends[i] = flat[o + 6]
	end

	record.positions = positions
	record.uvs = uvs
	record.blends = blends
	record.normals = normals
	record.texname = self.Material:match("^materials/(.*)%.vmt$")
	record.collide = self.Collide
	static_geometry.UpdateDisplacementBounds(record)
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

-- the triangles as a polygon in the entity's local space, for highlighting
function META:GetPolygons()
	if self.polygons then return self.polygons end

	self:EnsureLocalPoints()
	local flat = self.Vertices
	local polygon = Polygon3D.New()

	for i, point in ipairs(self.local_points) do
		local o = (i - 1) * 9
		polygon:AddVertex{
			pos = point,
			uv = Vec2(flat[o + 4], flat[o + 5]),
			normal = Vec3(flat[o + 7], flat[o + 8], flat[o + 9]),
			texture_blend = flat[o + 6],
		}
	end

	polygon:BuildBoundingBox()
	polygon:BuildTangents()
	polygon:Upload(nil)
	self.polygons = {polygon}
	return self.polygons
end

-- watches the transform so moving the entity moves the mesh
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
