local physics = import("goluwa/physics.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local polyhedron_triangle_aggregator = import("goluwa/physics/polyhedron_triangle_aggregator.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local mesh = {}

local function get_mesh_shape(body)
	local shape = body:GetPhysicsShape()
	return shape and shape.GetTypeName and shape:GetTypeName() == "mesh" and shape or nil
end

local function get_static_mesh_dynamic_pair(body_a, body_b)
	local shape_a = get_mesh_shape(body_a)
	local shape_b = get_mesh_shape(body_b)

	if shape_a and pair_solver_helpers.IsSolverImmovable(body_a) and pair_solver_helpers.HasSolverMass(body_b) then
		return body_a, body_b, shape_a
	end

	if shape_b and pair_solver_helpers.IsSolverImmovable(body_b) and pair_solver_helpers.HasSolverMass(body_a) then
		return body_b, body_a, shape_b
	end

	return nil, nil, nil
end

local function build_local_aabb_from_world_bounds(body, world_aabb)
	local local_min = Vec3(math.huge, math.huge, math.huge)
	local local_max = Vec3(-math.huge, -math.huge, -math.huge)
	local corners = {
		Vec3(world_aabb.min_x, world_aabb.min_y, world_aabb.min_z),
		Vec3(world_aabb.min_x, world_aabb.min_y, world_aabb.max_z),
		Vec3(world_aabb.min_x, world_aabb.max_y, world_aabb.min_z),
		Vec3(world_aabb.min_x, world_aabb.max_y, world_aabb.max_z),
		Vec3(world_aabb.max_x, world_aabb.min_y, world_aabb.min_z),
		Vec3(world_aabb.max_x, world_aabb.min_y, world_aabb.max_z),
		Vec3(world_aabb.max_x, world_aabb.max_y, world_aabb.min_z),
		Vec3(world_aabb.max_x, world_aabb.max_y, world_aabb.max_z),
	}

	for i = 1, #corners do
		local point = body:WorldToLocal(corners[i])
		local_min.x = math.min(local_min.x, point.x)
		local_min.y = math.min(local_min.y, point.y)
		local_min.z = math.min(local_min.z, point.z)
		local_max.x = math.max(local_max.x, point.x)
		local_max.y = math.max(local_max.y, point.y)
		local_max.z = math.max(local_max.z, point.z)
	end

	return AABB(local_min.x, local_min.y, local_min.z, local_max.x, local_max.y, local_max.z)
end

local function expand_world_bounds_for_mesh_contact(mesh_body, other_body, world_aabb)
	local mesh_margin = mesh_body.GetCollisionMargin and mesh_body:GetCollisionMargin() or 0
	local other_margin = other_body.GetCollisionMargin and other_body:GetCollisionMargin() or 0
	local probe_distance = other_body.GetCollisionProbeDistance and other_body:GetCollisionProbeDistance() or 0
	local pad = math.max(mesh_margin + other_margin + probe_distance, physics.DefaultSkin or 0, physics.EPSILON)
	return AABB(
		world_aabb.min_x - pad,
		world_aabb.min_y - pad,
		world_aabb.min_z - pad,
		world_aabb.max_x + pad,
		world_aabb.max_y + pad,
		world_aabb.max_z + pad
	)
end

local function for_each_overlapping_mesh_triangle(mesh_body, mesh_shape, other_body, callback)
	local bounds = expand_world_bounds_for_mesh_contact(mesh_body, other_body, other_body:GetBroadphaseAABB())
	local local_bounds = build_local_aabb_from_world_bounds(mesh_body, bounds)
	mesh_shape:ForEachOverlappingTriangle(mesh_body, local_bounds, function(v0, v1, v2, triangle_index, context)
		callback(
			mesh_body:LocalToWorld(v0),
			mesh_body:LocalToWorld(v1),
			mesh_body:LocalToWorld(v2),
			triangle_index,
			context
		)
	end)
end

local function select_triangle_normal(mesh_body, other_body, delta, fallback_delta, fallback_normal)
	return pair_solver_helpers.GetSafeCollisionNormal(
		delta,
		(other_body.GetVelocity and other_body:GetVelocity() or Vec3()) - (mesh_body.GetVelocity and mesh_body:GetVelocity() or Vec3()),
		fallback_delta,
		fallback_normal or pair_solver_helpers.GetCachedPairNormal(mesh_body, other_body)
	)
end

local function build_polyhedron_contact_samples(body)
	local samples = {}
	local seen = {}

	local function add_sample(local_point)
		if not local_point then return end

		local key = string.format("%.5f:%.5f:%.5f", local_point.x, local_point.y, local_point.z)

		if seen[key] then return end

		seen[key] = true
		samples[#samples + 1] = {
			local_point = local_point,
			point = body:GeometryLocalToWorld(local_point),
		}
	end

	for _, local_point in ipairs(body:GetCollisionLocalPoints() or {}) do
		add_sample(local_point)
	end

	for _, local_point in ipairs(body:GetSupportLocalPoints() or {}) do
		add_sample(local_point)
	end

	return samples
end

local function accumulate_polyhedron_sample_contacts(state, mesh_body, poly_body, samples, v0, v1, v2, triangle_index)
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
				select_triangle_normal(
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
				end

				polyhedron_triangle_aggregator.MergeContact(state.contacts, result.position, sample.point, 0.08)
			end
		end
	end

	return state
end

local function solve_mesh_sphere_collision(mesh_body, sphere_body, mesh_shape, dt)
	local center = sphere_body:GetPosition()
	local radius = sphere_body:GetSphereRadius()
	local combined_margin = (sphere_body:GetCollisionMargin() or 0) + (mesh_body:GetCollisionMargin() or 0)
	local best = nil

	for_each_overlapping_mesh_triangle(mesh_body, mesh_shape, sphere_body, function(v0, v1, v2, triangle_index)
		local result = triangle_contact_queries.QuerySphere(sphere_body, v0, v1, v2, {epsilon = physics.EPSILON})

		if not result then return end

		local normal = select(
			1,
			select_triangle_normal(
				mesh_body,
				sphere_body,
				center - result.position,
				center - triangle_geometry.GetTriangleCenter(v0, v1, v2),
				result.face_normal
			)
		)

		if not normal then return end

		local overlap = combined_margin - result.surface_distance

		if overlap <= physics.EPSILON then return end

		if not best or overlap > best.overlap then
			best = {
				triangle_index = triangle_index,
				normal = normal,
				overlap = overlap,
				point_a = result.position,
				point_b = center - normal * radius,
			}
		end
	end)

	if not best then return false end

	return contact_resolution.ResolvePairPenetration(
		mesh_body,
		sphere_body,
		best.normal,
		best.overlap,
		dt,
		best.point_a,
		best.point_b
	)
end

local function solve_mesh_capsule_collision(mesh_body, capsule_body, mesh_shape, dt)
	local shape = capsule_body:GetPhysicsShape()

	if
		not (
			shape and
			shape.GetRadius and
			shape.GetBottomSphereCenterLocal and
			shape.GetTopSphereCenterLocal
		)
	then
		return false
	end

	local start_point = capsule_body:LocalToWorld(shape:GetBottomSphereCenterLocal())
	local end_point = capsule_body:LocalToWorld(shape:GetTopSphereCenterLocal())
	local combined_margin = (capsule_body:GetCollisionMargin() or 0) + (mesh_body:GetCollisionMargin() or 0)
	local best = nil

	for_each_overlapping_mesh_triangle(mesh_body, mesh_shape, capsule_body, function(v0, v1, v2, triangle_index)
		local result = triangle_contact_queries.QueryCapsule(
			capsule_body,
			v0,
			v1,
			v2,
			{
				epsilon = physics.EPSILON,
				fallback_normal = physics.Up,
			}
		)

		if not result then return end

		local normal = select(
			1,
			select_triangle_normal(
				mesh_body,
				capsule_body,
				result.segment_point - result.position,
				capsule_body:GetPosition() - triangle_geometry.GetTriangleCenter(v0, v1, v2),
				result.face_normal
			)
		)

		if not normal then return end

		local overlap = combined_margin - result.surface_distance

		if overlap <= physics.EPSILON then return end

		if not best or overlap > best.overlap then
			best = {
				triangle_index = triangle_index,
				normal = normal,
				overlap = overlap,
				point_a = result.position,
				point_b = result.segment_point - normal * (result.radius or 0),
			}
		end
	end)

	if not best then return false end

	return contact_resolution.ResolvePairPenetration(
		mesh_body,
		capsule_body,
		best.normal,
		best.overlap,
		dt,
		best.point_a,
		best.point_b
	)
end

local function solve_mesh_polyhedron_collision(mesh_body, poly_body, mesh_shape, dt)
	local polyhedron = poly_body:GetBodyPolyhedron()

	if not (polyhedron and polyhedron.vertices and polyhedron.faces and polyhedron.faces[1]) then
		return false
	end

	local state = {
		best_overlap = 0,
		best_normal = nil,
		best_triangle_index = nil,
		contacts = {},
	}
	local samples = build_polyhedron_contact_samples(poly_body)

	for_each_overlapping_mesh_triangle(mesh_body, mesh_shape, poly_body, function(v0, v1, v2, triangle_index)
		local result = triangle_contact_queries.QueryPolyhedron(
			poly_body,
			polyhedron,
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
			if (result.overlap or 0) > (state.best_overlap or 0) then state.best_triangle_index = triangle_index end

			polyhedron_triangle_aggregator.AccumulateMeshContacts(state, poly_body, result, v0, v1, v2, {
				merge_distance = 0.08,
				max_contacts = 4,
			})
		end

		accumulate_polyhedron_sample_contacts(state, mesh_body, poly_body, samples, v0, v1, v2, triangle_index)
	end)

	if not (state.best_normal and state.best_overlap > physics.EPSILON) then return false end

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

	return false
end

local function solve_static_mesh_pair_collision(body_a, body_b, dt)
	local mesh_body, dynamic_body, mesh_shape = get_static_mesh_dynamic_pair(body_a, body_b)

	if not mesh_body then return false end

	local dynamic_shape = dynamic_body:GetShapeType()

	if dynamic_shape == "sphere" then
		return solve_mesh_sphere_collision(mesh_body, dynamic_body, mesh_shape, dt)
	end

	if dynamic_shape == "capsule" then
		return solve_mesh_capsule_collision(mesh_body, dynamic_body, mesh_shape, dt)
	end

	if dynamic_shape == "box" or dynamic_shape == "convex" then
		return solve_mesh_polyhedron_collision(mesh_body, dynamic_body, mesh_shape, dt)
	end

	return false
end

physics.solver:RegisterPairHandler("mesh", "sphere", function(body_a, body_b, _, _, dt)
	return solve_static_mesh_pair_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("sphere", "mesh", function(body_a, body_b, _, _, dt)
	return solve_static_mesh_pair_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("mesh", "capsule", function(body_a, body_b, _, _, dt)
	return solve_static_mesh_pair_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("capsule", "mesh", function(body_a, body_b, _, _, dt)
	return solve_static_mesh_pair_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("mesh", "box", function(body_a, body_b, _, _, dt)
	return solve_static_mesh_pair_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("box", "mesh", function(body_a, body_b, _, _, dt)
	return solve_static_mesh_pair_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("mesh", "convex", function(body_a, body_b, _, _, dt)
	return solve_static_mesh_pair_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("convex", "mesh", function(body_a, body_b, _, _, dt)
	return solve_static_mesh_pair_collision(body_a, body_b, dt)
end)

return mesh