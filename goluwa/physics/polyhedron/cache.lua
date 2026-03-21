local polyhedron_cache = {}

local function local_to_world_at(position, rotation, local_point)
	return position + rotation:VecMul(local_point)
end

local function fill_polyhedron_world_vertices(polyhedron_data, position, rotation, out)
	out = out or {}
	local count = 0

	for i, point in ipairs(polyhedron_data.vertices or {}) do
		out[i] = local_to_world_at(position, rotation, point)
		count = i
	end

	for i = count + 1, #out do
		out[i] = nil
	end

	return out
end

local function fill_polyhedron_world_faces(polyhedron_data, world_vertices, rotation, out)
	out = out or {}
	local face_count = 0

	for face_index, face in ipairs(polyhedron_data.faces or {}) do
		local cached_face = out[face_index] or {points = {}}
		local points = cached_face.points
		local count = 0

		for i, vertex_index in ipairs(face.indices or {}) do
			points[i] = world_vertices[vertex_index]
			count = i
		end

		for i = count + 1, #points do
			points[i] = nil
		end

		cached_face.normal = rotation:VecMul(face.normal):GetNormalized()
		cached_face.face_index = face_index
		out[face_index] = cached_face
		face_count = face_index
	end

	for i = face_count + 1, #out do
		out[i] = nil
	end

	return out
end

local function get_polyhedron_world_cache(body, polyhedron_data)
	local position = body:GetPosition()
	local rotation = body:GetRotation()
	local cache = body._PhysicsPolyhedronWorldVerticesCache or {}
	body._PhysicsPolyhedronWorldVerticesCache = cache

	if
		cache.polyhedron == polyhedron_data and
		cache.px == position.x and
		cache.py == position.y and
		cache.pz == position.z and
		cache.rx == rotation.x and
		cache.ry == rotation.y and
		cache.rz == rotation.z and
		cache.rw == rotation.w
	then
		return cache
	end

	cache.polyhedron = polyhedron_data
	cache.px = position.x
	cache.py = position.y
	cache.pz = position.z
	cache.rx = rotation.x
	cache.ry = rotation.y
	cache.rz = rotation.z
	cache.rw = rotation.w
	cache.vertices = fill_polyhedron_world_vertices(polyhedron_data, position, rotation, cache.vertices)
	cache.faces_valid = false
	return cache
end

function polyhedron_cache.FillPolyhedronWorldVertices(polyhedron_data, position, rotation, out)
	return fill_polyhedron_world_vertices(polyhedron_data, position, rotation, out)
end

function polyhedron_cache.GetPolyhedronWorldVertices(body, polyhedron_data)
	return get_polyhedron_world_cache(body, polyhedron_data).vertices
end

function polyhedron_cache.GetPolyhedronWorldFace(body, polyhedron_data, face_index)
	local cache = get_polyhedron_world_cache(body, polyhedron_data)

	if not cache.faces_valid then
		cache.faces = fill_polyhedron_world_faces(polyhedron_data, cache.vertices, body:GetRotation(), cache.faces)
		cache.faces_valid = true
	end

	return cache.faces and cache.faces[face_index]
end

function polyhedron_cache.FindIncidentFaceIndex(polyhedron_data, rotation, reference_normal)
	local best_index = nil
	local best_dot = math.huge

	for face_index, face in ipairs(polyhedron_data.faces or {}) do
		local world_normal = rotation:VecMul(face.normal):GetNormalized()
		local dot = world_normal:Dot(reference_normal)

		if dot < best_dot then
			best_dot = dot
			best_index = face_index
		end
	end

	return best_index
end

return polyhedron_cache
