local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local brush_geometry = import("goluwa/source_engine/brush_geometry.lua")
local world_pack = import("goluwa/source_engine/world_pack.lua")
local units = import("goluwa/source_engine/units.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local META = objects.CreateTemplate("brush")
META:StartStorable()
META:GetSet("Sides", nil, {Hidden = true})
META:GetSet("Collide", true, {callback = "OnShapeChanged"})
META:EndStorable()
-- sides are planes in source space, a static world below the brush batches and collides it
local MATRIX_FIELDS = {}

for row = 0, 3 do
	for column = 0, 3 do
		list.insert(MATRIX_FIELDS, "m" .. row .. column)
	end
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
	self.side_polygons = nil

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
	local side_polygons = {}
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
			side_polygons[i] = polygon
		end
	end

	self.polygons = polygons
	self.side_polygons = side_polygons
	return polygons
end

-- the polygon of one side in the entity's local space, nil when the side has no visible area
function META:GetSidePolygon(index)
	self:GetPolygons()
	return self.side_polygons[index]
end

-- the corners of a side in source space, wound clockwise as seen from the front
function META:GetSideCorners(index)
	return brush_geometry.ClipSide(self.sides, index)
end

function META:GetSideCenter(index)
	local corners = brush_geometry.ClipSide(self.sides, index)

	if not corners then return self.sides[index].normal * self.sides[index].dist end

	local center = Vec3(0, 0, 0)

	for _, point in ipairs(corners) do
		center = center + point
	end

	return center / #corners
end

function META:GetVisibleSideCount()
	local count = 0

	for i = 1, #self.sides do
		if brush_geometry.ClipSide(self.sides, i) then count = count + 1 end
	end

	return count
end

-- moves a side plane, refusing changes that would leave fewer than four sides with area
function META:SetSideDist(index, dist)
	local side = self.sides[index]
	local previous = side.dist

	if math.abs(dist - previous) < 0.0001 then return true end

	side.dist = dist

	if self:GetVisibleSideCount() < 4 then
		side.dist = previous
		return false
	end

	self:OnShapeChanged()
	return true
end

do
	local MERGE_DISTANCE = 0.05
	local PLANE_EPSILON = 0.05
	local MIN_CROSS_LENGTH = 0.01

	-- the corners of the brush in source space, solved from the planes so they are exact and shared by every side that meets there
	function META:GetVertices()
		local sides = self.sides
		local count = #sides
		local nx, ny, nz, nd = {}, {}, {}, {}
		local vertices = {}

		for i, side in ipairs(sides) do
			nx[i], ny[i], nz[i], nd[i] = side.normal.x, side.normal.y, side.normal.z, side.dist
		end

		for a = 1, count - 2 do
			for b = a + 1, count - 1 do
				local bcx, bcy, bcz

				for c = b + 1, count do
					bcx = ny[b] * nz[c] - nz[b] * ny[c]
					bcy = nz[b] * nx[c] - nx[b] * nz[c]
					bcz = nx[b] * ny[c] - ny[b] * nx[c]
					local det = nx[a] * bcx + ny[a] * bcy + nz[a] * bcz

					if math.abs(det) > 1e-6 then
						local cax = ny[c] * nz[a] - nz[c] * ny[a]
						local cay = nz[c] * nx[a] - nx[c] * nz[a]
						local caz = nx[c] * ny[a] - ny[c] * nx[a]
						local abx = ny[a] * nz[b] - nz[a] * ny[b]
						local aby = nz[a] * nx[b] - nx[a] * nz[b]
						local abz = nx[a] * ny[b] - ny[a] * nx[b]
						local x = (nd[a] * bcx + nd[b] * cax + nd[c] * abx) / det
						local y = (nd[a] * bcy + nd[b] * cay + nd[c] * aby) / det
						local z = (nd[a] * bcz + nd[b] * caz + nd[c] * abz) / det
						local inside = true

						for k = 1, count do
							if nx[k] * x + ny[k] * y + nz[k] * z - nd[k] > PLANE_EPSILON then
								inside = false

								break
							end
						end

						if inside then
							local found = false

							for _, vertex in ipairs(vertices) do
								if
									math.abs(vertex.x - x) < MERGE_DISTANCE and
									math.abs(vertex.y - y) < MERGE_DISTANCE and
									math.abs(vertex.z - z) < MERGE_DISTANCE
								then
									found = true

									break
								end
							end

							if not found then list.insert(vertices, Vec3(x, y, z)) end
						end
					end
				end
			end
		end

		return vertices
	end

	-- replaces the sides with the convex hull of points. Every new side copies the texture of the template side it faces
	-- most. Returns false and changes nothing when the hull is flat or a point in required is no longer a corner of it.
	function META:RebuildFromPoints(points, templates, required)
		local count = #points
		local sides = {}
		local seen = {}
		local on_plane = {}
		local xs, ys, zs = {}, {}, {}

		for i, point in ipairs(points) do
			xs[i], ys[i], zs[i] = point.x, point.y, point.z
		end

		for a = 1, count - 2 do
			for b = a + 1, count - 1 do
				local abx, aby, abz = xs[b] - xs[a], ys[b] - ys[a], zs[b] - zs[a]

				for c = b + 1, count do
					local acx, acy, acz = xs[c] - xs[a], ys[c] - ys[a], zs[c] - zs[a]
					local nx, ny, nz = aby * acz - abz * acy, abz * acx - abx * acz, abx * acy - aby * acx
					local length = math.sqrt(nx * nx + ny * ny + nz * nz)

					if length > MIN_CROSS_LENGTH then
						nx, ny, nz = nx / length, ny / length, nz / length
						local dist = nx * xs[a] + ny * ys[a] + nz * zs[a]
						local above, below = false, false
						local on_count = 0

						for k = 1, count do
							local d = nx * xs[k] + ny * ys[k] + nz * zs[k] - dist

							if d > PLANE_EPSILON then
								above = true
							elseif d < -PLANE_EPSILON then
								below = true
							else
								on_count = on_count + 1
								on_plane[on_count] = k
							end

							if above and below then break end
						end

						if not (above and below) and (above or below) then
							local normal = Vec3(nx, ny, nz)

							if above then normal, dist = normal * -1, -dist end

							-- a face is the set of corners on it, planes through the same corners are one face
							local key = table.concat(on_plane, ",", 1, on_count)
							local duplicate = seen[key]
							seen[key] = true

							if not duplicate then
								local template, best = templates[1], -math.huge

								for _, candidate in ipairs(templates) do
									local facing = normal:Dot(candidate.normal)

									if facing > best then template, best = candidate, facing end
								end

								local side = table.copy(template)
								side.normal, side.dist = normal, dist
								list.insert(sides, side)
							end
						end
					end
				end
			end
		end

		if #sides < 4 then return false end

		for _, point in ipairs(required) do
			local touching = 0

			for _, side in ipairs(sides) do
				if math.abs(side.normal:Dot(point) - side.dist) < PLANE_EPSILON then
					touching = touching + 1
				end
			end

			if touching < 3 then return false end
		end

		local changed = #sides ~= #self.sides

		for i = 1, #sides do
			local old = self.sides[i]

			if
				changed or
				(
					old.normal - sides[i].normal
				):GetLength() > 0.0001 or
				math.abs(old.dist - sides[i].dist) > 0.0001
			then
				changed = true

				break
			end
		end

		if changed then
			self.sides = sides
			self:OnShapeChanged()
		end

		return true
	end
end

-- puts the pivot in the middle of the brush without moving any plane
function META:Recenter()
	local sum = Vec3(0, 0, 0)
	local count = 0

	for i = 1, #self.sides do
		for _, point in ipairs(brush_geometry.ClipSide(self.sides, i) or {}) do
			sum = sum + point
			count = count + 1
		end
	end

	if count == 0 then return end

	local transform = self.Owner.transform
	local delta = units.PositionToEngine(sum / count) - transform:GetWorldPosition()
	transform:SetPosition(transform:GetPosition() + delta)
	self.last_matrix = transform:GetWorldMatrix():Copy()
	self.polygons = nil
	self.side_polygons = nil
end

-- watches the transform so moving, rotating or scaling the entity carries the planes along
function META:Activate()
	if self.active then return end

	self.active = true
	self.last_matrix = self.Owner.transform:GetWorldMatrix():Copy()
	self:AddGlobalEvent("Update")
end

function META:OnUpdate()
	local matrix = self.Owner.transform:GetWorldMatrix()
	local last = self.last_matrix
	local moved = false

	for _, field in ipairs(MATRIX_FIELDS) do
		if matrix[field] ~= last[field] then
			moved = true

			break
		end
	end

	if not moved then return end

	local inverse = last:GetInverse()
	local reference_z = Vec3(0, 0, 1)
	local reference_x = Vec3(1, 0, 0)

	local function carry(point)
		return units.PositionFromEngine(matrix:TransformVector(inverse:TransformVector(units.PositionToEngine(point))))
	end

	for _, side in ipairs(self.sides) do
		local normal = side.normal
		local origin = normal * side.dist
		local u = normal:GetCross(math.abs(normal.z) < 0.9 and reference_z or reference_x):GetNormalized() * 64
		local v = normal:GetCross(u):GetNormalized() * 64
		local a, b, c = carry(origin), carry(origin + u), carry(origin + v)
		local new_normal = (b - a):GetCross(c - a):GetNormalized()

		if new_normal:Dot(carry(origin + normal) - a) < 0 then
			new_normal = new_normal * -1
		end

		side.normal, side.dist = new_normal, new_normal:Dot(a)
	end

	self.last_matrix = matrix:Copy()
	self:OnShapeChanged()
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
