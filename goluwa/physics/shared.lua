local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local bit = require("bit")
physics.DefaultRigidBodyIterations = physics.DefaultRigidBodyIterations or 1
physics.DefaultRigidBodySubsteps = physics.DefaultRigidBodySubsteps or 2
physics.DefaultFixedTimeStep = physics.DefaultFixedTimeStep or (1 / 30)
physics.RigidBodyIterations = physics.RigidBodyIterations or physics.DefaultRigidBodyIterations
physics.RigidBodySubsteps = physics.RigidBodySubsteps or physics.DefaultRigidBodySubsteps
physics.Gravity = physics.Gravity or Vec3(0, -28, 0)
physics.Up = physics.Up or Vec3(0, 1, 0)
physics.DefaultSkin = physics.DefaultSkin or 0.02
physics.FixedTimeStep = physics.FixedTimeStep or physics.DefaultFixedTimeStep
physics.MaxFrameTime = physics.MaxFrameTime or 0.1
physics.MaxCatchUpSteps = physics.MaxCatchUpSteps or 8
physics.BusyMaxFrameTime = physics.BusyMaxFrameTime or (1 / 30)
physics.BusyMaxCatchUpSteps = physics.BusyMaxCatchUpSteps or 1
physics.DropBusyFrameDebt = physics.DropBusyFrameDebt ~= false
physics.FrameAccumulator = physics.FrameAccumulator or 0
physics.InterpolationAlpha = physics.InterpolationAlpha or 0
physics.DistanceConstraints = physics.DistanceConstraints or {}
physics.PreviousCollisionPairs = physics.PreviousCollisionPairs or {}
physics.CurrentCollisionPairs = physics.CurrentCollisionPairs or {}
physics.PreviousWorldCollisionPairs = physics.PreviousWorldCollisionPairs or {}
physics.CurrentWorldCollisionPairs = physics.CurrentWorldCollisionPairs or {}
physics.WorldTraceSource = physics.WorldTraceSource or nil

function physics.SetWorldTraceSource(source)
	physics.WorldTraceSource = source
	return source
end

function physics.GetWorldTraceSource()
	return physics.WorldTraceSource
end

function physics.GetInterpolationAlpha()
	return math.min(math.max(physics.InterpolationAlpha or 0, 0), 1)
end

function physics.IsActiveRigidBody(body)
	if body and body.GetBody then body = body:GetBody() end

	return body and
		body.Enabled and
		body.Owner and
		body.Owner.IsValid and
		body.Owner:IsValid() and
		body.Owner.transform
end

local function get_pair_key(body_a, body_b)
	local key_a = tostring(body_a)
	local key_b = tostring(body_b)

	if key_b < key_a then return key_b .. "|" .. key_a, true end

	return key_a .. "|" .. key_b, false
end

function physics.ShouldBodiesCollide(body_a, body_b)
	if not (body_a and body_b) or body_a == body_b then return false end

	if not (physics.IsActiveRigidBody(body_a) and physics.IsActiveRigidBody(body_b)) then
		return false
	end

	local group_a = body_a.GetCollisionGroup and
		body_a:GetCollisionGroup() or
		body_a.CollisionGroup or
		1
	local group_b = body_b.GetCollisionGroup and
		body_b:GetCollisionGroup() or
		body_b.CollisionGroup or
		1
	local mask_a = body_a.GetCollisionMask and body_a:GetCollisionMask() or body_a.CollisionMask
	local mask_b = body_b.GetCollisionMask and body_b:GetCollisionMask() or body_b.CollisionMask
	mask_a = mask_a == nil and -1 or mask_a
	mask_b = mask_b == nil and -1 or mask_b
	return bit.band(mask_a, group_b) ~= 0 and bit.band(mask_b, group_a) ~= 0
end

function physics.BeginCollisionFrame()
	physics.CurrentCollisionPairs = {}
	physics.CurrentWorldCollisionPairs = {}
end

function physics.RecordCollisionPair(body_a, body_b, normal, overlap)
	if not physics.ShouldBodiesCollide(body_a, body_b) then return end

	body_a = body_a.GetBody and body_a:GetBody() or body_a
	body_b = body_b.GetBody and body_b:GetBody() or body_b
	local key, swapped = get_pair_key(body_a, body_b)
	local stored_normal = swapped and normal * -1 or normal
	local stored_overlap = overlap or 0
	local existing = physics.CurrentCollisionPairs[key]

	if not existing or stored_overlap > (existing.overlap or 0) then
		physics.CurrentCollisionPairs[key] = {
			body_a = swapped and body_b or body_a,
			body_b = swapped and body_a or body_b,
			normal = stored_normal,
			overlap = stored_overlap,
		}
	end
end

local function get_world_pair_key(body, entity)
	if not (physics.IsActiveRigidBody(body) and entity) then return nil end

	return tostring(body) .. "|world|" .. tostring(entity)
end

function physics.RecordWorldCollision(body, hit, normal, overlap)
	if not physics.IsActiveRigidBody(body) then return end

	if not (hit and hit.entity) then return end

	if hit.entity == body.Owner then return end

	local key = get_world_pair_key(body, hit.entity)

	if not key then return end

	local stored_overlap = overlap or 0
	local existing = physics.CurrentWorldCollisionPairs[key]

	if not existing or stored_overlap > (existing.overlap or 0) then
		physics.CurrentWorldCollisionPairs[key] = {
			body = body,
			entity = hit.entity,
			normal = normal,
			overlap = stored_overlap,
			hit = hit,
		}
	end
end

local function emit_collision_event(what, self_owner, self_body, other_entity, other_body, normal, overlap, hit)
	local owner = self_owner or (self_body and self_body.Owner)

	if not (owner and owner.CallLocalEvent) then return end

	owner:CallLocalEvent(
		what,
		other_entity,
		{
			self_body = self_body,
			other_body = other_body,
			other_entity = other_entity,
			normal = normal,
			overlap = overlap or 0,
			hit = hit,
		}
	)
end

function physics.DispatchCollisionEvents()
	local current = physics.CurrentCollisionPairs or {}
	local previous = physics.PreviousCollisionPairs or {}

	for key, pair in pairs(current) do
		local previous_pair = previous[key]
		local event_name = previous_pair and "OnCollisionStay" or "OnCollisionEnter"
		emit_collision_event(
			event_name,
			pair.body_a and pair.body_a.Owner or nil,
			pair.body_a,
			pair.body_b and pair.body_b.Owner or nil,
			pair.body_b,
			pair.normal,
			pair.overlap
		)
		emit_collision_event(
			event_name,
			pair.body_b and pair.body_b.Owner or nil,
			pair.body_b,
			pair.body_a and pair.body_a.Owner or nil,
			pair.body_a,
			pair.normal * -1,
			pair.overlap
		)
	end

	for key, pair in pairs(previous) do
		if not current[key] then
			emit_collision_event(
				"OnCollisionExit",
				pair.body_a and pair.body_a.Owner or nil,
				pair.body_a,
				pair.body_b and pair.body_b.Owner or nil,
				pair.body_b,
				pair.normal,
				pair.overlap
			)
			emit_collision_event(
				"OnCollisionExit",
				pair.body_b and pair.body_b.Owner or nil,
				pair.body_b,
				pair.body_a and pair.body_a.Owner or nil,
				pair.body_a,
				pair.normal * -1,
				pair.overlap
			)
		end
	end

	local current_world = physics.CurrentWorldCollisionPairs or {}
	local previous_world = physics.PreviousWorldCollisionPairs or {}

	for key, pair in pairs(current_world) do
		local previous_pair = previous_world[key]
		local event_name = previous_pair and "OnCollisionStay" or "OnCollisionEnter"
		emit_collision_event(
			event_name,
			pair.body and pair.body.Owner or nil,
			pair.body,
			pair.entity,
			nil,
			pair.normal,
			pair.overlap,
			pair.hit
		)
		emit_collision_event(
			event_name,
			pair.entity,
			nil,
			pair.body and pair.body.Owner or nil,
			pair.body,
			pair.normal * -1,
			pair.overlap,
			pair.hit
		)
	end

	for key, pair in pairs(previous_world) do
		if not current_world[key] then
			emit_collision_event(
				"OnCollisionExit",
				pair.body and pair.body.Owner or nil,
				pair.body,
				pair.entity,
				nil,
				pair.normal,
				pair.overlap,
				pair.hit
			)
			emit_collision_event(
				"OnCollisionExit",
				pair.entity,
				nil,
				pair.body and pair.body.Owner or nil,
				pair.body,
				pair.normal * -1,
				pair.overlap,
				pair.hit
			)
		end
	end

	physics.PreviousCollisionPairs = current
	physics.CurrentCollisionPairs = {}
	physics.PreviousWorldCollisionPairs = current_world
	physics.CurrentWorldCollisionPairs = {}
end

local function copy_vec3(vec)
	return Vec3(vec.x, vec.y, vec.z)
end

local function quantize(value, epsilon)
	local scaled = value / epsilon
	return scaled >= 0 and math.floor(scaled + 0.5) or math.ceil(scaled - 0.5)
end

local function vec3_key(vec, epsilon)
	return quantize(vec.x, epsilon) .. ":" .. quantize(vec.y, epsilon) .. ":" .. quantize(vec.z, epsilon)
end

local function get_vertex_position(vertex)
	if not vertex then return nil end

	if vertex.pos then vertex = vertex.pos end

	if vertex.x and vertex.y and vertex.z then
		return Vec3(vertex.x, vertex.y, vertex.z)
	end

	if vertex[1] and vertex[2] and vertex[3] then
		return Vec3(vertex[1], vertex[2], vertex[3])
	end

	return nil
end

local function append_source_points(points, source)
	if not source then return end

	if source.Primitives then
		for _, primitive in ipairs(source.Primitives) do
			append_source_points(points, primitive and primitive.polygon3d)
		end

		return
	end

	if source.Vertices then
		for _, vertex in ipairs(source.Vertices) do
			local pos = get_vertex_position(vertex)

			if pos then points[#points + 1] = pos end
		end

		return
	end

	for _, vertex in ipairs(source) do
		local pos = get_vertex_position(vertex)

		if pos then points[#points + 1] = pos end
	end
end

local function dedupe_points(points, epsilon)
	local out = {}
	local seen = {}

	for _, point in ipairs(points) do
		local key = vec3_key(point, epsilon)

		if not seen[key] then
			seen[key] = true
			out[#out + 1] = copy_vec3(point)
		end
	end

	return out
end

local function get_plane_basis(normal)
	local tangent

	if math.abs(normal.x) < 0.8 then
		tangent = normal:GetCross(Vec3(1, 0, 0))
	else
		tangent = normal:GetCross(Vec3(0, 1, 0))
	end

	if tangent:GetLength() <= 0.000001 then
		tangent = normal:GetCross(Vec3(0, 0, 1))
	end

	tangent = tangent:GetNormalized()
	local bitangent = normal:GetCross(tangent):GetNormalized()
	return tangent, bitangent
end

local function hull2d_cross(a, b, c)
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
end

local function build_convex_hull_2d(points, epsilon)
	if #points <= 2 then return points end

	table.sort(points, function(a, b)
		if a.x == b.x then return a.y < b.y end

		return a.x < b.x
	end)

	local unique = {}
	local seen = {}

	for _, point in ipairs(points) do
		local key = quantize(point.x, epsilon) .. ":" .. quantize(point.y, epsilon)

		if not seen[key] then
			seen[key] = true
			unique[#unique + 1] = point
		end
	end

	if #unique <= 2 then return unique end

	local lower = {}

	for _, point in ipairs(unique) do
		while #lower >= 2 and hull2d_cross(lower[#lower - 1], lower[#lower], point) <= epsilon do
			table.remove(lower)
		end

		lower[#lower + 1] = point
	end

	local upper = {}

	for i = #unique, 1, -1 do
		local point = unique[i]

		while #upper >= 2 and hull2d_cross(upper[#upper - 1], upper[#upper], point) <= epsilon do
			table.remove(upper)
		end

		upper[#upper + 1] = point
	end

	table.remove(lower)
	table.remove(upper)

	for _, point in ipairs(upper) do
		lower[#lower + 1] = point
	end

	return lower
end

local function add_unique_edge(edges, seen, a, b)
	local min_index = math.min(a, b)
	local max_index = math.max(a, b)
	local key = min_index .. ":" .. max_index

	if seen[key] then return end

	seen[key] = true
	edges[#edges + 1] = {a = min_index, b = max_index}
end

local function finalize_convex_hull(points, faces, indices, epsilon)
	if not faces[1] then return nil end

	local used = {}
	local remap = {}
	local hull_points = {}
	local hull_faces = {}
	local hull_indices = {}
	local min_bounds = Vec3(math.huge, math.huge, math.huge)
	local max_bounds = Vec3(-math.huge, -math.huge, -math.huge)
	local edges = {}
	local edge_seen = {}

	for _, face in ipairs(faces) do
		for _, index in ipairs(face.indices) do
			used[index] = true
		end
	end

	for index, point in ipairs(points) do
		if used[index] then
			remap[index] = #hull_points + 1
			hull_points[#hull_points + 1] = point
		end
	end

	for _, face in ipairs(faces) do
		local remapped_indices = {}

		for _, index in ipairs(face.indices) do
			remapped_indices[#remapped_indices + 1] = remap[index]
		end

		hull_faces[#hull_faces + 1] = {
			indices = remapped_indices,
			normal = face.normal,
		}
	end

	for i = 1, #indices do
		hull_indices[i] = remap[indices[i]]
	end

	for _, point in ipairs(hull_points) do
		min_bounds.x = math.min(min_bounds.x, point.x)
		min_bounds.y = math.min(min_bounds.y, point.y)
		min_bounds.z = math.min(min_bounds.z, point.z)
		max_bounds.x = math.max(max_bounds.x, point.x)
		max_bounds.y = math.max(max_bounds.y, point.y)
		max_bounds.z = math.max(max_bounds.z, point.z)
	end

	for _, face in ipairs(hull_faces) do
		for i = 1, #face.indices do
			local a = face.indices[i]
			local b = face.indices[i % #face.indices + 1]
			add_unique_edge(edges, edge_seen, a, b)
		end
	end

	return {
		vertices = hull_points,
		faces = hull_faces,
		indices = hull_indices,
		edges = edges,
		bounds_min = min_bounds,
		bounds_max = max_bounds,
		epsilon = epsilon,
	}
end

local function get_indexed_triangles(vertices, indices)
	local triangles = {}

	for tri_idx = 0, math.floor(#indices / 3) - 1 do
		local base = tri_idx * 3
		local a = get_vertex_position(vertices[indices[base + 1] + 1])
		local b = get_vertex_position(vertices[indices[base + 2] + 1])
		local c = get_vertex_position(vertices[indices[base + 3] + 1])

		if a and b and c then triangles[#triangles + 1] = {a, b, c} end
	end

	return triangles
end

local function append_source_triangles(triangles, source)
	if not source then return end

	if source.Primitives then
		for _, primitive in ipairs(source.Primitives) do
			append_source_triangles(triangles, primitive and primitive.polygon3d)
		end

		return
	end

	if source.Vertices then
		local vertices = source.Vertices
		local indices = source.indices

		if indices and #indices >= 3 then
			local indexed = get_indexed_triangles(vertices, indices)

			for _, triangle in ipairs(indexed) do
				triangles[#triangles + 1] = triangle
			end

			return
		end

		for i = 1, #vertices, 3 do
			local a = get_vertex_position(vertices[i])
			local b = get_vertex_position(vertices[i + 1])
			local c = get_vertex_position(vertices[i + 2])

			if a and b and c then triangles[#triangles + 1] = {a, b, c} end
		end

		return
	end

	for i = 1, #source, 3 do
		local a = get_vertex_position(source[i])
		local b = get_vertex_position(source[i + 1])
		local c = get_vertex_position(source[i + 2])

		if a and b and c then triangles[#triangles + 1] = {a, b, c} end
	end
end

local function copy_hull_vertices(vertices)
	local out = {}

	for i, point in ipairs(vertices or {}) do
		out[i] = copy_vec3(point)
	end

	return out
end

local function build_triangle_components(triangles, epsilon)
	epsilon = epsilon or 0.0001
	local vertex_to_triangles = {}
	local visited = {}

	for tri_index, triangle in ipairs(triangles) do
		for _, point in ipairs(triangle) do
			local key = vec3_key(point, epsilon)
			vertex_to_triangles[key] = vertex_to_triangles[key] or {}
			vertex_to_triangles[key][#vertex_to_triangles[key] + 1] = tri_index
		end
	end

	local components = {}

	for tri_index = 1, #triangles do
		if visited[tri_index] then goto continue_component end

		local queue = {tri_index}
		local queue_index = 1
		visited[tri_index] = true
		local component_points = {}

		while queue_index <= #queue do
			local current = queue[queue_index]
			queue_index = queue_index + 1
			local triangle = triangles[current]

			for _, point in ipairs(triangle) do
				component_points[#component_points + 1] = copy_vec3(point)
				local key = vec3_key(point, epsilon)

				for _, linked in ipairs(vertex_to_triangles[key] or {}) do
					if not visited[linked] then
						visited[linked] = true
						queue[#queue + 1] = linked
					end
				end
			end
		end

		components[#components + 1] = dedupe_points(component_points, epsilon)

		::continue_component::
	end

	return components
end

local function build_convex_hull(points, epsilon)
	epsilon = epsilon or 0.0001
	points = dedupe_points(points, epsilon)

	if #points < 4 then return nil end

	local centroid = Vec3(0, 0, 0)

	for _, point in ipairs(points) do
		centroid = centroid + point
	end

	centroid = centroid / #points
	local plane_groups = {}
	local plane_epsilon = math.max(epsilon * 4, 0.0001)

	for i = 1, #points - 2 do
		local a = points[i]

		for j = i + 1, #points - 1 do
			local b = points[j]

			for k = j + 1, #points do
				local c = points[k]
				local normal = (b - a):GetCross(c - a)
				local length = normal:GetLength()

				if length <= plane_epsilon then goto continue end

				normal = normal / length
				local positive = false
				local negative = false

				for m = 1, #points do
					if m ~= i and m ~= j and m ~= k then
						local distance = (points[m] - a):Dot(normal)

						if distance > plane_epsilon then
							positive = true
						elseif distance < -plane_epsilon then
							negative = true
						end

						if positive and negative then break end
					end
				end

				if positive and negative then goto continue end

				if normal:Dot(centroid - a) > 0 then normal = normal * -1 end

				local plane_distance = normal:Dot(a)
				local key = vec3_key(normal, plane_epsilon) .. ":" .. quantize(plane_distance, plane_epsilon)
				local group = plane_groups[key]

				if not group then
					group = {
						normal = normal,
						distance = plane_distance,
						vertices = {},
					}
					plane_groups[key] = group
				end

				for m = 1, #points do
					if math.abs(points[m]:Dot(group.normal) - group.distance) <= plane_epsilon then
						group.vertices[m] = true
					end
				end

				::continue::
			end
		end
	end

	local faces = {}
	local indices = {}

	for _, group in pairs(plane_groups) do
		local face_indices = {}
		local face_center = Vec3(0, 0, 0)

		for index in pairs(group.vertices) do
			face_indices[#face_indices + 1] = index
			face_center = face_center + points[index]
		end

		if #face_indices >= 3 then
			face_center = face_center / #face_indices
			local tangent, bitangent = get_plane_basis(group.normal)
			local projected = {}

			for _, index in ipairs(face_indices) do
				local point = points[index]
				local relative = point - face_center
				projected[#projected + 1] = {
					x = relative:Dot(tangent),
					y = relative:Dot(bitangent),
					index = index,
				}
			end

			local ordered = build_convex_hull_2d(projected, plane_epsilon)

			if #ordered >= 3 then
				local ordered_indices = {}

				for _, point in ipairs(ordered) do
					ordered_indices[#ordered_indices + 1] = point.index
				end

				faces[#faces + 1] = {
					indices = ordered_indices,
					normal = copy_vec3(group.normal),
				}

				for i = 2, #ordered_indices - 1 do
					indices[#indices + 1] = ordered_indices[1]
					indices[#indices + 1] = ordered_indices[i]
					indices[#indices + 1] = ordered_indices[i + 1]
				end
			end
		end
	end

	return finalize_convex_hull(points, faces, indices, epsilon)
end

function physics.NormalizeConvexHull(hull, epsilon)
	if not hull then return nil end

	if hull.vertices and hull.faces and hull.indices and hull.edges then
		return finalize_convex_hull(
			dedupe_points(hull.vertices, epsilon or hull.epsilon or 0.0001),
			hull.faces,
			hull.indices,
			epsilon or hull.epsilon or 0.0001
		)
	end

	return build_convex_hull(hull.vertices or hull, epsilon)
end

function physics.BuildConvexHullFromTriangles(source, epsilon)
	local points = {}
	append_source_points(points, source)
	return build_convex_hull(points, epsilon)
end

function physics.BuildConvexHullFromModel(model, epsilon)
	local points = {}
	append_source_points(points, model)
	return build_convex_hull(points, epsilon)
end

function physics.BuildCompoundShapeFromTriangles(source, epsilon)
	epsilon = epsilon or 0.0001
	local triangles = {}
	append_source_triangles(triangles, source)

	if not triangles[1] then return nil end

	local components = build_triangle_components(triangles, epsilon)
	local children = {}

	for _, points in ipairs(components) do
		local hull = build_convex_hull(points, epsilon)

		if hull and hull.vertices and hull.vertices[1] then
			local center = (hull.bounds_min + hull.bounds_max) * 0.5
			local local_vertices = copy_hull_vertices(hull.vertices)

			for _, point in ipairs(local_vertices) do
				point.x = point.x - center.x
				point.y = point.y - center.y
				point.z = point.z - center.z
			end

			local local_hull = build_convex_hull(local_vertices, epsilon)

			if local_hull then
				children[#children + 1] = {
					Position = center,
					ConvexHull = local_hull,
				}
			end
		end
	end

	if not children[1] then return nil end

	return {
		children = children,
		epsilon = epsilon,
	}
end

function physics.BuildCompoundShapeFromModel(model, epsilon)
	return physics.BuildCompoundShapeFromTriangles(model, epsilon)
end

physics.ApproximateConvexMeshFromTriangles = physics.BuildConvexHullFromTriangles
return physics