local Visual = import("goluwa/entities/components/visual.lua")
local decal_receivers = {}
decal_receivers.__index = decal_receivers
local CELL_SIZE = 32

local function cell_key(x, z)
	return (x + 32768) * 65536 + z + 32768
end

function decal_receivers.New()
	local self = setmetatable({}, decal_receivers)
	self.cells = {}
	self.stamp = 0
	self.stamps = {}
	local cells = self.cells

	for _, component in ipairs(Visual.Instances) do
		if component.ReceivesDecals and not component.Loading then
			local aabb = component:GetWorldAABB()

			if aabb and aabb.min_x <= aabb.max_x then
				for x = math.floor(aabb.min_x / CELL_SIZE), math.floor(aabb.max_x / CELL_SIZE) do
					for z = math.floor(aabb.min_z / CELL_SIZE), math.floor(aabb.max_z / CELL_SIZE) do
						local key = cell_key(x, z)
						local cell = cells[key]

						if not cell then
							cell = {}
							cells[key] = cell
						end

						cell[#cell + 1] = component
					end
				end
			end
		end
	end

	return self
end

local function visit_polygon(
	polygon,
	matrix,
	mirrored,
	min_x,
	min_y,
	min_z,
	max_x,
	max_y,
	max_z,
	callback,
	context
)
	if polygon.packed then polygon:GetVertices() end

	local vertices, indices = polygon.Vertices, polygon.indices
	local m00, m01, m02, m10, m11, m12, m20, m21, m22 = matrix.m00,
	matrix.m01,
	matrix.m02,
	matrix.m10,
	matrix.m11,
	matrix.m12,
	matrix.m20,
	matrix.m21,
	matrix.m22
	local m30, m31, m32 = matrix.m30, matrix.m31, matrix.m32

	for i = 1, indices and #indices or #vertices, 3 do
		local va, vb, vc

		if indices then
			va, vb, vc = vertices[indices[i]], vertices[indices[i + 1]], vertices[indices[i + 2]]
		else
			va, vb, vc = vertices[i], vertices[i + 1], vertices[i + 2]
		end

		local pa, pb, pc = va.pos, vb.pos, vc.pos
		local ax = pa.x * m00 + pa.y * m10 + pa.z * m20 + m30
		local ay = pa.x * m01 + pa.y * m11 + pa.z * m21 + m31
		local az = pa.x * m02 + pa.y * m12 + pa.z * m22 + m32
		local bx = pb.x * m00 + pb.y * m10 + pb.z * m20 + m30
		local by = pb.x * m01 + pb.y * m11 + pb.z * m21 + m31
		local bz = pb.x * m02 + pb.y * m12 + pb.z * m22 + m32
		local cx = pc.x * m00 + pc.y * m10 + pc.z * m20 + m30
		local cy = pc.x * m01 + pc.y * m11 + pc.z * m21 + m31
		local cz = pc.x * m02 + pc.y * m12 + pc.z * m22 + m32

		if
			not (
				(
					ax < min_x and
					bx < min_x and
					cx < min_x
				)
				or
				(
					ax > max_x and
					bx > max_x and
					cx > max_x
				)
				or
				(
					ay < min_y and
					by < min_y and
					cy < min_y
				)
				or
				(
					ay > max_y and
					by > max_y and
					cy > max_y
				)
				or
				(
					az < min_z and
					bz < min_z and
					cz < min_z
				)
				or
				(
					az > max_z and
					bz > max_z and
					cz > max_z
				)
			)
		then
			local ex1, ey1, ez1 = bx - ax, by - ay, bz - az
			local ex2, ey2, ez2 = cx - ax, cy - ay, cz - az
			local nx, ny, nz = ey1 * ez2 - ez1 * ey2, ez1 * ex2 - ex1 * ez2, ex1 * ey2 - ey1 * ex2
			local length = math.sqrt(nx * nx + ny * ny + nz * nz)

			if length > 1e-12 then
				nx, ny, nz = nx / length, ny / length, nz / length
				local na, nb, nc = va.normal, vb.normal, vc.normal
				local sx, sy, sz = na.x + nb.x + nc.x, na.y + nb.y + nc.y, na.z + nb.z + nc.z
				local vertex_nx = sx * m00 + sy * m10 + sz * m20
				local vertex_ny = sx * m01 + sy * m11 + sz * m21
				local vertex_nz = sx * m02 + sy * m12 + sz * m22

				if nx * vertex_nx + ny * vertex_ny + nz * vertex_nz < 0 then
					nx, ny, nz = -nx, -ny, -nz
				end

				if mirrored then
					callback(context, ax, ay, az, cx, cy, cz, bx, by, bz, nx, ny, nz)
				else
					callback(context, ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz)
				end
			end
		end
	end
end

function decal_receivers:ForEachTriangle(min_x, min_y, min_z, max_x, max_y, max_z, callback, context)
	self.stamp = self.stamp + 1
	local stamp, stamps, cells = self.stamp, self.stamps, self.cells

	for x = math.floor(min_x / CELL_SIZE), math.floor(max_x / CELL_SIZE) do
		for z = math.floor(min_z / CELL_SIZE), math.floor(max_z / CELL_SIZE) do
			local cell = cells[cell_key(x, z)]

			if cell then
				for _, component in ipairs(cell) do
					if stamps[component] ~= stamp then
						stamps[component] = stamp
						local aabb = component:GetWorldAABB()

						if
							aabb and
							aabb.max_x >= min_x and
							aabb.min_x <= max_x and
							aabb.max_y >= min_y and
							aabb.min_y <= max_y and
							aabb.max_z >= min_z and
							aabb.min_z <= max_z
						then
							local world = component:GetWorldMatrix()

							for _, entry in ipairs(component:GetRenderEntries()) do
								local material = component:GetResolvedMaterial(entry)

								if not material:IsTransparent() and not material:GetAlphaTest() then
									local matrix = entry.local_matrix and (entry.local_matrix * world) or world
									local mirrored = matrix.m00 * (
											matrix.m11 * matrix.m22 - matrix.m12 * matrix.m21
										) - matrix.m01 * (
											matrix.m10 * matrix.m22 - matrix.m12 * matrix.m20
										) + matrix.m02 * (
											matrix.m10 * matrix.m21 - matrix.m11 * matrix.m20
										) < 0
									visit_polygon(
										entry.polygon3d,
										matrix,
										mirrored,
										min_x,
										min_y,
										min_z,
										max_x,
										max_y,
										max_z,
										callback,
										context
									)
								end
							end
						end
					end
				end
			end
		end
	end
end

return decal_receivers
