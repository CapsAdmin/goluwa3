local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local vmt_material = import("goluwa/source_engine/vmt_material.lua")
local brush_geometry = import("goluwa/source_engine/brush_geometry.lua")
local units = import("goluwa/source_engine/units.lua")
local system = import("goluwa/system.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local META = objects.CreateTemplate("brush")
META:StartStorable()
META:GetSet("Index", 0)
META:GetSet("Sides", nil)
META:EndStorable()
local NORMAL_EPSILON = 0.0001
local DIST_EPSILON = 0.05
local COLLISION_SETTLE_TIME = 0.3

local function direction_to_rotation(direction)
	local forward = direction:GetNormalized()
	local reference = math.abs(forward:GetDot(orientation.UP_VECTOR)) > 0.95 and
		orientation.RIGHT_VECTOR or
		orientation.UP_VECTOR
	local right = forward:GetCross(reference):GetNormalized()
	local up = right:GetCross(forward):GetNormalized()
	local backward = forward * -1
	local matrix = Matrix44():Identity()
	matrix.m00, matrix.m01, matrix.m02 = right.x, right.y, right.z
	matrix.m10, matrix.m11, matrix.m12 = up.x, up.y, up.z
	matrix.m20, matrix.m21, matrix.m22 = backward.x, backward.y, backward.z
	return matrix:GetRotation(Quat()):GetNormalized()
end

function META:GetSides()
	local out = {}

	for i, side in ipairs(self.sides) do
		local vecs

		if side.vecs then
			vecs = {}

			for k = 1, 8 do
				vecs[k] = side.vecs[k]
			end
		end

		out[i] = {
			normal = side.normal:Copy(),
			dist = side.dist,
			texname = side.texname,
			vecs = vecs,
			width = side.width,
			height = side.height,
			visible = side.visible,
		}
	end

	return out
end

function META:SetSides(sides)
	self.sides = {}

	for i, saved in ipairs(sides) do
		self.sides[i] = {
			normal = saved.normal:Copy(),
			dist = saved.dist,
			texname = saved.texname,
			vecs = saved.vecs,
			width = saved.width,
			height = saved.height,
			visible = saved.visible,
		}
	end
end

function META:ShouldSerializeEntity()
	return self.editing
end

function META:Setup(world, record)
	self.record = record
	self.editing = false
	self.Index = record.index
	self:SetSides(record.sides)
	self.Owner.transform:SetPosition(units.PositionToEngine((record.mins + record.maxs) / 2))
	self:Attach(world)
	self:Rebuild()
end

function META:Attach(world)
	self.world = world
	world.brush_entities[self.Index] = self.Owner

	if self.editing then
		self.record = world.brush_records[self.Index]

		if self.record then
			world:HideRecord(self.record)
			self:UpdateCollision()
		end
	end
end

function META:UpdateCollision()
	local planes = {}

	for i, side in ipairs(self.sides) do
		planes[i] = units.PlaneToEngine(side)
	end

	self.world:UpdateBrushCollision(self.Index, planes)
end

function META:OnDeserialized()
	self.editing = true
	self.Owner:SetTransient(false)

	if not self.Owner:HasComponent("visual") then
		self.Owner:AddComponent("visual")
	end

	self:Rebuild()
	local world = static_world.GetActive()

	if world then self:Attach(world) else static_world.WaitForBuild(self) end
end

function META:GetRecord()
	return self.record
end

function META:GetPolygons()
	local polygons = {}

	for _, side in ipairs(self.sides) do
		if side.polygon then list.insert(polygons, side.polygon) end
	end

	return polygons
end

function META:CreateSides()
	if self.sides_created then return end

	self.sides_created = true
	local owner = self.Owner
	local brush_position = owner.transform:GetWorldPosition()

	for i, side in ipairs(self.sides) do
		local center = Vec3(0, 0, 0)
		local polygon = side.source_polygon

		if polygon then
			for _, point in ipairs(polygon) do
				center = center + point
			end

			center = center / #polygon
		else
			center = side.normal * side.dist
		end

		local normal = side.normal
		local entity = Entity.New{
			Name = "side " .. i .. (side.texname and (" " .. side.texname) or ""),
			Parent = owner,
		}
		entity:AddComponent("transform")
		entity:AddComponent("brush_side")
		entity:SetTransient(false)
		entity.transform:SetPosition(units.PositionToEngine(center) - brush_position)
		entity.transform:SetRotation(direction_to_rotation(Vec3(-normal.y, normal.z, -normal.x)))
		side.entity = entity
	end

	self:AddGlobalEvent("Update")
end

function META:ReadSidePlane(side)
	local matrix = side.entity.transform:GetWorldMatrix()
	local ox, oy, oz = matrix:GetTranslation()
	local forward = orientation.FORWARD_VECTOR
	local tx, ty, tz = matrix:TransformVectorUnpacked(forward.x, forward.y, forward.z)
	local direction = Vec3(tx - ox, ty - oy, tz - oz):GetNormalized()
	local normal = Vec3(-direction.z, -direction.x, direction.y)
	return normal, normal:Dot(units.PositionFromEngine(Vec3(ox, oy, oz)))
end

function META:OnUpdate()
	local changed = false

	for _, side in ipairs(self.sides) do
		local normal, dist = self:ReadSidePlane(side)

		if
			(
				normal - side.normal
			):GetLength() > NORMAL_EPSILON or
			math.abs(dist - side.dist) > DIST_EPSILON
		then
			side.normal, side.dist = normal, dist
			changed = true
		end
	end

	if changed then
		if not self.editing then self:BeginEdit() end

		self:Rebuild()
		self.collision_time = system.GetElapsedTime()
	elseif
		self.collision_time and
		system.GetElapsedTime() - self.collision_time > COLLISION_SETTLE_TIME
	then
		self.collision_time = nil
		self:UpdateCollision()
	end
end

function META:BeginEdit()
	self.editing = true
	self.world:HideRecord(self.record)

	if not self.Owner:HasComponent("visual") then
		self.Owner:AddComponent("visual")
	end
end

function META:Rebuild()
	local inverse = self.Owner.transform:GetWorldMatrixInverse()

	for i, side in ipairs(self.sides) do
		side.source_polygon = brush_geometry.ClipSide(self.sides, i)
		side.polygon = nil

		if side.visible and side.source_polygon then
			local vecs = side.vecs
			local points = side.source_polygon
			local polygon = Polygon3D.New()
			local count = #points

			for j = 2, count - 1 do
				for _, index in ipairs{1, j, j + 1} do
					local point = points[index]
					polygon:AddVertex{
						pos = inverse:TransformVector(units.PositionToEngine(point)),
						uv = Vec2(
							(
									vecs[1] * point.x + vecs[2] * point.y + vecs[3] * point.z + vecs[4]
								) / side.width,
							(
									vecs[5] * point.x + vecs[6] * point.y + vecs[7] * point.z + vecs[8]
								) / side.height
						),
						texture_blend = 0,
					}
				end
			end

			local vertices = polygon:GetVertices()

			for k = 1, #vertices, 3 do
				local a, b, c = vertices[k], vertices[k + 1], vertices[k + 2]
				local normal = (c.pos - a.pos):Cross(b.pos - a.pos):GetNormalized()
				a.normal, b.normal, c.normal = normal, normal, normal
			end

			polygon:BuildBoundingBox()
			polygon:BuildTangents()
			polygon:Upload(nil)
			side.polygon = polygon
		end
	end

	if not self.editing then return end

	local visual = self.Owner.visual

	for _, side in ipairs(self.sides) do
		if side.polygon then
			if side.primitive then
				side.primitive.visual_primitive:SetPolygon3D(side.polygon)
			else
				side.material = side.material or vmt_material.FromVMT("materials/" .. side.texname .. ".vmt")
				side.primitive = visual:CreatePrimitiveEntity(side.polygon, side.material, side.texname)
			end
		elseif side.primitive then
			side.primitive:Remove()
			side.primitive = nil
		end
	end

	visual:BuildAABB()
end

return META:Register()
