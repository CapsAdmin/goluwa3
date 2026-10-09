local Vec3 = import("goluwa/structs/vec3.lua")
local brush_geometry = {}
local EXTENT = 131072

-- planes is a list of {normal = Vec3, dist = number} with outward normals. Returns the polygon of
-- planes[side_index] clipped by all other planes, wound clockwise as seen from the front (Source winding).
function brush_geometry.ClipSide(planes, side_index)
	local plane = planes[side_index]
	local normal = plane.normal
	local reference = math.abs(normal.z) < 0.9 and Vec3(0, 0, 1) or Vec3(1, 0, 0)
	local u = normal:GetCross(reference):GetNormalized() * EXTENT
	local v = normal:GetCross(u):GetNormalized() * EXTENT
	local center = normal * plane.dist
	local polygon = {center - u - v, center + u - v, center + u + v, center - u + v}

	for other_index = 1, #planes do
		if other_index ~= side_index then
			local other = planes[other_index]
			local clipped = {}
			local previous = polygon[#polygon]
			local previous_d = other.normal:Dot(previous) - other.dist

			for _, current in ipairs(polygon) do
				local d = other.normal:Dot(current) - other.dist

				if (previous_d <= 0) ~= (d <= 0) then
					clipped[#clipped + 1] = previous + (current - previous) * (previous_d / (previous_d - d))
				end

				if d <= 0 then clipped[#clipped + 1] = current end

				previous, previous_d = current, d
			end

			polygon = clipped

			if #polygon < 3 then return nil end
		end
	end

	local sum = Vec3(0, 0, 0)

	for i, current in ipairs(polygon) do
		sum = sum + current:GetCross(polygon[i % #polygon + 1])
	end

	if sum:Dot(normal) > 0 then
		local count = #polygon

		for i = 1, count / 2 do
			polygon[i], polygon[count + 1 - i] = polygon[count + 1 - i], polygon[i]
		end
	end

	return polygon
end

return brush_geometry
