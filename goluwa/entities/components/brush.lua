local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local brush_geometry = import("goluwa/source_engine/brush_geometry.lua")
local world_pack = import("goluwa/source_engine/world_pack.lua")
local units = import("goluwa/source_engine/units.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local META = objects.CreateTemplate("brush")
META:StartStorable()
META:GetSet("Sides", nil, {Hidden = true})
META:GetSet("Collide", true, {callback = "OnShapeChanged"})
META:GetSet("ClipBounds", nil, {type = "table", Hidden = true, callback = "OnShapeChanged"})
META:EndStorable()
-- sides are planes in source space, a static world below the brush batches and collides it
local NORMAL_EPSILON = 0.0001
local DIST_EPSILON = 0.05

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
	return self.sides and world_pack.PackSides(self.sides)
end

function META:SetSides(value)
	self.sides = world_pack.UnpackSides(value)
	self:OnShapeChanged()
end

function META:OnShapeChanged()
	self.polygons = nil

	if self.world then self.world:MarkDirty(self) end
end

function META:CreateRecord()
	return {
		kind = "brush",
		spans = {},
		mins = Vec3(math.huge, math.huge, math.huge),
		maxs = Vec3(-math.huge, -math.huge, -math.huge),
	}
end

function META:UpdateRecord(record)
	record.sides = self.sides
	record.collide = self.Collide
	record.clip = self.ClipBounds
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

-- the world space polygons of the visible sides in the entity's local space, for highlighting
function META:GetPolygons()
	if self.polygons then return self.polygons end

	local polygons = {}
	local inverse = self.Owner.transform:GetWorldMatrixInverse()

	for i, side in ipairs(self.sides) do
		local points = side.visible and brush_geometry.ClipSide(self.sides, i)

		if points then
			local vecs = side.vecs
			local polygon = Polygon3D.New()

			for j = 2, #points - 1 do
				for _, index in ipairs{1, j, j + 1} do
					local point = points[index]
					polygon:AddVertex{
						pos = inverse:TransformVector(units.PositionToEngine(point)),
						uv = Vec2(
							vecs[1] * point.x + vecs[2] * point.y + vecs[3] * point.z + vecs[4],
							vecs[5] * point.x + vecs[6] * point.y + vecs[7] * point.z + vecs[8]
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
			list.insert(polygons, polygon)
		end
	end

	self.polygons = polygons
	return polygons
end

-- gives every side an entity with a transform so the gizmo can move the planes
function META:CreateSides()
	if self.sides_created then return end

	self.sides_created = true
	local owner = self.Owner
	local brush_position = owner.transform:GetWorldPosition()

	for i, side in ipairs(self.sides) do
		local center = Vec3(0, 0, 0)
		local polygon = brush_geometry.ClipSide(self.sides, i)

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

	if changed then self:OnShapeChanged() end
end

do
	-- the six planes of an axis aligned box with the texture tiling every 256 units
	local FACES = {
		{Vec3(1, 0, 0), "x", 1, {0, 1, 0}, {0, 0, -1}},
		{Vec3(-1, 0, 0), "x", -1, {0, 1, 0}, {0, 0, -1}},
		{Vec3(0, 1, 0), "y", 1, {1, 0, 0}, {0, 0, -1}},
		{Vec3(0, -1, 0), "y", -1, {1, 0, 0}, {0, 0, -1}},
		{Vec3(0, 0, 1), "z", 1, {1, 0, 0}, {0, -1, 0}},
		{Vec3(0, 0, -1), "z", -1, {1, 0, 0}, {0, -1, 0}},
	}

	-- creates a new box brush below parent, min and max are in source space and texname is a material name like "dev/dev_measuregeneric01"
	function META.CreateBox(parent, min, max, texname)
		local sides = {}

		for i, face in ipairs(FACES) do
			local axis, sign = face[2], face[3]
			local u, v = face[4], face[5]
			sides[i] = {
				normal = face[1]:Copy(),
				dist = sign == 1 and max[axis] or -min[axis],
				texname = texname,
				vecs = {
					u[1] / 256,
					u[2] / 256,
					u[3] / 256,
					0,
					v[1] / 256,
					v[2] / 256,
					v[3] / 256,
					0,
				},
				visible = true,
			}
		end

		local entity = Entity.New{Name = "brush", Parent = parent}
		entity:AddComponent("transform")
		entity:SetTransient(false)
		entity.transform:SetPosition(units.PositionToEngine((min + max) / 2))
		local brush = entity:AddComponent("brush")
		brush.sides = sides
		brush:Attach()
		return entity
	end
end

return META:Register()
