local physics = import("goluwa/physics.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local mesh_contact_common = import("goluwa/physics/mesh_contact_common.lua")
local polyhedron_triangle_aggregator = import("goluwa/physics/polyhedron_triangle_aggregator.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local mesh_polyhedron_contacts = {}

local SOLVE_MESH_POLYHEDRON_CONTEXT = {
	mesh_body = nil,
	poly_body = nil,
	polyhedron = nil,
	state = nil,
	samples = nil,
}

local function add_contact_sample(body, seen, samples, local_point)
	if not local_point then return end

	local key = string.format("%.5f:%.5f:%.5f", local_point.x, local_point.y, local_point.z)

	if seen[key] then return end

	seen[key] = true
	samples[#samples + 1] = {
		local_point = local_point,
		point = body:GeometryLocalToWorld(local_point),
	}
end

local function solve_mesh_polyhedron_triangle(v0, v1, v2, triangle_index, context)
	local mesh_body = context.mesh_body
	local poly_body = context.poly_body
	local state = context.state
	local result = triangle_contact_queries.QueryPolyhedron(
		poly_body,
		context.polyhedron,
		v0,
		v1,
		v2,
		{
			epsilon = physics.EPSILON,
			triangle_slop = (mesh_body:GetCollisionMargin() or 0) + (poly_body:GetCollisionMargin() or 0),
			manifold_merge_distance = 0.08,
			face_axis_relative_tolerance = 1.05,
			face_axis_absolute_tolerance = 0.03,
		}
	)

	if result and result.normal and result.contacts and result.contacts[1] then
		if (result.overlap or 0) > (state.best_overlap or 0) then
			state.best_triangle_index = triangle_index
		end

		polyhedron_triangle_aggregator.AccumulateMeshContacts(
			state,
			poly_body,
			result,
			v0,
			v1,
			v2,
			{
				merge_distance = 0.08,
				max_contacts = 4,
			}
		)
	end

	mesh_polyhedron_contacts.AccumulateSampleContacts(state, mesh_body, poly_body, context.samples, v0, v1, v2, triangle_index)
end

function mesh_polyhedron_contacts.BuildContactSamples(body)
	local samples = {}
	local seen = {}

	for _, local_point in ipairs(body:GetCollisionLocalPoints() or {}) do
		add_contact_sample(body, seen, samples, local_point)
	end

	for _, local_point in ipairs(body:GetSupportLocalPoints() or {}) do
		add_contact_sample(body, seen, samples, local_point)
	end

	return samples
end

function mesh_polyhedron_contacts.AccumulateSampleContacts(state, mesh_body, poly_body, samples, v0, v1, v2, triangle_index)
	if not samples[1] then return state end

	local combined_margin = (poly_body:GetCollisionMargin() or 0) + (mesh_body:GetCollisionMargin() or 0)
	local triangle_center = triangle_geometry.GetTriangleCenter(v0, v1, v2)

	for _, sample in ipairs(samples) do
		local result = triangle_contact_queries.QueryPointSample(poly_body, sample.point, v0, v1, v2, {
			epsilon = physics.EPSILON,
		})

		if result then
			local normal = select(
				1,
				mesh_contact_common.SelectTriangleNormal(
					mesh_body,
					poly_body,
					sample.point - result.position,
					poly_body:GetPosition() - triangle_center,
					result.face_normal
				)
			)
			local overlap = combined_margin - result.surface_distance

			if normal and overlap > physics.EPSILON then
				if overlap > (state.best_overlap or 0) then
					state.best_overlap = overlap
					state.best_normal = normal
					state.best_triangle_index = triangle_index
					state.best_point_a = result.position
					state.best_point_b = sample.point
				end

				polyhedron_triangle_aggregator.MergeContact(state.contacts, result.position, sample.point, 0.08)
			end
		end
	end

	return state
end

function mesh_polyhedron_contacts.SolveMeshPolyhedronCollision(mesh_body, poly_body, mesh_shape, dt)
	local polyhedron = poly_body:GetBodyPolyhedron()

	if
		not (
			polyhedron and
			polyhedron.vertices and
			polyhedron.faces and
			polyhedron.faces[1]
		)
	then
		return false
	end

	local state = {
		best_overlap = 0,
		best_normal = nil,
		best_triangle_index = nil,
		contacts = {},
	}
	local samples = mesh_polyhedron_contacts.BuildContactSamples(poly_body)
	SOLVE_MESH_POLYHEDRON_CONTEXT.mesh_body = mesh_body
	SOLVE_MESH_POLYHEDRON_CONTEXT.poly_body = poly_body
	SOLVE_MESH_POLYHEDRON_CONTEXT.polyhedron = polyhedron
	SOLVE_MESH_POLYHEDRON_CONTEXT.state = state
	SOLVE_MESH_POLYHEDRON_CONTEXT.samples = samples

	mesh_contact_common.ForEachOverlappingMeshTriangle(
		mesh_body,
		mesh_shape,
		poly_body,
		solve_mesh_polyhedron_triangle,
		SOLVE_MESH_POLYHEDRON_CONTEXT
	)
	SOLVE_MESH_POLYHEDRON_CONTEXT.mesh_body = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.poly_body = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.polyhedron = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.state = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.samples = nil

	if not (state.best_normal and state.best_overlap > physics.EPSILON) then
		return false
	end

	if state.contacts[1] then
		return contact_resolution.ResolvePairPenetration(
			mesh_body,
			poly_body,
			state.best_normal,
			state.best_overlap,
			dt,
			nil,
			nil,
			state.contacts
		)
	end

	if state.best_point_a and state.best_point_b then
		return contact_resolution.ResolvePairPenetration(
			mesh_body,
			poly_body,
			state.best_normal,
			state.best_overlap,
			dt,
			state.best_point_a,
			state.best_point_b
		)
	end

	return false
end


return mesh_polyhedron_contacts
