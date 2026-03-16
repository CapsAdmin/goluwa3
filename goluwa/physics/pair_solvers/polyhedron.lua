local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics = import("goluwa/physics/shared.lua")
local solver = import("goluwa/physics/solver.lua")
local physics_solver = import("goluwa/physics/solver.lua")
local shape_accessors = import("goluwa/physics/shape_accessors.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local polyhedron = {}
local EPSILON = physics_solver.EPSILON or 0.00001

function polyhedron.GetPolyhedronWorldVertices(body, polyhedron_data)
	local out = {}

	for i, point in ipairs(polyhedron_data.vertices or {}) do
		out[i] = body:LocalToWorld(point)
	end

	return out
end

function polyhedron.ClosestPointOnTriangle(point, a, b, c)
	local ab = b - a
	local ac = c - a
	local ap = point - a
	local d1 = ab:Dot(ap)
	local d2 = ac:Dot(ap)

	if d1 <= 0 and d2 <= 0 then return a end

	local bp = point - b
	local d3 = ab:Dot(bp)
	local d4 = ac:Dot(bp)

	if d3 >= 0 and d4 <= d3 then return b end

	local vc = d1 * d4 - d3 * d2

	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		return a + ab * v
	end

	local cp = point - c
	local d5 = ab:Dot(cp)
	local d6 = ac:Dot(cp)

	if d6 >= 0 and d5 <= d6 then return c end

	local vb = d5 * d2 - d1 * d6

	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		return a + ac * w
	end

	local va = d3 * d6 - d5 * d4

	if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
		local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w
	end

	local denom = 1 / (va + vb + vc)
	local v = vb * denom
	local w = vc * denom
	return a + ab * v + ac * w
end

local function local_to_world_at(position, rotation, local_point)
	return position + rotation:VecMul(local_point)
end

local function get_polyhedron_world_vertices_at(polyhedron, position, rotation)
	local out = {}

	for i, point in ipairs(polyhedron.vertices or {}) do
		out[i] = local_to_world_at(position, rotation, point)
	end

	return out
end

local function interpolate_position(previous, current, t)
	return previous + (current - previous) * t
end

local function interpolate_rotation(previous, current, t)
	local target = current

	if previous:Dot(current) < 0 then
		target = Quat(-current.x, -current.y, -current.z, -current.w)
	end

	return Quat(
		previous.x + (target.x - previous.x) * t,
		previous.y + (target.y - previous.y) * t,
		previous.z + (target.z - previous.z) * t,
		previous.w + (target.w - previous.w) * t
	):GetNormalized()
end

local function get_edge_direction(polyhedron, edge)
	if edge.direction then return edge.direction end

	local a = edge.a or edge[1]
	local b = edge.b or edge[2]
	return polyhedron.vertices[b] - polyhedron.vertices[a]
end

local function add_unique_axis(axes, axis)
	local axis_length = axis:GetLength()

	if axis_length <= EPSILON then return end

	local normalized = axis / axis_length

	for _, existing in ipairs(axes) do
		if math.abs(existing:Dot(normalized)) >= 0.995 then return end
	end

	axes[#axes + 1] = normalized
end

local function project_vertices(vertices, axis)
	local min_projection = math.huge
	local max_projection = -math.huge

	for _, point in ipairs(vertices) do
		local projection = point:Dot(axis)
		min_projection = math.min(min_projection, projection)
		max_projection = math.max(max_projection, projection)
	end

	return min_projection, max_projection
end

local function collect_support_vertices(vertices, axis, want_max)
	local support = {}
	local best = want_max and -math.huge or math.huge
	local tolerance = 0.06

	for _, point in ipairs(vertices) do
		local projection = point:Dot(axis)

		if want_max then
			if projection > best + tolerance then
				best = projection
				support = {point}
			elseif math.abs(projection - best) <= tolerance then
				support[#support + 1] = point
			end
		else
			if projection < best - tolerance then
				best = projection
				support = {point}
			elseif math.abs(projection - best) <= tolerance then
				support[#support + 1] = point
			end
		end
	end

	return support, best
end

local function average_world_points(points)
	if not points or not points[1] then return nil end

	local sum = Vec3(0, 0, 0)

	for _, point in ipairs(points) do
		sum = sum + point
	end

	return sum / #points
end

local function add_contact_point(contacts, point_a, point_b)
	local midpoint = (point_a + point_b) * 0.5

	for _, existing in ipairs(contacts) do
		local existing_midpoint = (existing.point_a + existing.point_b) * 0.5

		if (existing_midpoint - midpoint):GetLength() <= 0.1 then return end
	end

	contacts[#contacts + 1] = {
		point_a = point_a,
		point_b = point_b,
	}
end

local function build_polyhedron_contacts(vertices_a, vertices_b, normal)
	local contacts = {}
	local support_a = collect_support_vertices(vertices_a, normal, true)
	local support_b = collect_support_vertices(vertices_b, normal, false)

	if not support_a[1] or not support_b[1] then return contacts end

	local primary = #support_a <= #support_b and support_a or support_b
	local secondary = primary == support_a and support_b or support_a
	local primary_is_a = primary == support_a

	for _, point in ipairs(primary) do
		local closest_other = nil
		local closest_distance = math.huge

		for _, other in ipairs(secondary) do
			local tangent_delta = other - point
			tangent_delta = tangent_delta - normal * tangent_delta:Dot(normal)
			local tangent_distance = tangent_delta:GetLength()

			if tangent_distance < closest_distance then
				closest_distance = tangent_distance
				closest_other = other
			end
		end

		if closest_other then
			if primary_is_a then
				add_contact_point(contacts, point, closest_other)
			else
				add_contact_point(contacts, closest_other, point)
			end
		end

		if #contacts >= 4 then break end
	end

	return contacts
end

local function closest_point_on_triangle(point, a, b, c)
	local ab = b - a
	local ac = c - a
	local ap = point - a
	local d1 = ab:Dot(ap)
	local d2 = ac:Dot(ap)

	if d1 <= 0 and d2 <= 0 then return a end

	local bp = point - b
	local d3 = ab:Dot(bp)
	local d4 = ac:Dot(bp)

	if d3 >= 0 and d4 <= d3 then return b end

	local vc = d1 * d4 - d3 * d2

	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		return a + ab * v
	end

	local cp = point - c
	local d5 = ab:Dot(cp)
	local d6 = ac:Dot(cp)

	if d6 >= 0 and d5 <= d6 then return c end

	local vb = d5 * d2 - d1 * d6

	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		return a + ac * w
	end

	local va = d3 * d6 - d5 * d4

	if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
		local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w
	end

	local denom = 1 / (va + vb + vc)
	local v = vb * denom
	local w = vc * denom
	return a + ab * v + ac * w
end

local function solve_swept_polyhedron_polyhedron_collision(dynamic_body, static_body, static_polyhedron, dt)
	if
		not pair_solver_helpers.IsSolverImmovable(static_body) or
		not pair_solver_helpers.HasSolverMass(dynamic_body)
	then
		return false
	end

	local previous_position = dynamic_body:GetPreviousPosition()
	local current_position = dynamic_body:GetPosition()
	local movement = current_position - previous_position

	if movement:GetLength() <= EPSILON then return false end

	local earliest_hit

	for _, local_point in ipairs(dynamic_body:GetCollisionLocalPoints()) do
		local start_world = dynamic_body:GeometryLocalToWorld(local_point, previous_position, dynamic_body:GetPreviousRotation())
		local end_world = dynamic_body:GeometryLocalToWorld(local_point)
		local hit = pair_solver_helpers.SweepPointAgainstPolyhedron(static_body, static_polyhedron, start_world, end_world)

		if hit and (not earliest_hit or hit.t < earliest_hit.t) then
			earliest_hit = hit
		end
	end

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(static_body, dynamic_body, previous_position, movement, earliest_hit, dt)
end

local function evaluate_polyhedron_pair_at_transforms(poly_a, position_a, rotation_a, poly_b, position_b, rotation_b)
	local axes = {}

	for _, face in ipairs(poly_a.faces or {}) do
		add_unique_axis(axes, rotation_a:VecMul(face.normal))
	end

	for _, face in ipairs(poly_b.faces or {}) do
		add_unique_axis(axes, rotation_b:VecMul(face.normal))
	end

	for _, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = rotation_a:VecMul(get_edge_direction(poly_a, edge_a))

		for _, edge_b in ipairs(poly_b.edges or {}) do
			local dir_b = rotation_b:VecMul(get_edge_direction(poly_b, edge_b))
			add_unique_axis(axes, dir_a:GetCross(dir_b))
		end
	end

	if not axes[1] then return nil end

	local vertices_a = get_polyhedron_world_vertices_at(poly_a, position_a, rotation_a)
	local vertices_b = get_polyhedron_world_vertices_at(poly_b, position_b, rotation_b)
	local best_overlap = math.huge
	local best_normal = nil
	local center_delta = position_b - position_a

	for _, axis in ipairs(axes) do
		local min_a, max_a = project_vertices(vertices_a, axis)
		local min_b, max_b = project_vertices(vertices_b, axis)
		local overlap = math.min(max_a, max_b) - math.max(min_a, min_b)

		if overlap <= 0 then return nil end

		if overlap < best_overlap then
			best_overlap = overlap
			best_normal = axis * math.sign(center_delta:Dot(axis))
		end
	end

	if not best_normal or best_overlap == math.huge then return nil end

	local contacts = build_polyhedron_contacts(vertices_a, vertices_b, best_normal)
	local point_a = average_world_points(collect_support_vertices(vertices_a, best_normal, true))
	local point_b = average_world_points(collect_support_vertices(vertices_b, best_normal, false))
	return {
		overlap = best_overlap,
		normal = best_normal,
		contacts = contacts,
		point_a = point_a,
		point_b = point_b,
		position_a = position_a,
		position_b = position_b,
		rotation_a = rotation_a,
		rotation_b = rotation_b,
	}
end

local function find_polyhedron_pair_time_of_impact(body_a, poly_a, body_b, poly_b)
	local previous_position_a = body_a:GetPreviousPosition()
	local previous_rotation_a = body_a:GetPreviousRotation()
	local current_position_a = body_a:GetPosition()
	local current_rotation_a = body_a:GetRotation()
	local previous_position_b = body_b:GetPreviousPosition()
	local previous_rotation_b = body_b:GetPreviousRotation()
	local current_position_b = body_b:GetPosition()
	local current_rotation_b = body_b:GetRotation()
	local sample_steps = 10
	local previous_t = 0
	local previous_result = evaluate_polyhedron_pair_at_transforms(
		poly_a,
		previous_position_a,
		previous_rotation_a,
		poly_b,
		previous_position_b,
		previous_rotation_b
	)

	if previous_result then return nil end

	for i = 1, sample_steps do
		local t = i / sample_steps
		local result = evaluate_polyhedron_pair_at_transforms(
			poly_a,
			interpolate_position(previous_position_a, current_position_a, t),
			interpolate_rotation(previous_rotation_a, current_rotation_a, t),
			poly_b,
			interpolate_position(previous_position_b, current_position_b, t),
			interpolate_rotation(previous_rotation_b, current_rotation_b, t)
		)

		if result then
			local low = previous_t
			local high = t
			local best = result

			for _ = 1, 10 do
				local mid = (low + high) * 0.5
				local mid_result = evaluate_polyhedron_pair_at_transforms(
					poly_a,
					interpolate_position(previous_position_a, current_position_a, mid),
					interpolate_rotation(previous_rotation_a, current_rotation_a, mid),
					poly_b,
					interpolate_position(previous_position_b, current_position_b, mid),
					interpolate_rotation(previous_rotation_b, current_rotation_b, mid)
				)

				if mid_result then
					best = mid_result
					high = mid
				else
					low = mid
				end
			end

			best.t = high
			return best
		end

		previous_t = t
	end

	return nil
end

local function solve_temporal_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)
	local result = find_polyhedron_pair_time_of_impact(body_a, poly_a, body_b, poly_b)

	if not result then return false end

	if body_a:HasSolverMass() then
		body_a.Position = result.position_a
		body_a.Rotation = result.rotation_a
	end

	if body_b:HasSolverMass() then
		body_b.Position = result.position_b
		body_b.Rotation = result.rotation_b
	end

	if result.contacts and result.contacts[1] then
		return contact_resolution.ResolvePairPenetration(body_a, body_b, result.normal, result.overlap, dt, nil, nil, result.contacts)
	end

	return contact_resolution.ResolvePairPenetration(body_a, body_b, result.normal, result.overlap, dt, result.point_a, result.point_b)
end

local function solve_relative_swept_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)
	if
		pair_solver_helpers.IsSolverImmovable(body_a) or
		pair_solver_helpers.IsSolverImmovable(body_b)
	then
		return false
	end

	local previous_position_a = body_a:GetPreviousPosition()
	local previous_position_b = body_b:GetPreviousPosition()
	local current_position_a = body_a:GetPosition()
	local current_position_b = body_b:GetPosition()
	local movement_a = current_position_a - previous_position_a
	local movement_b = current_position_b - previous_position_b
	local relative_movement = movement_a - movement_b

	if relative_movement:GetLength() <= EPSILON then return false end

	local previous_rotation_a = body_a:GetPreviousRotation()
	local previous_rotation_b = body_b:GetPreviousRotation()
	local earliest_hit

	for _, local_point in ipairs(body_a:GetCollisionLocalPoints()) do
		local start_world = body_a:GeometryLocalToWorld(local_point, previous_position_a, previous_rotation_a)
		local hit = pair_solver_helpers.SweepPointAgainstPolyhedron(
			body_b,
			poly_b,
			start_world,
			start_world + relative_movement,
			0,
			previous_position_b,
			previous_rotation_b
		)

		if hit and (not earliest_hit or hit.t < earliest_hit.t) then
			earliest_hit = {
				t = hit.t,
				normal = hit.normal * -1,
			}
		end
	end

	for _, local_point in ipairs(body_b:GetCollisionLocalPoints()) do
		local start_world = body_b:GeometryLocalToWorld(local_point, previous_position_b, previous_rotation_b)
		local hit = pair_solver_helpers.SweepPointAgainstPolyhedron(
			body_a,
			poly_a,
			start_world,
			start_world - relative_movement,
			0,
			previous_position_a,
			previous_rotation_a
		)

		if hit and (not earliest_hit or hit.t < earliest_hit.t) then
			earliest_hit = {
				t = hit.t,
				normal = hit.normal,
			}
		end
	end

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveRelativeSweptPairHit(
		body_a,
		body_b,
		previous_position_a,
		movement_a,
		previous_position_b,
		movement_b,
		earliest_hit,
		dt
	)
end

local function solve_polyhedron_pair_collision(body_a, body_b, dt)
	local poly_a = shape_accessors.GetBodyPolyhedron(body_a)
	local poly_b = shape_accessors.GetBodyPolyhedron(body_b)

	if not (poly_a and poly_b and poly_a.vertices and poly_b.vertices) then
		return false
	end

	if
		shape_accessors.BodyHasSignificantRotation(body_a) or
		shape_accessors.BodyHasSignificantRotation(body_b)
	then
		local temporal = solve_temporal_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)

		if temporal then return true end
	end

	if
		pair_solver_helpers.HasSolverMass(body_a) and
		pair_solver_helpers.HasSolverMass(body_b)
	then
		local previous_bounds_a = body_a:GetBroadphaseAABB(body_a:GetPreviousPosition(), body_a:GetPreviousRotation())
		local previous_bounds_b = body_b:GetBroadphaseAABB(body_b:GetPreviousPosition(), body_b:GetPreviousRotation())

		if not previous_bounds_a:IsBoxIntersecting(previous_bounds_b) then
			local swept = solve_relative_swept_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)

			if swept then return true end
		end
	end

	local axes = {}
	local center_delta = body_b:GetPosition() - body_a:GetPosition()

	for _, face in ipairs(poly_a.faces or {}) do
		add_unique_axis(axes, body_a:GetRotation():VecMul(face.normal))
	end

	for _, face in ipairs(poly_b.faces or {}) do
		add_unique_axis(axes, body_b:GetRotation():VecMul(face.normal))
	end

	for _, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = body_a:GetRotation():VecMul(get_edge_direction(poly_a, edge_a))

		for _, edge_b in ipairs(poly_b.edges or {}) do
			local dir_b = body_b:GetRotation():VecMul(get_edge_direction(poly_b, edge_b))
			add_unique_axis(axes, dir_a:GetCross(dir_b))
		end
	end

	if not axes[1] then return false end

	local vertices_a = polyhedron.GetPolyhedronWorldVertices(body_a, poly_a)
	local vertices_b = polyhedron.GetPolyhedronWorldVertices(body_b, poly_b)
	local best_overlap = math.huge
	local best_normal = nil

	local function try_swept_fallback()
		local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

		if static_body == body_a then
			return solve_swept_polyhedron_polyhedron_collision(dynamic_body, static_body, poly_a, dt)
		end

		if static_body == body_b then
			return solve_swept_polyhedron_polyhedron_collision(dynamic_body, static_body, poly_b, dt)
		end

		return solve_relative_swept_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)
	end

	for _, axis in ipairs(axes) do
		local min_a, max_a = project_vertices(vertices_a, axis)
		local min_b, max_b = project_vertices(vertices_b, axis)
		local overlap = math.min(max_a, max_b) - math.max(min_a, min_b)

		if overlap <= 0 then return try_swept_fallback() end

		if overlap < best_overlap then
			best_overlap = overlap
			best_normal = axis * math.sign(center_delta:Dot(axis))
		end
	end

	if not best_normal or best_overlap == math.huge then return false end

	local contacts = build_polyhedron_contacts(vertices_a, vertices_b, best_normal)
	local point_a = average_world_points(collect_support_vertices(vertices_a, best_normal, true))
	local point_b = average_world_points(collect_support_vertices(vertices_b, best_normal, false))

	if contacts[1] then
		return contact_resolution.ResolvePairPenetration(body_a, body_b, best_normal, best_overlap, dt, nil, nil, contacts)
	end

	return contact_resolution.ResolvePairPenetration(body_a, body_b, best_normal, best_overlap, dt, point_a, point_b)
end

polyhedron.SolveTemporalPolyhedronPairCollision = solve_temporal_polyhedron_pair_collision
polyhedron.SolvePolyhedronPairCollision = solve_polyhedron_pair_collision

solver:RegisterPairHandler("convex", "box", function(body_a, body_b, _, _, dt)
	return solve_polyhedron_pair_collision(body_a, body_b, dt)
end)

solver:RegisterPairHandler("box", "convex", function(body_a, body_b, _, _, dt)
	return solve_polyhedron_pair_collision(body_a, body_b, dt)
end)

solver:RegisterPairHandler("convex", "convex", function(body_a, body_b, _, _, dt)
	return solve_polyhedron_pair_collision(body_a, body_b, dt)
end)

return polyhedron