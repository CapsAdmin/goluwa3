local Visual = import("goluwa/entities/components/visual.lua")
local nearby = library()

function nearby.Collect(position, max_count)
	local px, py, pz = position.x, position.y, position.z
	local best = {}
	local worst = math.huge

	for _, visual in ipairs(Visual.Instances) do
		if visual.Is3D and visual.Visible and not visual.Owner:GetTransient() then
			local aabb = visual:GetWorldAABB()

			if aabb and aabb.min_x <= aabb.max_x then
				local dx = math.max(aabb.min_x - px, 0, px - aabb.max_x)
				local dy = math.max(aabb.min_y - py, 0, py - aabb.max_y)
				local dz = math.max(aabb.min_z - pz, 0, pz - aabb.max_z)
				local distance_sq = dx * dx + dy * dy + dz * dz

				if #best < max_count or distance_sq < worst then
					local index = #best + 1

					while index > 1 and best[index - 1].distance_sq > distance_sq do
						best[index] = best[index - 1]
						index = index - 1
					end

					best[index] = {entity = visual.Owner, distance_sq = distance_sq}

					if #best > max_count then best[#best] = nil end

					if #best == max_count then worst = best[#best].distance_sq end
				end
			end
		end
	end

	for _, info in ipairs(best) do
		info.distance = math.sqrt(info.distance_sq)
	end

	return best
end

return nearby
