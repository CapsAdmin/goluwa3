local Vec3 = import("goluwa/structs/vec3.lua")
local collider_debug = {}
local edge_cache = table.weak("k")
local BOX_EDGES = {
	{1, 2},
	{3, 4},
	{5, 6},
	{7, 8},
	{1, 3},
	{2, 4},
	{5, 7},
	{6, 8},
	{1, 5},
	{2, 6},
	{3, 7},
	{4, 8},
}

function collider_debug.GetEdges(polyhedron)
	local cached = edge_cache[polyhedron]

	if cached then return cached end

	local edges = {}
	local seen = {}

	local function add(a, b)
		if a > b then a, b = b, a end

		local key = a * 100000 + b

		if not seen[key] then
			seen[key] = true
			edges[#edges + 1] = {a, b}
		end
	end

	if polyhedron.edges then
		for _, edge in ipairs(polyhedron.edges) do
			add(edge.a or edge[1], edge.b or edge[2])
		end
	elseif polyhedron.faces then
		for _, face in ipairs(polyhedron.faces) do
			local indices = face.indices

			for i = 1, #indices do
				add(indices[i], indices[i % #indices + 1])
			end
		end
	elseif polyhedron.indices then
		local indices = polyhedron.indices

		for i = 1, #indices, 3 do
			add(indices[i], indices[i + 1])
			add(indices[i + 1], indices[i + 2])
			add(indices[i + 2], indices[i])
		end
	end

	edge_cache[polyhedron] = edges
	return edges
end

function collider_debug.GetPolyhedron(collider)
	local shape = collider:GetPhysicsShape()
	return shape.GetPolyhedron and shape:GetPolyhedron(collider) or nil
end

function collider_debug.Describe(collider)
	local shape = collider:GetPhysicsShape()
	local polyhedron = collider_debug.GetPolyhedron(collider)
	local min = Vec3(math.huge, math.huge, math.huge)
	local max = Vec3(-math.huge, -math.huge, -math.huge)
	local count = 0

	if polyhedron and polyhedron.vertices then
		for _, vertex in ipairs(polyhedron.vertices) do
			count = count + 1
			min:Set(math.min(min.x, vertex.x), math.min(min.y, vertex.y), math.min(min.z, vertex.z))
			max:Set(math.max(max.x, vertex.x), math.max(max.y, vertex.y), math.max(max.z, vertex.z))
		end
	elseif shape:GetTypeName() == "sphere" then
		local radius = shape:GetRadius()
		min:Set(-radius, -radius, -radius)
		max:Set(radius, radius, radius)
	elseif shape:GetTypeName() == "capsule" then
		local radius, half = shape:GetRadius(), shape:GetHeight() * 0.5
		min:Set(-radius, -half, -radius)
		max:Set(radius, half, radius)
	else
		min:Set(0, 0, 0)
		max:Set(0, 0, 0)
	end

	local position, rotation = collider:GetLocalPosition(), collider:GetLocalRotation()
	return {
		shape:GetTypeName(),
		count,
		min.x,
		min.y,
		min.z,
		max.x,
		max.y,
		max.z,
		position.x,
		position.y,
		position.z,
		rotation.x,
		rotation.y,
		rotation.z,
		rotation.w,
	}
end

collider_debug.BOX_EDGES = BOX_EDGES
return collider_debug
