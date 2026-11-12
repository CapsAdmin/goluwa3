local Vec3 = import("goluwa/structs/vec3.lua")
local brush_geometry = {}
local EXTENT = 131072

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

-- the volume of a convex brush in cubic units: a third of every face's area times its plane distance
function brush_geometry.GetVolume(sides)
	local volume = 0

	for i, side in ipairs(sides) do
		local polygon = brush_geometry.ClipSide(sides, i)

		if polygon then
			local sum = Vec3(0, 0, 0)

			for k, point in ipairs(polygon) do
				sum = sum + point:GetCross(polygon[k % #polygon + 1])
			end

			volume = volume + sum:GetLength() * 0.5 * side.dist
		end
	end

	return volume / 3
end

do
	local MIN_VOLUME = 1
	local SAME_NORMAL = 0.9999
	local SAME_DIST = 0.01

	local function with_plane(sides, plane)
		local out = {}

		for i, side in ipairs(sides) do
			if
				side.normal:Dot(plane.normal) > SAME_NORMAL and
				math.abs(side.dist - plane.dist) < SAME_DIST
			then
				return sides
			end

			out[i] = side
		end

		out[#out + 1] = plane
		return out
	end

	local function prune(sides)
		local out = {}

		for i, side in ipairs(sides) do
			if brush_geometry.ClipSide(sides, i) then out[#out + 1] = side end
		end

		return out
	end

	-- a face of target's texture for a new face with this normal: the side of target facing the same way the most
	local function textured_plane(target, normal, dist)
		local template, best = target[1], -math.huge

		for _, side in ipairs(target) do
			local facing = side.normal:Dot(normal)

			if facing > best then template, best = side, facing end
		end

		return {
			normal = normal,
			dist = dist,
			texname = template.texname,
			vecs = template.vecs and table.copy(template.vecs),
			visible = true,
		}
	end

	-- target minus cutter (both convex brushes as sides) as convex pieces, nil when they do not overlap. Each cutter
	-- plane splits off what lies outside it; the faces it makes get target's texture
	function brush_geometry.Subtract(target, cutter)
		local overlap = target

		for _, plane in ipairs(cutter) do
			overlap = with_plane(overlap, plane)
		end

		if brush_geometry.GetVolume(prune(overlap)) < MIN_VOLUME then return nil end

		local pieces = {}
		local remaining = target

		for _, plane in ipairs(cutter) do
			local outside = prune(with_plane(remaining, textured_plane(target, plane.normal * -1, -plane.dist)))

			if brush_geometry.GetVolume(outside) >= MIN_VOLUME then
				pieces[#pieces + 1] = outside
			end

			remaining = with_plane(remaining, textured_plane(target, plane.normal, plane.dist))
		end

		return pieces
	end
end

return brush_geometry
