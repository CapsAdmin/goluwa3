local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ffi = require("ffi")
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local VertexType = vertex_math.VertexType
local VERTEX_FLOATS = ffi.sizeof(VertexType(1)) / 4
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

do
	local streak

	function Beam.GetStreakTexture()
		if streak then return streak end

		streak = Texture.New{
			width = 64,
			height = 256,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			image = {
				usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "repeat",
			},
		}
		streak:Shade[[
			float edge = 1.0 - abs(uv.x * 2.0 - 1.0);
			edge = edge * edge * (3.0 - 2.0 * edge);
			float t = uv.y * 6.2831853;
			float streaks = 0.5 + 0.5 * sin(uv.x * 23.0 + sin(t) * 2.0) * cos(uv.x * 9.0 - t * 2.0);
			float a = edge * mix(0.35, 1.0, streaks) * smoothstep(0.0, 0.3, uv.y) * pow(1.0 - clamp(uv.y, 0.0, 1.0), 1.2);
			return vec4(vec3(a), a);
		]]
		return streak
	end
end

do
	local glow

	function Beam.GetGlowTexture()
		if glow then return glow end

		glow = Texture.New{
			width = 128,
			height = 128,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			image = {
				usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
		glow:Shade[[
			float d = length(uv * 2.0 - 1.0);
			float a = clamp(1.0 - d, 0.0, 1.0);
			a = a * a * a * 0.8 + exp(-d * d * 14.0) * 0.3;
			return vec4(vec3(a), a);
		]]
		return glow
	end
end

function Beam.CreateRibbonMaterial(color, strength, texture, extra)
	local config = {
		Additive = true,
		DoubleSided = true,
		AlbedoTexture = texture or Beam.GetStreakTexture(),
		ColorMultiplier = Color(color.r, color.g, color.b, 1),
		EmissiveMultiplier = Color(1, 1, 1, strength),
	}

	for key, value in pairs(extra or {}) do
		config[key] = value
	end

	return Material.New(config)
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
	self.ribbon = config.Ribbon
	self.sides = self.ribbon and 1 or config.Sides or 6
	self.ring_size = self.sides + 1
	self:SetRadius(config.Radius or 0.02)
	self:SetRadiusEnd(config.RadiusEnd)
	self:SetMaterial(config.Material)
	self.tint_r, self.tint_g, self.tint_b, self.tint_a = 1, 1, 1, 1
	local polygon = Polygon3D.New()
	local entity = Entity.New{Name = "beam", Parent = config.Parent}
	entity:SetTransient(true)
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	local visual = entity.visual
	visual:SetCastShadows(false)
	visual:SetInSceneBVH(false)
	visual:SetRaycast(false)
	visual:SetUseOcclusionCulling(false)
	visual:SetReceivesDecals(false)
	self.entity = entity
	self.polygon = polygon

	if self.ribbon then
		local vertex_count = self.point_count * 2
		local vertices = VertexType(vertex_count)
		local indices = ffi.new("uint16_t[?]", (self.point_count - 1) * 6)

		for i = 0, self.point_count - 2 do
			local a = i * 2
			local k = i * 6
			indices[k], indices[k + 1], indices[k + 2] = a, a + 2, a + 1
			indices[k + 3], indices[k + 4], indices[k + 5] = a + 1, a + 2, a + 3
		end

		for i = 0, vertex_count - 1 do
			vertices[i].tangent[3] = 1
			vertices[i].vertex_color[3] = 1
		end

		polygon:UploadVertexArray(vertices, vertex_count, indices, (self.point_count - 1) * 6, false, "owned")
		self.vertices = vertices
		self.floats = ffi.cast("float *", vertices)
		self.primitive = visual:CreatePrimitiveEntity(polygon, self.Material, "beam_primitive")
		return self
	end

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
	return self
end

function Beam:SetTint(r, g, b, a)
	self.tint_r, self.tint_g, self.tint_b, self.tint_a = r, g, b, a
	self.tint_dirty = true
end

function Beam:ApplyTint()
	local floats = self.floats
	local r, g, b, a = self.tint_r, self.tint_g, self.tint_b, self.tint_a

	for i = 0, self.point_count * 2 - 1 do
		local f = i * VERTEX_FLOATS
		floats[f + 13], floats[f + 14], floats[f + 15], floats[f + 16] = r, g, b, a
	end

	self.tint_dirty = false
	self.polygon.mesh.vertex_buffer:Upload()
end

do
	local MIN_PIXEL_RADIUS = 1.5

	local function finish(self)
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

	local function finish_ribbon(self, min_x, min_y, min_z, max_x, max_y, max_z)
		self.tint_dirty = false
		local aabb = self.polygon.AABB
		aabb.min_x, aabb.min_y, aabb.min_z = min_x, min_y, min_z
		aabb.max_x, aabb.max_y, aabb.max_z = max_x, max_y, max_z
		self.polygon.mesh.vertex_buffer:Upload()
		self.primitive.visual_primitive:SetLocalAABB(aabb)
		self.entity.visual:BuildAABB()
	end

	local work = ffi.new("double[?]", 8 * 512)

	local function write_bounds(self, floats, count)
		local min_x, min_y, min_z = math.huge, math.huge, math.huge
		local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

		for i = 0, count * 2 - 1 do
			local f = i * VERTEX_FLOATS
			local x, y, z = floats[f], floats[f + 1], floats[f + 2]

			if x < min_x then min_x = x end

			if x > max_x then max_x = x end

			if y < min_y then min_y = y end

			if y > max_y then max_y = y end

			if z < min_z then min_z = z end

			if z > max_z then max_z = z end
		end

		finish_ribbon(self, min_x, min_y, min_z, max_x, max_y, max_z)
	end

	local function write_attributes(floats, count, uv_offset, uv_scale, tint_r, tint_g, tint_b, tint_a)
		for i = 0, count - 1 do
			local w = i * 8
			local v = i / (count - 1) * uv_scale + uv_offset
			local nx, ny, nz = work[w + 3], work[w + 4], work[w + 5]
			local tx, ty, tz = work[w], work[w + 1], work[w + 2]

			for side = 0, 1 do
				local f = (i * 2 + side) * VERTEX_FLOATS
				floats[f + 3], floats[f + 4], floats[f + 5] = nx, ny, nz
				floats[f + 6], floats[f + 7] = side, v
				floats[f + 8], floats[f + 9], floats[f + 10] = tx, ty, tz
				floats[f + 13], floats[f + 14], floats[f + 15], floats[f + 16] = tint_r, tint_g, tint_b, tint_a
			end
		end
	end

	function Beam:SetRibbonFlat(points, uv_offset, uv_scale)
		local count = self.point_count
		local floats = self.floats
		local view = render3d.GetCamera()
		local camera = view:GetPosition()
		local cx, cy, cz = camera.x, camera.y, camera.z
		local min_radius_per_distance = math.tan(view:GetFOV() / 2) / view:GetViewport().h * MIN_PIXEL_RADIUS

		for i = 0, count - 1 do
			local o = i * 3
			local w = i * 8
			local before = (i > 0 and i - 1 or i) * 3
			local after = (i < count - 1 and i + 1 or i) * 3
			local tx, ty, tz = points[after] - points[before],
			points[after + 1] - points[before + 1],
			points[after + 2] - points[before + 2]
			local vx, vy, vz = cx - points[o], cy - points[o + 1], cz - points[o + 2]
			local sx, sy, sz = ty * vz - tz * vy, tz * vx - tx * vz, tx * vy - ty * vx
			local length = math.sqrt(sx * sx + sy * sy + sz * sz)

			if length < 1e-6 then sx, sy, sz, length = 1, 0, 0, 1 end

			local distance = math.sqrt(vx * vx + vy * vy + vz * vz)
			work[w], work[w + 1], work[w + 2] = sx / length, sy / length, sz / length
			work[w + 3], work[w + 4], work[w + 5] = vx / distance, vy / distance, vz / distance
			work[w + 6] = distance
		end

		local radius_start = self.Radius
		local radius_delta = (self.RadiusEnd or radius_start) - radius_start

		for i = 0, count - 1 do
			local o = i * 3
			local w = i * 8
			local radius = radius_start + radius_delta * i / (count - 1)
			local minimum = work[w + 6] * min_radius_per_distance

			if minimum > radius then radius = minimum end

			local px, py, pz = points[o], points[o + 1], points[o + 2]
			local ox, oy, oz = work[w] * radius, work[w + 1] * radius, work[w + 2] * radius
			local f = i * 2 * VERTEX_FLOATS
			floats[f], floats[f + 1], floats[f + 2] = px - ox, py - oy, pz - oz
			f = f + VERTEX_FLOATS
			floats[f], floats[f + 1], floats[f + 2] = px + ox, py + oy, pz + oz
		end

		write_attributes(
			floats,
			count,
			uv_offset,
			uv_scale,
			self.tint_r,
			self.tint_g,
			self.tint_b,
			self.tint_a
		)
		write_bounds(self, floats, count)
	end

	function Beam:SetStripFlat(left, right, uv_offset, uv_scale)
		local count = self.point_count
		local floats = self.floats
		local camera = render3d.GetCamera():GetPosition()
		local cx, cy, cz = camera.x, camera.y, camera.z

		for i = 0, count - 1 do
			local o = i * 3
			local w = i * 8
			local tx, ty, tz = right[o] - left[o], right[o + 1] - left[o + 1], right[o + 2] - left[o + 2]
			local length = math.sqrt(tx * tx + ty * ty + tz * tz)

			if length < 1e-6 then tx, ty, tz, length = 1, 0, 0, 1 end

			local nx, ny, nz = cx - left[o], cy - left[o + 1], cz - left[o + 2]
			local distance = math.sqrt(nx * nx + ny * ny + nz * nz)
			work[w], work[w + 1], work[w + 2] = tx / length, ty / length, tz / length
			work[w + 3], work[w + 4], work[w + 5] = nx / distance, ny / distance, nz / distance
			local f = i * 2 * VERTEX_FLOATS
			floats[f], floats[f + 1], floats[f + 2] = left[o], left[o + 1], left[o + 2]
			f = f + VERTEX_FLOATS
			floats[f], floats[f + 1], floats[f + 2] = right[o], right[o + 1], right[o + 2]
		end

		write_attributes(
			floats,
			count,
			uv_offset,
			uv_scale,
			self.tint_r,
			self.tint_g,
			self.tint_b,
			self.tint_a
		)
		write_bounds(self, floats, count)
	end

	local scratch_a = ffi.new("double[?]", 3 * 512)
	local scratch_b = ffi.new("double[?]", 3 * 512)

	local function flatten(points, count, out)
		for i = 1, count do
			local p = points[i]
			local o = (i - 1) * 3
			out[o], out[o + 1], out[o + 2] = p.x, p.y, p.z
		end
	end

	function Beam:SetRibbonPoints(points, uv_offset, uv_scale)
		flatten(points, self.point_count, scratch_a)
		self:SetRibbonFlat(scratch_a, uv_offset, uv_scale)
	end

	function Beam:SetStripPoints(left, right, uv_offset, uv_scale)
		flatten(left, self.point_count, scratch_a)
		flatten(right, self.point_count, scratch_b)
		self:SetStripFlat(scratch_a, scratch_b, uv_offset, uv_scale)
	end

	Beam.FinishPoints = finish
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

		Beam.FinishPoints(self)
	end
end

return Beam:Register()
