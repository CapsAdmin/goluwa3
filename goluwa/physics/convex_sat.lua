local solver = import("goluwa/physics/solver.lua")
local convex_sat = {}
local EPSILON = solver.EPSILON or 0.00001

function convex_sat.AddUniqueAxis(axes, axis, duplicate_dot_threshold)
	local axis_length = axis:GetLength()

	if axis_length <= EPSILON then return end

	local normalized = axis / axis_length
	duplicate_dot_threshold = duplicate_dot_threshold or 0.995

	for _, existing in ipairs(axes) do
		if math.abs(existing:Dot(normalized)) >= duplicate_dot_threshold then return end
	end

	axes[#axes + 1] = normalized
end

function convex_sat.ProjectVertices(vertices, axis)
	local min_projection = math.huge
	local max_projection = -math.huge

	for _, point in ipairs(vertices) do
		local projection = point:Dot(axis)
		min_projection = math.min(min_projection, projection)
		max_projection = math.max(max_projection, projection)
	end

	return min_projection, max_projection
end

function convex_sat.OrientAxisNormal(axis, distance)
	return axis * (distance >= 0 and 1 or -1)
end

function convex_sat.CreateBestAxisTracker()
	return {
		any = {
			overlap = math.huge,
			normal = nil,
			kind = nil,
		},
		face = nil,
	}
end

function convex_sat.UpdateBestAxis(best, candidate)
	if candidate.overlap < best.any.overlap then best.any = candidate end

	if
		candidate.kind == "face" and
		(
			not best.face or
			candidate.overlap < best.face.overlap
		)
	then
		best.face = candidate
	end
end

function convex_sat.ChoosePreferredAxis(best, relative_tolerance, absolute_tolerance)
	local chosen = best.any

	if not chosen or chosen.kind ~= "edge" or not best.face then return chosen end

	relative_tolerance = relative_tolerance or 1
	absolute_tolerance = absolute_tolerance or 0

	if best.face.overlap <= chosen.overlap * relative_tolerance + absolute_tolerance then
		return best.face
	end

	return chosen
end

return convex_sat