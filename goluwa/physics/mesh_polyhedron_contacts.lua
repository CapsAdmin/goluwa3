local physics_constants = import("goluwa/physics/constants.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local mesh_contact_common = import("goluwa/physics/mesh_contact_common.lua")
local polyhedron_triangle_aggregator = import("goluwa/physics/polyhedron/triangle_aggregator.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local mesh_polyhedron_contacts = {}
local EPSILON = physics_constants.EPSILON
local MAX_MESH_POLYHEDRON_CONTACTS = 4
local CONTACT_MERGE_DISTANCE = 0.08
local SOLVE_MESH_POLYHEDRON_CONTEXT = {
	mesh_body = nil,
	poly_body = nil,
	polyhedron = nil,
	state = nil,
	samples = nil,
	combined_margin = 0,
	use_local_space = false,
}

local function quantize_sample_coord(value)
	if value >= 0 then return math.floor(value * 100000 + 0.5) end

	return math.ceil(value * 100000 - 0.5)
end

local function add_contact_sample_entry(seen, entries, local_point, is_support)
	if not local_point then return end

	local x = quantize_sample_coord(local_point.x)
	local y = quantize_sample_coord(local_point.y)
	local z = quantize_sample_coord(local_point.z)
	local seen_x = seen[x]

	if not seen_x then
		seen_x = {}
		seen[x] = seen_x
	end

	local seen_y = seen_x[y]

	if not seen_y then
		seen_y = {}
		seen_x[y] = seen_y
	end

	local existing = seen_y[z]

	if existing then
		if is_support then existing.is_support = true end

		return
	end

	local entry = {
		local_point = local_point,
		point = Vec3(),
		mesh_point = Vec3(),
		is_support = is_support == true,
	}
	seen_y[z] = entry
	entries[#entries + 1] = entry
end

local function get_cached_contact_sample_entries(body)
	local collision_points = body:GetCollisionLocalPoints() or false
	local support_points = body:GetSupportLocalPoints() or false
	local cache = body._PhysicsMeshPolyhedronContactSampleCache

	if
		cache and
		cache.collision_points == collision_points and
		cache.support_points == support_points
	then
		return cache.entries
	end

	local entries = {}
	local seen = {}

	for _, local_point in ipairs(collision_points or {}) do
		add_contact_sample_entry(seen, entries, local_point, false)
	end

	for _, local_point in ipairs(support_points or {}) do
		add_contact_sample_entry(seen, entries, local_point, true)
	end

	body._PhysicsMeshPolyhedronContactSampleCache = {
		collision_points = collision_points,
		support_points = support_points,
		entries = entries,
	}
	return entries
end

function mesh_polyhedron_contacts.BuildContactSamples(body, mesh_body, use_local_space)
	local entries = get_cached_contact_sample_entries(body)

	for _, sample in ipairs(entries) do
		body:GeometryLocalToWorld(sample.local_point, nil, nil, sample.point)

		if use_local_space and mesh_body then
			mesh_body:WorldToLocal(sample.point, nil, nil, sample.mesh_point)
		end
	end

	return entries
end

local function resolve_mesh_polyhedron_state(mesh_body, poly_body, state, dt)
	if not (state.best_normal and state.best_overlap > EPSILON) then return false end

	if state.best_polygon and state.best_triangle_index ~= nil then
		mesh_contact_common.CacheTriangle(
			mesh_body,
			poly_body,
			state.best_polygon,
			state.best_triangle_index,
			state.best_normal,
			state.best_overlap
		)
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

function mesh_polyhedron_contacts.AccumulateSampleContacts(
	state,
	mesh_body,
	poly_body,
	samples,
	v0,
	v1,
	v2,
	triangle_index,
	polygon,
	use_local_space,
	support_only
)
	if not samples[1] then return state, false end

	local combined_margin = SOLVE_MESH_POLYHEDRON_CONTEXT.combined_margin or
		(
			(
				poly_body:GetCollisionMargin() or
				0
			) + (
				mesh_body:GetCollisionMargin() or
				0
			)
		)
	local triangle_center = triangle_geometry.GetTriangleCenter(v0, v1, v2)
	local triangle_center_world = use_local_space and mesh_body:LocalToWorld(triangle_center) or triangle_center
	local found_contact = false

	for _, sample in ipairs(samples) do
		if support_only and not sample.is_support then goto continue end

		local query_point = use_local_space and sample.mesh_point or sample.point
		local result = triangle_contact_queries.QueryPointSample(poly_body, query_point, v0, v1, v2, {
			epsilon = EPSILON,
		})

		if result then
			local position = use_local_space and mesh_body:LocalToWorld(result.position) or result.position
			local face_normal = use_local_space and
				mesh_body:GetRotation():VecMul(result.face_normal):GetNormalized() or
				result.face_normal
			local normal = select(
				1,
				mesh_contact_common.SelectTriangleNormal(
					mesh_body,
					poly_body,
					sample.point - position,
					poly_body:GetPosition() - triangle_center_world,
					face_normal
				)
			)
			local overlap = combined_margin - result.surface_distance

			if normal and overlap > EPSILON then
				found_contact = true

				if overlap > (state.best_overlap or 0) then
					state.best_overlap = overlap
					state.best_normal = normal
					state.best_triangle_index = triangle_index
					state.best_polygon = polygon
					state.best_point_a = position
					state.best_point_b = sample.point
				end

				if #state.contacts < MAX_MESH_POLYHEDRON_CONTACTS then
					polyhedron_triangle_aggregator.MergeContact(state.contacts, position, sample.point, CONTACT_MERGE_DISTANCE)
				end
			end
		end

		::continue::
	end

	return state, found_contact
end

local function solve_mesh_polyhedron_triangle(v0, v1, v2, triangle_index, context)
	local mesh_body = context.mesh_body
	local poly_body = context.poly_body
	local state = context.state
	local polygon = context.entry and context.entry.polygon or nil
	local query_v0 = v0
	local query_v1 = v1
	local query_v2 = v2

	if context.use_local_space then
		query_v0 = mesh_body:LocalToWorld(v0)
		query_v1 = mesh_body:LocalToWorld(v1)
		query_v2 = mesh_body:LocalToWorld(v2)
	end

	local result = triangle_contact_queries.QueryPolyhedron(
		poly_body,
		context.polyhedron,
		query_v0,
		query_v1,
		query_v2,
		{
			epsilon = EPSILON,
			triangle_slop = context.combined_margin,
			manifold_merge_distance = CONTACT_MERGE_DISTANCE,
		}
	)

	if result and result.normal and result.contacts and result.contacts[1] then
		if (result.overlap or 0) > (state.best_overlap or 0) then
			state.best_triangle_index = triangle_index
			state.best_polygon = polygon
		end

		polyhedron_triangle_aggregator.AccumulateMeshContacts(
			state,
			poly_body,
			result,
			query_v0,
			query_v1,
			query_v2,
			{
				merge_distance = CONTACT_MERGE_DISTANCE,
				max_contacts = MAX_MESH_POLYHEDRON_CONTACTS,
			}
		)
	end

	if #state.contacts < MAX_MESH_POLYHEDRON_CONTACTS then
		mesh_polyhedron_contacts.AccumulateSampleContacts(
			state,
			mesh_body,
			poly_body,
			context.samples,
			query_v0,
			query_v1,
			query_v2,
			triangle_index,
			polygon,
			false
		)
	end

	return false
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
	local use_local_space = false
	local combined_margin = (mesh_body:GetCollisionMargin() or 0) + (poly_body:GetCollisionMargin() or 0)
	local samples = mesh_polyhedron_contacts.BuildContactSamples(poly_body, mesh_body, use_local_space)
	SOLVE_MESH_POLYHEDRON_CONTEXT.mesh_body = mesh_body
	SOLVE_MESH_POLYHEDRON_CONTEXT.poly_body = poly_body
	SOLVE_MESH_POLYHEDRON_CONTEXT.polyhedron = polyhedron
	SOLVE_MESH_POLYHEDRON_CONTEXT.state = state
	SOLVE_MESH_POLYHEDRON_CONTEXT.samples = samples
	SOLVE_MESH_POLYHEDRON_CONTEXT.use_local_space = use_local_space
	SOLVE_MESH_POLYHEDRON_CONTEXT.combined_margin = combined_margin
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
	SOLVE_MESH_POLYHEDRON_CONTEXT.use_local_space = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.combined_margin = 0
	return resolve_mesh_polyhedron_state(mesh_body, poly_body, state, dt)
end

return mesh_polyhedron_contacts
