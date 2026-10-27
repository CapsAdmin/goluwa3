local ffi = require("ffi")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Beam = import("goluwa/render3d/beam.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local Color = import("goluwa/structs/color.lua")
local sprites = {}
local VertexType = vertex_math.VertexType
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local VERTEX_FLOATS = vertex_layout.FloatStride
local POSITION = vertex_layout.GetFloatOffset("position")
local NORMAL = vertex_layout.GetFloatOffset("normal")
local TANGENT = vertex_layout.GetFloatOffset("tangent")
local COLOR = vertex_layout.GetFloatOffset("vertex_color")
local CORNER_X = {-1, 1, 1, -1}
local CORNER_Y = {-1, -1, 1, 1}
local CORNER_U = {0, 1, 1, 0}
local CORNER_V = {0, 0, 1, 1}
local MIN_PIXEL_RADIUS = 1.5
local INITIAL_CAPACITY = 64
local WHITE = Color(1, 1, 1, 1)
local BATCH = {}
BATCH.__index = BATCH
local batches = {}
local listed = {}
local frame_ready = false
local right_x, right_y, right_z
local up_x, up_y, up_z
local back_x, back_y, back_z
local camera_x, camera_y, camera_z
local radius_per_distance

local function begin_frame()
	local camera = render3d.GetCamera()
	local position = camera:GetPosition()
	local rotation = camera:GetRotation()
	local right, up, forward = rotation:GetRight(), rotation:GetUp(), rotation:GetForward()
	right_x, right_y, right_z = right.x, right.y, right.z
	up_x, up_y, up_z = up.x, up.y, up.z
	back_x, back_y, back_z = -forward.x, -forward.y, -forward.z
	camera_x, camera_y, camera_z = position.x, position.y, position.z
	radius_per_distance = math.tan(camera:GetFOV() / 2) / camera:GetViewport().h * MIN_PIXEL_RADIUS
	frame_ready = true
end

local function build(batch, capacity)
	if batch.entity then batch.entity:Remove() end

	local vertex_count = capacity * 4
	local vertices = VertexType(vertex_count)
	local indices = ffi.new("uint16_t[?]", capacity * 6)

	for quad = 0, capacity - 1 do
		local first = quad * 4
		local k = quad * 6
		indices[k], indices[k + 1], indices[k + 2] = first, first + 2, first + 1
		indices[k + 3], indices[k + 4], indices[k + 5] = first, first + 3, first + 2

		for corner = 0, 3 do
			local vertex = vertices[first + corner]
			vertex.uv[0], vertex.uv[1] = CORNER_U[corner + 1], CORNER_V[corner + 1]
			vertex.tangent[3] = 1
		end
	end

	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, vertex_count, indices, capacity * 6, false, "owned")
	local entity = Entity.New{Name = "sprite_batch"}
	entity:SetTransient(true)
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	local visual = entity.visual
	visual:SetCastShadows(false)
	visual:SetInSceneBVH(false)
	visual:SetRaycast(false)
	visual:SetUseOcclusionCulling(false)
	visual:SetReceivesDecals(false)
	visual:SetVisible(false)
	batch.primitive = visual:CreatePrimitiveEntity(polygon, batch.material, "sprite_batch_primitive")
	batch.entity = entity
	batch.polygon = polygon
	batch.vertices = vertices
	batch.floats = ffi.cast("float *", vertices)
	batch.capacity = capacity
	batch.shown = false
	batch.overflow = 0
	batch.last_count = 0
end

function sprites.GetBatch(texture, extra, color)
	texture = texture or Beam.GetGlowTexture()
	local by_extra = batches[texture]

	if not by_extra then
		by_extra = {}
		batches[texture] = by_extra
	end

	local key = extra or false

	if color then
		key = string.format(
			"%s:%d:%d:%d",
			tostring(extra),
			math.floor(color.r * 16),
			math.floor(color.g * 16),
			math.floor(color.b * 16)
		)
	end

	local batch = by_extra[key]

	if batch then return batch end

	local config = {VertexTint = color == nil}

	if extra then for name, value in pairs(extra) do
		config[name] = value
	end end

	batch = setmetatable({count = 0, listed = false}, BATCH)
	batch.material = Beam.CreateRibbonMaterial(color or WHITE, 0, texture, config)
	batch.material:SetEmissiveMultiplier(Color(1, 1, 1, color and 0 or 1))
	build(batch, INITIAL_CAPACITY)
	by_extra[key] = batch
	return batch
end

local function write(self, x, y, z, ax, ay, az, bx, by, bz, nx, ny, nz, reach, r, g, b, a)
	local n = self.count

	if n >= self.capacity then
		self.overflow = n + 1
		return
	end

	if not self.listed then
		self.listed = true
		listed[#listed + 1] = self
	end

	if n == 0 then
		self.min_x, self.min_y, self.min_z = math.huge, math.huge, math.huge
		self.max_x, self.max_y, self.max_z = -math.huge, -math.huge, -math.huge
	end

	if x - reach < self.min_x then self.min_x = x - reach end

	if y - reach < self.min_y then self.min_y = y - reach end

	if z - reach < self.min_z then self.min_z = z - reach end

	if x + reach > self.max_x then self.max_x = x + reach end

	if y + reach > self.max_y then self.max_y = y + reach end

	if z + reach > self.max_z then self.max_z = z + reach end

	local floats = self.floats
	local first = n * 4

	for corner = 0, 3 do
		local sx, sy = CORNER_X[corner + 1], CORNER_Y[corner + 1]
		local f = (first + corner) * VERTEX_FLOATS
		floats[f + POSITION], floats[f + POSITION + 1], floats[f + POSITION + 2] = x + ax * sx + bx * sy, y + ay * sx + by * sy, z + az * sx + bz * sy
		floats[f + NORMAL], floats[f + NORMAL + 1], floats[f + NORMAL + 2] = nx, ny, nz
		floats[f + TANGENT], floats[f + TANGENT + 1], floats[f + TANGENT + 2] = ax, ay, az
		floats[f + COLOR], floats[f + COLOR + 1], floats[f + COLOR + 2], floats[f + COLOR + 3] = r, g, b, a
	end

	self.count = n + 1
end

function BATCH:Add(x, y, z, radius, r, g, b, a)
	if not frame_ready then begin_frame() end

	local dx, dy, dz = x - camera_x, y - camera_y, z - camera_z
	local min_radius = math.sqrt(dx * dx + dy * dy + dz * dz) * radius_per_distance

	if radius < min_radius then radius = min_radius end

	write(
		self,
		x,
		y,
		z,
		right_x * radius,
		right_y * radius,
		right_z * radius,
		up_x * radius,
		up_y * radius,
		up_z * radius,
		back_x,
		back_y,
		back_z,
		radius * 1.5,
		r,
		g,
		b,
		a
	)
end

function BATCH:AddFlat(x, y, z, nx, ny, nz, radius, r, g, b, a, ux, uy, uz)
	local rx, ry, rz = ny, -nx, 0

	if ux then
		local d = ux * nx + uy * ny + uz * nz
		local ax, ay, az = ux - nx * d, uy - ny * d, uz - nz * d

		if ax * ax + ay * ay + az * az > 1e-6 then rx, ry, rz = ax, ay, az end
	end

	if rx * rx + ry * ry + rz * rz < 1e-6 then rx, ry = 1, 0 end

	local length = math.sqrt(rx * rx + ry * ry + rz * rz)
	rx, ry, rz = rx / length * radius, ry / length * radius, rz / length * radius
	local bx = (ny * rz - nz * ry)
	local by = (nz * rx - nx * rz)
	local bz = (nx * ry - ny * rx)
	write(self, x, y, z, rx, ry, rz, bx, by, bz, nx, ny, nz, radius * 1.5, r, g, b, a)
end

function BATCH:AddAxial(x, y, z, ux, uy, uz, radius, r, g, b, a)
	if not frame_ready then begin_frame() end

	local length = math.sqrt(ux * ux + uy * uy + uz * uz)
	ux, uy, uz = ux / length, uy / length, uz / length
	local vx, vy, vz = camera_x - x, camera_y - y, camera_z - z
	local distance = math.sqrt(vx * vx + vy * vy + vz * vz)
	local along = vx * ux + vy * uy + vz * uz
	local nx, ny, nz = vx - ux * along, vy - uy * along, vz - uz * along
	local side = math.sqrt(nx * nx + ny * ny + nz * nz)
	local face = math.clamp((side / distance - 0.1) / 0.4, 0, 1)

	if face <= 0 then return end

	self:AddFlat(x, y, z, nx / side, ny / side, nz / side, radius, r, g, b, a * face, ux, uy, uz)
end

event.AddListener("LateUpdate", "sprite_batches", function()
	frame_ready = false

	for i = #listed, 1, -1 do
		local batch = listed[i]
		local count = batch.count

		if batch.overflow > 0 then
			local capacity = batch.capacity

			while capacity < batch.overflow do
				capacity = capacity * 2
			end

			build(batch, capacity)
			count = 0
		end

		if count == 0 then
			if batch.shown then
				batch.entity.visual:SetVisible(false)
				batch.shown = false
			end

			batch.listed = false
			table.remove(listed, i)
		else
			local floats = batch.floats

			for vertex = count * 4, batch.last_count * 4 - 1 do
				local f = vertex * VERTEX_FLOATS
				floats[f + POSITION], floats[f + POSITION + 1], floats[f + POSITION + 2] = 0, 0, 0
			end

			batch.last_count = count
			local aabb = batch.polygon.AABB
			aabb.min_x, aabb.min_y, aabb.min_z = batch.min_x, batch.min_y, batch.min_z
			aabb.max_x, aabb.max_y, aabb.max_z = batch.max_x, batch.max_y, batch.max_z
			batch.polygon.mesh.vertex_buffer:Upload()
			batch.primitive.visual_primitive:SetLocalAABB(aabb)
			batch.entity.visual:BuildAABB()

			if not batch.shown then
				batch.entity.visual:SetVisible(true)
				batch.shown = true
			end

			batch.count = 0
		end
	end
end)

return sprites
