local physics = import("goluwa/physics.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local polyhedron_triangle_aggregator = import("goluwa/physics/polyhedron_triangle_aggregator.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local world_static_query = import("goluwa/physics/world_static_query.lua")
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

local LOCAL_AABB_TRANSFORM_PROXY = {
	body = nil,
}

function LOCAL_AABB_TRANSFORM_PROXY:TransformVector(point)
	return self.body:WorldToLocal(point)
end

local function for_each_overlapping_mesh_triangle(mesh_body, mesh_shape, other_body, callback)
	local bounds = world_static_query.BuildExpandedWorldContactAABB(other_body:GetBroadphaseAABB(), mesh_body, other_body)
	LOCAL_AABB_TRANSFORM_PROXY.body = mesh_body
	local local_bounds = AABB.BuildLocalAABBFromWorldAABB(bounds, LOCAL_AABB_TRANSFORM_PROXY)
	LOCAL_AABB_TRANSFORM_PROXY.body = nil
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

local function update_best_mesh_contact(best, triangle_index, normal, overlap, point_a, point_b)
	if not normal or overlap <= physics.EPSILON then return best end

	if not best or overlap > best.overlap then
		return {
			triangle_index = triangle_index,
			normal = normal,
			overlap = overlap,
			point_a = point_a,
			point_b = point_b,
		}
	end

	return best
end

local function resolve_best_mesh_contact(mesh_body, other_body, best, dt)
	if not best then return false end

	return contact_resolution.ResolvePairPenetration(
		mesh_body,
		other_body,
		best.normal,
		best.overlap,
		dt,
		best.point_a,
		best.point_b
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
		best = update_best_mesh_contact(best, triangle_index, normal, overlap, result.position, center - normal * radius)
	end)

	return resolve_best_mesh_contact(mesh_body, sphere_body, best, dt)
end

local function solve_mesh_capsule_collision(mesh_body, capsule_body, mesh_shape, dt)
	local shape = capsule_geometry.GetCapsuleShape(capsule_body)

	if not shape then return false end

	local start_point, end_point = capsule_geometry.GetSegmentWorld(capsule_body)
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
		best = update_best_mesh_contact(
			best,
			triangle_index,
			normal,
			overlap,
			result.position,
			result.segment_point - normal * (result.radius or 0)
		)
	end)

	return resolve_best_mesh_contact(mesh_body, capsule_body, best, dt)
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