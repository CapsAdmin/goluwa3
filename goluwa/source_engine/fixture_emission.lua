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

local function cell_key(x, y, z)
	return math.floor(x / CELL) .. "," .. math.floor(y / CELL) .. "," .. math.floor(z / CELL)
end

local function near_light(x, y, z)
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local bucket = grid[cell_key(x + dx * CELL, y + dy * CELL, z + dz * CELL)]

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
	local light_count = 0

	for component in pairs(lights.GetInstances()) do
		if component:IsValid() then
			local position = component.Owner.transform:GetWorldPosition()
			local key = cell_key(position.x, position.y, position.z)
			local bucket = grid[key] or {}
			grid[key] = bucket
			bucket[#bucket + 1] = position.x
			bucket[#bucket + 1] = position.y
			bucket[#bucket + 1] = position.z
			light_count = light_count + 1
		end
	end

	if light_count > 0 then
		for _, visual in ipairs(Visual.Instances) do
			for _, entry in ipairs(visual.RenderEntries or {}) do
				local material = visual:GetResolvedMaterial(entry)
				local r, g, b = materials.GetEmissive(material)
				local packed = entry.polygon3d.packed

				if r + g + b > 0 and packed and packed.index_count >= 3 then
					local matrix = entry.transform:GetWorldMatrix()
					local vertices, indices = packed.vertices, packed.indices
					local total, near = area_total[material] or 0, area_near[material] or 0

					for t = 0, packed.index_count / 3 - 1 do
						local a = vertices[indices[t * 3]].position
						local b = vertices[indices[t * 3 + 1]].position
						local c = vertices[indices[t * 3 + 2]].position
						local ax, ay, az = matrix:TransformVectorUnpacked(a[0], a[1], a[2])
						local bx, by, bz = matrix:TransformVectorUnpacked(b[0], b[1], b[2])
						local cx, cy, cz = matrix:TransformVectorUnpacked(c[0], c[1], c[2])
						local e1x, e1y, e1z = bx - ax, by - ay, bz - az
						local e2x, e2y, e2z = cx - ax, cy - ay, cz - az
						local nx, ny, nz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
						local area = math.sqrt(nx * nx + ny * ny + nz * nz) * 0.5
						total = total + area

						if near_light((ax + bx + cx) / 3, (ay + by + cy) / 3, (az + bz + cz) / 3) then
							near = near + area
						end
					end

					area_total[material], area_near[material] = total, near
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
