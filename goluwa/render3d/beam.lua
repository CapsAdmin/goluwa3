local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Beam = objects.CreateTemplate("render3d_beam")
Beam:GetSet("Radius", 0.02)
Beam:GetSet("RadiusEnd", nil)
Beam:GetSet("Visible", true)
Beam:GetSet("Material", nil)

function Beam.CreateMaterial(color, strength)
	return Material.New{
		Color = Color(color.r, color.g, color.b, 1),
		Roughness = 0.5,
		Metallic = 0,
		DoubleSided = true,
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 1, 1, strength),
	}
end

function Beam.Line(from, to, points)
	local count = #points

	for i = 1, count do
		local t = (i - 1) / (count - 1)
		points[i]:Set(
			from.x + (to.x - from.x) * t,
			from.y + (to.y - from.y) * t,
			from.z + (to.z - from.z) * t
		)
	end

	return points
end

function Beam.Quadratic(from, control, to, points)
	local count = #points

	for i = 1, count do
		local t = (i - 1) / (count - 1)
		local a = (1 - t) * (1 - t)
		local b = 2 * (1 - t) * t
		local c = t * t
		points[i]:Set(
			from.x * a + control.x * b + to.x * c,
			from.y * a + control.y * b + to.y * c,
			from.z * a + control.z * b + to.z * c
		)
	end

	return points
end

function Beam.NewPoints(count)
	local points = {}

	for i = 1, count do
		points[i] = Vec3()
	end

	return points
end

function Beam.New(config)
	local self = Beam:CreateObject()
	self.point_count = config.Points
	self.sides = config.Sides or 6
	self.ring_size = self.sides + 1
	self:SetRadius(config.Radius or 0.02)
	self:SetRadiusEnd(config.RadiusEnd)
	self:SetMaterial(config.Material)
	local polygon = Polygon3D.New()
	polygon.Dynamic = true

	for i = 1, self.point_count * self.ring_size do
		polygon:AddVertex{
			pos = Vec3(),
			normal = Vec3(0, 0, 1),
			tangent = {x = 1, y = 0, z = 0, w = 1},
			uv = Vec2(),
		}
	end

	local indices = {}

	for i = 1, self.point_count - 1 do
		for side = 1, self.sides do
			local a = (i - 1) * self.ring_size + side
			local b = a + 1
			local c = a + self.ring_size
			local d = c + 1
			indices[#indices + 1] = a
			indices[#indices + 1] = c
			indices[#indices + 1] = b
			indices[#indices + 1] = b
			indices[#indices + 1] = c
			indices[#indices + 1] = d
		end
	end

	self.indices = indices
	self.polygon = polygon
	local entity = Entity.New{Name = "beam", Parent = config.Parent}
	entity:SetTransient(true)
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	local visual = entity.visual
	visual:SetCastShadows(false)
	visual:SetInSceneBVH(false)
	visual:SetUseOcclusionCulling(false)
	visual:SetReceivesDecals(false)
	self.entity = entity
	return self
end

function Beam:SetVisible(visible)
	self.Visible = visible
	self.entity.visual:SetVisible(visible)
end

function Beam:OnRemove()
	if self.entity:IsValid() then self.entity:Remove() end
end

do
	function Beam:SetPoints(points)
		local count = self.point_count
		local ring_size = self.ring_size
		local sides = self.sides
		local radius_start = self.Radius
		local radius_end = self.RadiusEnd or radius_start
		local vertices = self.polygon.Vertices
		local nx, ny, nz = 0, 1, 0
		local distance = 0

		for i = 1, count do
			local p = points[i]
			local before = points[i > 1 and i - 1 or i]
			local after = points[i < count and i + 1 or i]
			local tx, ty, tz = after.x - before.x, after.y - before.y, after.z - before.z
			local length = math.sqrt(tx * tx + ty * ty + tz * tz)

			if length < 1e-6 then
				tx, ty, tz = 0, 0, -1
			else
				tx, ty, tz = tx / length, ty / length, tz / length
			end

			local d = nx * tx + ny * ty + nz * tz
			nx, ny, nz = nx - tx * d, ny - ty * d, nz - tz * d
			length = math.sqrt(nx * nx + ny * ny + nz * nz)

			if length < 1e-4 then
				nx, ny, nz = ty, tz, tx
				d = nx * tx + ny * ty + nz * tz
				nx, ny, nz = nx - tx * d, ny - ty * d, nz - tz * d
				length = math.sqrt(nx * nx + ny * ny + nz * nz)
			end

			nx, ny, nz = nx / length, ny / length, nz / length
			local bx, by, bz = ty * nz - tz * ny, tz * nx - tx * nz, tx * ny - ty * nx
			local radius = radius_start + (radius_end - radius_start) * (i - 1) / (count - 1)

			if i > 1 then
				local previous = points[i - 1]
				local dx, dy, dz = p.x - previous.x, p.y - previous.y, p.z - previous.z
				distance = distance + math.sqrt(dx * dx + dy * dy + dz * dz)
			end

			for side = 0, sides do
				local angle = side / sides * math.pi * 2
				local c, s = math.cos(angle), math.sin(angle)
				local rx, ry, rz = nx * c + bx * s, ny * c + by * s, nz * c + bz * s
				local vertex = vertices[(i - 1) * ring_size + side + 1]
				vertex.pos:Set(p.x + rx * radius, p.y + ry * radius, p.z + rz * radius)
				vertex.normal:Set(rx, ry, rz)
				vertex.tangent.x, vertex.tangent.y, vertex.tangent.z = tx, ty, tz
				vertex.uv:Set(distance, side / sides)
			end
		end

		if not self.primitive then
			self.polygon:BuildBoundingBox()
			self.polygon:Upload(self.indices)
			self.primitive = self.entity.visual:CreatePrimitiveEntity(self.polygon, self.Material, "beam_primitive")
			return
		end

		self.polygon:UpdateVertices()
		self.primitive.visual_primitive:SetLocalAABB(self.polygon.AABB)
		self.entity.visual:BuildAABB()
	end
end

return Beam:Register()
