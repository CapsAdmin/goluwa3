local convex_sat = import("goluwa/physics/convex_sat.lua")
local polyhedron_geometry = import("goluwa/physics/polyhedron/geometry.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local polyhedron_sat = {}
local FACE_AXIS = Vec3()
local EDGE_AXIS_A = Vec3()
local EDGE_AXIS_B = Vec3()
local EDGE_NORMAL = Vec3()

local function default_face_candidate(face_index)
	return {face_index = face_index}
end

local function default_edge_candidate()
	return {kind = "edge"}
end

local function default_margin_overlap()
	return nil
end

local function build_polyhedron_candidate(build_candidate, context, ...)
	if context ~= nil then return build_candidate(context, ...) end

	return build_candidate(...)
end

local function get_polyhedron_margin_overlap(get_margin_overlap, context, ...)
	if context ~= nil then return get_margin_overlap(context, ...) end

	return get_margin_overlap(...)
end

function polyhedron_sat.TryUpdateAxisCandidate(best, vertices_a, vertices_b, axis, center_delta, candidate, options)
	options = options or {}

	if options.normalize then axis:Normalize() end

	local margin_overlap = options.margin_overlap

	if options.get_margin_overlap then
		margin_overlap = options.get_margin_overlap(axis, candidate)
	end

	return convex_sat.TryUpdateAxis(
		best,
		vertices_a,
		vertices_b,
		axis,
		center_delta,
		candidate,
		margin_overlap,
		options.allow_zero_axis or false,
		options.epsilon
	)
end

function polyhedron_sat.CollectAxes(poly_a, rotation_a, poly_b, rotation_b, axes)
	axes = axes or {}

	for i = #axes, 1, -1 do
		axes[i] = nil
	end

	for _, face in ipairs(poly_a.faces or {}) do
		convex_sat.AddUniqueAxis(axes, rotation_a:VecMul(face.normal))
	end

	for _, face in ipairs(poly_b.faces or {}) do
		convex_sat.AddUniqueAxis(axes, rotation_b:VecMul(face.normal))
	end

	for _, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = rotation_a:VecMul(polyhedron_geometry.GetEdgeDirection(poly_a, edge_a))

		for _, edge_b in ipairs(poly_b.edges or {}) do
			local dir_b = rotation_b:VecMul(polyhedron_geometry.GetEdgeDirection(poly_b, edge_b))
			convex_sat.AddUniqueAxis(axes, dir_a:GetCross(dir_b))
		end
	end

	return axes
end

function polyhedron_sat.HasSeparatingAxis(vertices_a, vertices_b, axes)
	for _, axis in ipairs(axes) do
		if convex_sat.GetProjectedOverlap(vertices_a, vertices_b, axis) <= 0 then
			return true
		end
	end

	return false
end

function polyhedron_sat.UpdateFaceAxisCandidates(
	best,
	vertices_a,
	vertices_b,
	poly_data,
	rotation,
	center_delta,
	reference_body,
	epsilon
)
	for face_index, face in ipairs(poly_data.faces or {}) do
		convex_sat.TryUpdateAxis(
			best,
			vertices_a,
			vertices_b,
			rotation:VecMul(face.normal),
			center_delta,
			{
				kind = "face",
				reference_body = reference_body,
				face_index = face_index,
			},
			nil,
			false,
			epsilon
		)
	end

	return best
end

function polyhedron_sat.TryUpdatePolyhedronFaceAxisCandidates(best, vertices_a, vertices_b, poly_data, rotation, center_delta, options)
	options = options or {}
	local epsilon = options.epsilon
	local allow_zero_axis = options.allow_zero_axis or false
	local build_candidate = options.build_candidate or default_face_candidate
	local build_candidate_context = options.build_candidate_context
	local get_margin_overlap = options.get_margin_overlap or default_margin_overlap
	local get_margin_overlap_context = options.get_margin_overlap_context

	for face_index, face in ipairs(poly_data.faces or {}) do
		local axis = Quat.SetVecMul(FACE_AXIS, rotation, face.normal)
		local candidate = build_polyhedron_candidate(build_candidate, build_candidate_context, face_index, axis)
		local margin_overlap = get_polyhedron_margin_overlap(get_margin_overlap, get_margin_overlap_context, axis, face_index)

		if
			not polyhedron_sat.TryUpdateAxisCandidate(
				best,
				vertices_a,
				vertices_b,
				axis,
				center_delta,
				candidate,
				{
					epsilon = epsilon,
					allow_zero_axis = allow_zero_axis,
					normalize = options.normalize,
					margin_overlap = margin_overlap,
				}
			)
		then
			return false
		end
	end

	return true
end

function polyhedron_sat.UpdateEdgeAxisCandidates(
	best,
	vertices_a,
	vertices_b,
	poly_a,
	rotation_a,
	poly_b,
	rotation_b,
	center_delta,
	epsilon
)
	for edge_index_a, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = rotation_a:VecMul(polyhedron_geometry.GetEdgeDirection(poly_a, edge_a))

		for edge_index_b, edge_b in ipairs(poly_b.edges or {}) do
			convex_sat.TryUpdateAxis(
				best,
				vertices_a,
				vertices_b,
				dir_a:GetCross(rotation_b:VecMul(polyhedron_geometry.GetEdgeDirection(poly_b, edge_b))),
				center_delta,
				{
					kind = "edge",
					edge_index_a = edge_index_a,
					edge_index_b = edge_index_b,
				},
				nil,
				true,
				epsilon
			)
		end
	end

	return best
end

function polyhedron_sat.TryUpdatePolyhedronTriangleEdgeAxisCandidates(
	best,
	vertices_a,
	vertices_b,
	polyhedron,
	rotation,
	triangle_edges,
	center_delta,
	options
)
	options = options or {}
	local epsilon = options.epsilon
	local allow_zero_axis = options.allow_zero_axis or false
	local build_candidate = options.build_candidate or default_edge_candidate
	local build_candidate_context = options.build_candidate_context
	local get_margin_overlap = options.get_margin_overlap or default_margin_overlap
	local get_margin_overlap_context = options.get_margin_overlap_context

	for edge_index, edge in ipairs(polyhedron.edges or {}) do
		local edge_axis = polyhedron_geometry.GetEdgeDirection(polyhedron, edge)

		if edge_axis then
			local world_edge_axis = Quat.SetVecMul(EDGE_AXIS_A, rotation, edge_axis)

			for triangle_edge_index, triangle_edge in ipairs(triangle_edges or {}) do
				local axis = Vec3.SetCross(EDGE_AXIS_B, world_edge_axis, triangle_edge)
				local axis_length = axis:GetLength()

				if axis_length > epsilon then
					local normal = EDGE_NORMAL:CopyFrom(axis):Scale(1 / axis_length)
					local candidate = build_polyhedron_candidate(
						build_candidate,
						build_candidate_context,
						edge_index,
						triangle_edge_index,
						normal
					)
					local margin_overlap = get_polyhedron_margin_overlap(
						get_margin_overlap,
						get_margin_overlap_context,
						normal,
						edge_index,
						triangle_edge_index
					)

					if
						not polyhedron_sat.TryUpdateAxisCandidate(
							best,
							vertices_a,
							vertices_b,
							normal,
							center_delta,
							candidate,
							{
								epsilon = epsilon,
								allow_zero_axis = allow_zero_axis,
								margin_overlap = margin_overlap,
							}
						)
					then
						return false
					end
				end
			end
		end
	end

	return true
end

return polyhedron_sat
