local polyhedron_cache = {}
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local TEMP_WORLD_NORMAL = Vec3()

local function fill_polyhedron_world_vertices(polyhedron_data, position, rotation, out)
	out = out or {}
	local vertices = polyhedron_data.vertices
	local count = 0

	for i = 1, #vertices do
		local world_point = out[i]

		if not world_point then
			world_point = Vec3()
			out[i] = world_point
		end

		Quat.SetVecMul(world_point, rotation, vertices[i])
		world_point:Add(position)
		count = i
	end

	for i = count + 1, #out do
		out[i] = nil
	end

	return out
end

local function fill_polyhedron_world_faces(polyhedron_data, world_vertices, rotation, out)
	out = out or {}
	local faces = polyhedron_data.faces
	local face_count = 0

	for face_index = 1, #faces do
		local face = faces[face_index]
		local cached_face = out[face_index]

		if not cached_face then
			cached_face = {points = {}}
			out[face_index] = cached_face
		end

		local points = cached_face.points
		local count = 0

		for i = 1, #face.indices do
			points[i] = world_vertices[face.indices[i]]
			count = i
		end

		for i = count + 1, #points do
			points[i] = nil
		end

		local normal = cached_face.normal

		if not normal then
			normal = Vec3()
			cached_face.normal = normal
		end

		Quat.SetVecMul(normal, rotation, face.normal)
		normal:Normalize()
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
	local faces = polyhedron_data.faces
	local world_normal = TEMP_WORLD_NORMAL

	for face_index = 1, #faces do
		local face = faces[face_index]
		Quat.SetVecMul(world_normal, rotation, face.normal)
		world_normal:Normalize()
		local dot = world_normal:Dot(reference_normal)

		if dot < best_dot then
			best_dot = dot
			best_index = face_index
		end
	end

	return best_index
end

return polyhedron_cache
