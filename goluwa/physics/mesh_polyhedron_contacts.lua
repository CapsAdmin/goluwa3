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
local MAX_MESH_POLYHEDRON_CANDIDATES = 16
local CONTACT_MERGE_DISTANCE = 0.08
local MIN_FACE_NORMAL_DOT = 0.5
local FACE_SNAP_DOT = 0.99
local SPECULATIVE_DISTANCE = 0.03
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

local RESTING_CONTACT_SLACK = 0.005

local function reduce_contacts(contacts, normal)
	local nx, ny, nz = normal.x, normal.y, normal.z
	local first = 1
	local deepest = -math.huge

	for i = 1, #contacts do
		local a, b = contacts[i].point_a, contacts[i].point_b
		local depth = (a.x - b.x) * nx + (a.y - b.y) * ny + (a.z - b.z) * nz

		if depth > deepest then deepest, first = depth, i end
	end

	local p1 = contacts[first].point_b
	local second = first
	local farthest = -1

	for i = 1, #contacts do
		local p = contacts[i].point_b
		local dx, dy, dz = p.x - p1.x, p.y - p1.y, p.z - p1.z
		local distance = dx * dx + dy * dy + dz * dz

		if distance > farthest then farthest, second = distance, i end
	end

	local p2 = contacts[second].point_b
	local ex, ey, ez = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
	local third = nil
	local third_area = 0
	local fourth = nil
	local fourth_area = 0

	for pass = 1, 2 do
		for i = 1, #contacts do
			local p = contacts[i].point_b
			local dx, dy, dz = p.x - p1.x, p.y - p1.y, p.z - p1.z
			local area = (ey * dz - ez * dy) * nx + (ez * dx - ex * dz) * ny + (ex * dy - ey * dx) * nz

			if pass == 1 then
				if math.abs(area) > math.abs(third_area) then third_area, third = area, i end
			elseif -area * third_area > fourth_area then
				fourth_area, fourth = -area * third_area, i
			end
		end
	end

	local a, b, c, d = contacts[first], contacts[second], contacts[third], contacts[fourth]
	list.clear(contacts)
	contacts[1] = a

	if b ~= a then contacts[#contacts + 1] = b end

	if c then contacts[#contacts + 1] = c end

	if d then contacts[#contacts + 1] = d end
end

local function resolve_mesh_polyhedron_state(mesh_body, poly_body, state, dt)
	if not (state.best_normal and state.best_overlap > EPSILON) then return false end

	local contacts = state.contacts

	if not contacts[1] then
		if not (state.best_point_a and state.best_point_b) then return false end

		contacts[1] = {point_a = state.best_point_a, point_b = state.best_point_b}
	end

	local normal = state.best_normal
	local body = poly_body:GetBody()
	local solver = body:GetPhysics().solver
	local rest_gap = poly_body:GetCollisionMargin() + solver.PENETRATION_SLOP
	local velocity = body.Velocity
	local angular_velocity = body.AngularVelocity
	local center = body.Position
	local deepest = -math.huge
	local count = 0

	for i = 1, #contacts do
		local contact = contacts[i]
		local point = contact.point_b
		local mesh_point = contact.point_a
		local depth = (
				mesh_point.x - point.x
			) * normal.x + (
				mesh_point.y - point.y
			) * normal.y + (
				mesh_point.z - point.z
			) * normal.z
		local rx, ry, rz = point.x - center.x, point.y - center.y, point.z - center.z
		local approach_speed = -(
			(
				velocity.x + angular_velocity.y * rz - angular_velocity.z * ry
			) * normal.x + (
				velocity.y + angular_velocity.z * rx - angular_velocity.x * rz
			) * normal.y + (
				velocity.z + angular_velocity.x * ry - angular_velocity.y * rx
			) * normal.z
		)

		if
			-depth - rest_gap <= math.max(approach_speed, 0) * solver.StepDt + RESTING_CONTACT_SLACK
		then
			count = count + 1
			contacts[count] = contact
			deepest = math.max(deepest, depth)
		end
	end

	for i = #contacts, count + 1, -1 do
		contacts[i] = nil
	end

	if count == 0 then return false end

	if count > MAX_MESH_POLYHEDRON_CONTACTS then
		reduce_contacts(contacts, normal)
	end

	return contact_resolution.ResolvePairPenetration(mesh_body, poly_body, normal, deepest + rest_gap, dt, nil, nil, contacts)
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
	local e1x, e1y, e1z = v1.x - v0.x, v1.y - v0.y, v1.z - v0.z
	local e2x, e2y, e2z = v2.x - v0.x, v2.y - v0.y, v2.z - v0.z
	local nx, ny, nz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
	local normal_length = math.sqrt(nx * nx + ny * ny + nz * nz)
	local plane_cutoff = normal_length > EPSILON and combined_margin * normal_length or math.huge

	for _, sample in ipairs(samples) do
		if support_only and not sample.is_support then goto continue end

		local query_point = use_local_space and sample.mesh_point or sample.point

		if
			(
				query_point.x - v0.x
			) * nx + (
				query_point.y - v0.y
			) * ny + (
				query_point.z - v0.z
			) * nz >= plane_cutoff
		then
			goto continue
		end

		local result = triangle_contact_queries.QueryPointSample(poly_body, query_point, v0, v1, v2, {
			epsilon = EPSILON,
		})

		if result then
			local position = use_local_space and mesh_body:LocalToWorld(result.position) or result.position
			local face_normal = use_local_space and
				mesh_body:GetRotation():VecMul(result.face_normal):GetNormalized() or
				result.face_normal
			local normal = face_normal

			if
				not SOLVE_MESH_POLYHEDRON_CONTEXT.outward_winding and
				(
					poly_body:GetPosition() - triangle_center_world
				):Dot(face_normal) < 0
			then
				normal = face_normal * -1
			end

			local overlap = combined_margin - result.surface_distance

			if overlap > EPSILON then
				found_contact = true

				if overlap > (state.best_overlap or 0) then
					state.best_overlap = overlap
					state.best_normal = normal:Copy()
					state.best_point_a = position:Copy()
					state.best_point_b = sample.point:Copy()
				end

				if #state.contacts < MAX_MESH_POLYHEDRON_CANDIDATES then
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
			outward_winding = context.outward_winding,
		}
	)

	local face_normal = result and
		result.normal and
		result.contacts and
		result.contacts[1] and
		triangle_contact_queries.GetTriangleFaceNormal(query_v0, query_v1, query_v2, EPSILON)
	local face_dot = face_normal and result.normal:Dot(face_normal) or 0

	if math.abs(face_dot) >= MIN_FACE_NORMAL_DOT then
		if math.abs(face_dot) >= FACE_SNAP_DOT then
			result.normal = face_dot > 0 and face_normal or face_normal * -1
		end

		polyhedron_triangle_aggregator.AccumulateMeshContacts(
			state,
			mesh_body,
			poly_body,
			result,
			query_v0,
			query_v1,
			query_v2,
			{
				merge_distance = CONTACT_MERGE_DISTANCE,
				max_contacts = MAX_MESH_POLYHEDRON_CANDIDATES,
			}
		)
	end

	if #state.contacts < MAX_MESH_POLYHEDRON_CANDIDATES then
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
		contacts = {},
	}
	local use_local_space = false
	local combined_margin = (
			mesh_body:GetCollisionMargin() or
			0
		) + (
			poly_body:GetCollisionMargin() or
			0
		) + SPECULATIVE_DISTANCE
	local samples = mesh_polyhedron_contacts.BuildContactSamples(poly_body, mesh_body, use_local_space)
	local outward_winding = mesh_shape and
		mesh_shape.IsOutwardWound and
		mesh_shape:IsOutwardWound(mesh_body) or
		false
	SOLVE_MESH_POLYHEDRON_CONTEXT.mesh_body = mesh_body
	SOLVE_MESH_POLYHEDRON_CONTEXT.poly_body = poly_body
	SOLVE_MESH_POLYHEDRON_CONTEXT.polyhedron = polyhedron
	SOLVE_MESH_POLYHEDRON_CONTEXT.state = state
	SOLVE_MESH_POLYHEDRON_CONTEXT.samples = samples
	SOLVE_MESH_POLYHEDRON_CONTEXT.use_local_space = use_local_space
	SOLVE_MESH_POLYHEDRON_CONTEXT.combined_margin = combined_margin
	SOLVE_MESH_POLYHEDRON_CONTEXT.outward_winding = outward_winding
	mesh_contact_common.ForEachOverlappingMeshTriangle(
		mesh_body,
		mesh_shape,
		poly_body,
		solve_mesh_polyhedron_triangle,
		SOLVE_MESH_POLYHEDRON_CONTEXT,
		SPECULATIVE_DISTANCE
	)
	SOLVE_MESH_POLYHEDRON_CONTEXT.mesh_body = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.poly_body = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.polyhedron = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.state = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.samples = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.use_local_space = nil
	SOLVE_MESH_POLYHEDRON_CONTEXT.combined_margin = 0
	SOLVE_MESH_POLYHEDRON_CONTEXT.outward_winding = false
	return resolve_mesh_polyhedron_state(mesh_body, poly_body, state, dt)
end

return mesh_polyhedron_contacts
