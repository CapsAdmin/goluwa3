local objects = import("goluwa/objects/objects.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local math3d = import("goluwa/render3d/math3d.lua")
local vmt_material = import("goluwa/source_engine/vmt_material.lua")
local units = import("goluwa/source_engine/units.lua")
local system = import("goluwa/system.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("displacement")
META:StartStorable()
META:GetSet("Index", 0)
META:GetSet("Power", 0)
META:GetSet("Corners", nil)
META:GetSet("Positions", nil)
META:GetSet("Alphas", nil)
META:GetSet("Texname", "")
META:GetSet("Vecs", nil)
META:GetSet("Width", 0)
META:GetSet("Height", 0)
META:EndStorable()
local COLLISION_SETTLE_TIME = 0.3
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

function META:ShouldSerializeEntity()
	return self.editing
end

function META:Setup(world, record)
	self.record = record
	self.editing = false
	self.Index = record.index
	self.Power = record.power
	self.Texname = record.texname
	self.Width = record.width
	self.Height = record.height
	self.Corners = {}

	for i, corner in ipairs(record.corners) do
		self.Corners[i] = corner:Copy()
	end

	self.Positions = {}
	self.Alphas = {}

	for i, position in ipairs(record.positions) do
		self.Positions[i * 3 - 2], self.Positions[i * 3 - 1], self.Positions[i * 3] = position.x, position.y, position.z
		self.Alphas[i] = record.alphas[i]
	end

	self.Vecs = {}

	for k = 1, 8 do
		self.Vecs[k] = record.vecs[k]
	end

	self:BuildGeometry()
	self.Owner.transform:SetPosition(self.center)
	self:Attach(world)
end

function META:BuildGeometry()
	local dims = 2 ^ self.Power + 1
	local positions = self.Positions
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for i = 1, dims * dims do
		local x, y, z = positions[i * 3 - 2], positions[i * 3 - 1], positions[i * 3]
		min_x, min_y, min_z = math.min(min_x, x), math.min(min_y, y), math.min(min_z, z)
		max_x, max_y, max_z = math.max(max_x, x), math.max(max_y, y), math.max(max_z, z)
	end

	self.center = units.PositionToEngine(Vec3((min_x + max_x) / 2, (min_y + max_y) / 2, (min_z + max_z) / 2))
	self.dims = dims
	local local_points = {}
	local nx, ny, nz = {}, {}, {}

	for i = 1, dims * dims do
		local_points[i] = units.PositionToEngine(Vec3(positions[i * 3 - 2], positions[i * 3 - 1], positions[i * 3])) - self.center
		nx[i], ny[i], nz[i] = 0, 0, 0
	end

	self.local_points = local_points
	local corners = self.Corners
	local vecs = self.Vecs
	local uvs = {}

	for y = 1, dims do
		for x = 1, dims do
			local flat = math3d.BilerpVec3(
				corners[1],
				corners[2],
				corners[3],
				corners[4],
				(y - 1) / (dims - 1),
				(x - 1) / (dims - 1)
			)
			uvs[(y - 1) * dims + x] = Vec2(
				(vecs[1] * flat.x + vecs[2] * flat.y + vecs[3] * flat.z + vecs[4]) / self.Width,
				(vecs[5] * flat.x + vecs[6] * flat.y + vecs[7] * flat.z + vecs[8]) / self.Height
			)
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
	self.polygon = polygon
	self.material = vmt_material.FromVMT("materials/" .. self.Texname .. ".vmt")
end

function META:GetPolygons()
	return {self.polygon}
end

function META:Attach(world)
	self.world = world
	world.displacement_entities[self.Index] = self.Owner

	if self.editing then
		self.record = world.displacement_records[self.Index]

		if self.record then
			world:HideRecord(self.record)
			self:UpdateCollision()
		end
	end
end

function META:UpdateCollision()
	local matrix = self.Owner.transform:GetWorldMatrix()
	local points = {}

	for i, point in ipairs(self.local_points) do
		points[i] = matrix:TransformVector(point)
	end

	self.world:UpdateDisplacementCollision(self.Index, points)
end

function META:BeginEdit()
	self.editing = true
	self.world:HideRecord(self.record)
	self:CreatePrimitive()
end

function META:CreatePrimitive()
	if not self.Owner:HasComponent("visual") then
		self.Owner:AddComponent("visual")
	end

	local visual = self.Owner.visual
	self.primitive = visual:CreatePrimitiveEntity(self.polygon, self.material, self.Texname)
	visual:BuildAABB()
end

function META:Activate()
	if self.active then return end

	self.active = true
	self.last_matrix = self.Owner.transform:GetWorldMatrix():Copy()
	self:AddGlobalEvent("Update")
end

function META:OnUpdate()
	local matrix = self.Owner.transform:GetWorldMatrix()
	local last = self.last_matrix
	local changed = false

	for _, field in ipairs(MATRIX_FIELDS) do
		if matrix[field] ~= last[field] then
			changed = true

			break
		end
	end

	if changed then
		self.last_matrix = matrix:Copy()

		if not self.editing then self:BeginEdit() end

		self.collision_time = system.GetElapsedTime()
	elseif
		self.collision_time and
		system.GetElapsedTime() - self.collision_time > COLLISION_SETTLE_TIME
	then
		self.collision_time = nil
		self:UpdateCollision()
	end
end

function META:OnDeserialized()
	self.editing = true
	self.Owner:SetTransient(false)
	self:BuildGeometry()
	self:CreatePrimitive()
	local world = static_world.GetActive()

	if world then self:Attach(world) else static_world.WaitForBuild(self) end
end

return META:Register()
