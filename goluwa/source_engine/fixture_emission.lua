local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local lights = import("goluwa/source_engine/lights.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local fixture_emission = {}
local RADIUS = 0.5
local FIXTURE_FRACTION = 0.5
local SETTLE_SECONDS = 2
local CELL = 2
local seen_version = -1
local checked_version = -1
local changed_at = 0
local grid = {}
local area_total = {}
local area_near = {}
local CELL_SPAN = 2 ^ 20

local function cell_key(ix, iy, iz)
	return ix + iy * CELL_SPAN + iz * CELL_SPAN * CELL_SPAN
end

local function near_light(x, y, z)
	local ix, iy, iz = math.floor(x / CELL), math.floor(y / CELL), math.floor(z / CELL)

	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local bucket = grid[cell_key(ix + dx, iy + dy, iz + dz)]

				if bucket then
					for i = 1, #bucket, 3 do
						local ex, ey, ez = bucket[i] - x, bucket[i + 1] - y, bucket[i + 2] - z

						if ex * ex + ey * ey + ez * ez < RADIUS * RADIUS then return true end
					end
				end
			end
		end
	end

	return false
end

local light_positions = {}

local function is_bounds_near_light(bounds)
	if not bounds then return true end

	for i = 1, #light_positions, 3 do
		local x, y, z = light_positions[i], light_positions[i + 1], light_positions[i + 2]

		if
			x >= bounds.min_x - RADIUS and
			x <= bounds.max_x + RADIUS and
			y >= bounds.min_y - RADIUS and
			y <= bounds.max_y + RADIUS and
			z >= bounds.min_z - RADIUS and
			z <= bounds.max_z + RADIUS
		then
			return true
		end
	end

	return false
end

local local_areas = table.weak("k")
local entry_areas = table.weak("k")
local light_signature
local MATRIX_FIELDS = {
	"m00",
	"m01",
	"m02",
	"m10",
	"m11",
	"m12",
	"m20",
	"m21",
	"m22",
	"m30",
	"m31",
	"m32",
}

local function store_matrix(cached, matrix)
	for i = 1, #MATRIX_FIELDS do
		local key = MATRIX_FIELDS[i]
		cached[key] = matrix[key]
	end
end

local function is_same_matrix(cached, matrix)
	for i = 1, #MATRIX_FIELDS do
		local key = MATRIX_FIELDS[i]

		if cached[key] ~= matrix[key] then return false end
	end

	return true
end

-- a fixture far from every light only needs its area, which is the local area scaled by the transform
local function get_world_area(packed, matrix)
	local area = local_areas[packed]

	if not area then
		area = 0
		local vertices, indices = packed.vertices, packed.indices

		for t = 0, packed.index_count / 3 - 1 do
			local a = vertices[indices[t * 3]].position
			local b = vertices[indices[t * 3 + 1]].position
			local c = vertices[indices[t * 3 + 2]].position
			local e1x, e1y, e1z = b[0] - a[0], b[1] - a[1], b[2] - a[2]
			local e2x, e2y, e2z = c[0] - a[0], c[1] - a[1], c[2] - a[2]
			local nx, ny, nz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
			area = area + math.sqrt(nx * nx + ny * ny + nz * nz) * 0.5
		end

		local_areas[packed] = area
	end

	local m = matrix
	local det = m.m00 * (
			m.m11 * m.m22 - m.m12 * m.m21
		) - m.m01 * (
			m.m10 * m.m22 - m.m12 * m.m20
		) + m.m02 * (
			m.m10 * m.m21 - m.m11 * m.m20
		)
	return area * math.abs(det) ^ (2 / 3)
end

function fixture_emission.Update()
	if seen_version ~= bridge.emitter_version then
		seen_version = bridge.emitter_version
		changed_at = system.GetTime()
	end

	if seen_version == checked_version or system.GetTime() - changed_at < SETTLE_SECONDS then
		return
	end

	table.clear(grid)
	table.clear(area_total)
	table.clear(area_near)
	table.clear(light_positions)
	local light_count = 0

	for component in pairs(lights.GetInstances()) do
		if component:IsValid() then
			local position = component.Owner.transform:GetWorldPosition()
			local key = cell_key(
				math.floor(position.x / CELL),
				math.floor(position.y / CELL),
				math.floor(position.z / CELL)
			)
			local bucket = grid[key] or {}
			grid[key] = bucket
			bucket[#bucket + 1] = position.x
			bucket[#bucket + 1] = position.y
			bucket[#bucket + 1] = position.z
			light_positions[#light_positions + 1] = position.x
			light_positions[#light_positions + 1] = position.y
			light_positions[#light_positions + 1] = position.z
			light_count = light_count + 1
		end
	end

	light_signature = table.concat(light_positions, ",")

	if light_count > 0 then
		for _, visual in ipairs(Visual.Instances) do
			local visual_near

			for _, entry in ipairs(visual.RenderEntries or {}) do
				local material = visual:GetResolvedMaterial(entry)
				local r, g, b = materials.GetEmissive(material)
				local packed = entry.polygon3d.packed

				if r + g + b > 0 and packed and packed.index_count >= 3 then
					local matrix = entry.transform:GetWorldMatrix()

					if visual_near == nil then
						visual_near = is_bounds_near_light(visual:GetWorldAABB())
					end

					local cached = entry_areas[entry]

					if
						visual_near and
						cached and
						cached.lights == light_signature and
						cached.packed == packed and
						is_same_matrix(cached, matrix)
					then
						area_total[material] = (area_total[material] or 0) + cached.total
						area_near[material] = (area_near[material] or 0) + cached.near
					elseif visual_near then
						local vertices, indices = packed.vertices, packed.indices
						local total, near = 0, 0

						for t = 0, packed.index_count / 3 - 1 do
							local a = vertices + indices[t * 3]
							local b = vertices + indices[t * 3 + 1]
							local c = vertices + indices[t * 3 + 2]
							local ax, ay, az = matrix:TransformVectorUnpacked(a.position[0], a.position[1], a.position[2])
							local bx, by, bz = matrix:TransformVectorUnpacked(b.position[0], b.position[1], b.position[2])
							local cx, cy, cz = matrix:TransformVectorUnpacked(c.position[0], c.position[1], c.position[2])
							local e1x, e1y, e1z = bx - ax, by - ay, bz - az
							local e2x, e2y, e2z = cx - ax, cy - ay, cz - az
							local nx, ny, nz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
							local area = math.sqrt(nx * nx + ny * ny + nz * nz) * 0.5
							total = total + area

							if near_light((ax + bx + cx) / 3, (ay + by + cy) / 3, (az + bz + cz) / 3) then
								near = near + area
							end
						end

						area_total[material] = (area_total[material] or 0) + total
						area_near[material] = (area_near[material] or 0) + near

						if not cached then
							cached = {}
							entry_areas[entry] = cached
						end

						cached.lights = light_signature
						cached.packed = packed
						cached.total = total
						cached.near = near
						store_matrix(cached, matrix)
					else
						area_total[material] = (area_total[material] or 0) + get_world_area(packed, matrix)
						area_near[material] = area_near[material] or 0
					end
				end
			end
		end
	end

	for material, total in pairs(area_total) do
		local emits = area_near[material] < total * FIXTURE_FRACTION

		if material:GetEmitsLight() ~= emits then
			material:SetEmitsLight(emits)
			material:SetIgnoredByLightOcclusion(not emits)
		end
	end

	checked_version = seen_version
end

event.AddListener("Update", "source_fixture_emission", fixture_emission.Update)
return fixture_emission
