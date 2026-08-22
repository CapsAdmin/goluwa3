local physics_constants = import("goluwa/physics/constants.lua")
local convex_sat = {}

function convex_sat.AddUniqueAxis(axes, axis, duplicate_dot_threshold)
	local axis_length = axis:GetLength()

	if axis_length <= physics_constants.EPSILON then return end

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

function convex_sat.GetProjectedOverlap(vertices_a, vertices_b, axis)
	local min_a, max_a = convex_sat.ProjectVertices(vertices_a, axis)
	local min_b, max_b = convex_sat.ProjectVertices(vertices_b, axis)
	return math.min(max_a, max_b) - math.max(min_a, min_b)
end

function convex_sat.OrientAxisNormal(axis, distance)
	return axis * (distance >= 0 and 1 or -1)
end

function convex_sat.TryUpdateAxis(
	best,
	vertices_a,
	vertices_b,
	axis,
	center_delta,
	candidate,
	overlap_bias,
	normalize,
	epsilon
)
	local resolved_axis = axis

	if normalize then
		local axis_length = axis:GetLength()

		if axis_length <= (epsilon or physics_constants.EPSILON) then return false end

		resolved_axis = axis / axis_length
	end

	local overlap = convex_sat.GetProjectedOverlap(vertices_a, vertices_b, resolved_axis) + (
			overlap_bias or
			0
		)

	if overlap <= 0 then return false end

	candidate.overlap = overlap
	candidate.normal = convex_sat.OrientAxisNormal(resolved_axis, center_delta:Dot(resolved_axis))
	convex_sat.UpdateBestAxis(best, candidate)
	return true
end

-- Trackers store candidate values (not references) so callers can pass
-- reusable scratch candidate tables without aliasing the recorded best axis.
local function copy_candidate(target, source)
	target.overlap = source.overlap
	target.normal = source.normal
	target.kind = source.kind
	target.reference_body = source.reference_body
	target.edge_axis_a = source.edge_axis_a
	target.edge_axis_b = source.edge_axis_b
end

function convex_sat.CreateBestAxisTracker()
	return {
		any = {
			overlap = math.huge,
			normal = nil,
			kind = nil,
			reference_body = nil,
			edge_axis_a = nil,
			edge_axis_b = nil,
		},
		face = {
			overlap = math.huge,
			normal = nil,
			kind = nil,
			reference_body = nil,
			edge_axis_a = nil,
			edge_axis_b = nil,
		},
	}
end

function convex_sat.ResetBestAxisTracker(best)
	best.any.overlap = math.huge
	best.any.normal = nil
	best.any.kind = nil
	best.any.reference_body = nil
	best.any.edge_axis_a = nil
	best.any.edge_axis_b = nil
	best.face.overlap = math.huge
	best.face.normal = nil
	best.face.kind = nil
	best.face.reference_body = nil
	best.face.edge_axis_a = nil
	best.face.edge_axis_b = nil
end

function convex_sat.UpdateBestAxis(best, candidate)
	local any = best.any

	if candidate.overlap < any.overlap then copy_candidate(any, candidate) end

	local face = best.face

	if candidate.kind == "face" and candidate.overlap < face.overlap then
		copy_candidate(face, candidate)
	end
end

function convex_sat.ChoosePreferredAxis(best, relative_tolerance, absolute_tolerance)
	local chosen = best.any

	if not chosen or chosen.kind ~= "edge" or best.face.kind == nil then
		return chosen
	end

	relative_tolerance = relative_tolerance or 1
	absolute_tolerance = absolute_tolerance or 0

	if best.face.overlap <= chosen.overlap * relative_tolerance + absolute_tolerance then
		return best.face
	end

	return chosen
end

return convex_sat
