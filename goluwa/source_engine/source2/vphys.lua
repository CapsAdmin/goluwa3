local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local units = import("goluwa/source_engine/units.lua")
local vphys = {}
local SCALE = units.meters
local CHUNK_SIZE = 6
local f32_ptr_t = ffi.typeof("const float *")
local i32_ptr_t = ffi.typeof("const int32_t *")
local DIRECTIONS = {}

for x = -1, 1 do
	for y = -1, 1 do
		for z = -1, 1 do
			if x ~= 0 or y ~= 0 or z ~= 0 then
				DIRECTIONS[#DIRECTIONS + 1] = Vec3(x, y, z):GetNormalized()
			end
		end
	end
end

local function to_engine(x, y, z)
	return Vec3(-y * SCALE, z * SCALE, -x * SCALE)
end

local function add_mesh(children, mesh)
	local vertices = ffi.cast(f32_ptr_t, mesh.m_Vertices)
	local triangles = ffi.cast(i32_ptr_t, mesh.m_Triangles)
	local chunks = {}

	for t = 0, #mesh.m_Triangles / 12 - 1 do
		local a, b, c = triangles[t * 3], triangles[t * 3 + 1], triangles[t * 3 + 2]
		local cx = (vertices[a * 3] + vertices[b * 3] + vertices[c * 3]) / 3
		local cy = (vertices[a * 3 + 1] + vertices[b * 3 + 1] + vertices[c * 3 + 1]) / 3
		local cz = (vertices[a * 3 + 2] + vertices[b * 3 + 2] + vertices[c * 3 + 2]) / 3
		local ex, ey, ez = -cy * SCALE, cz * SCALE, -cx * SCALE
		local key = math.floor(ex / CHUNK_SIZE) .. ":" .. math.floor(ey / CHUNK_SIZE) .. ":" .. math.floor(ez / CHUNK_SIZE)
		local chunk = chunks[key]

		if not chunk then
			chunk = {vertices = {}, indices = {}, remap = {}}
			chunks[key] = chunk
		end

		for _, source_index in ipairs{a, b, c} do
			local index = chunk.remap[source_index]

			if not index then
				index = #chunk.vertices
				chunk.remap[source_index] = index
				chunk.vertices[index + 1] = {
					pos = to_engine(vertices[source_index * 3], vertices[source_index * 3 + 1], vertices[source_index * 3 + 2]),
				}
			end

			chunk.indices[#chunk.indices + 1] = index
		end

		if t % 20000 == 0 then tasks.Wait() end
	end

	for _, chunk in pairs(chunks) do
		children[#children + 1] = {Shape = MeshShape.New{Vertices = chunk.vertices, indices = chunk.indices}}
	end
end

local function add_hull_points(children, points)
	local polygon = {Vertices = {}}

	for i, point in ipairs(points) do
		polygon.Vertices[i] = {pos = point}
	end

	local child = convex_hull.FromPolygon3D(polygon)

	if child.ConvexHull then children[#children + 1] = child end
end

function vphys.Append(children, data)

	for _, part in ipairs(data.m_parts) do
		local shape = part.m_rnShape

		for _, mesh in ipairs(shape.m_meshes) do
			add_mesh(children, mesh.m_Mesh)
		end

		for _, hull in ipairs(shape.m_hulls) do
			local points = {}

			for i, v in ipairs(hull.m_Hull.m_Vertices) do
				points[i] = to_engine(v[1], v[2], v[3])
			end

			add_hull_points(children, points)
		end

		for _, sphere in ipairs(shape.m_spheres) do
			local c = sphere.m_Sphere.m_vCenter
			children[#children + 1] = {
				Shape = SphereShape.New(sphere.m_Sphere.m_flRadius * SCALE),
				Position = to_engine(c[1], c[2], c[3]),
			}
		end

		for _, capsule in ipairs(shape.m_capsules) do
			local a, b = capsule.m_Capsule.m_vCenter[1], capsule.m_Capsule.m_vCenter[2]
			local radius = capsule.m_Capsule.m_flRadius * SCALE
			local points = {}

			for _, end_point in ipairs{to_engine(a[1], a[2], a[3]), to_engine(b[1], b[2], b[3])} do
				for _, direction in ipairs(DIRECTIONS) do
					points[#points + 1] = end_point + direction * radius
				end
			end

			add_hull_points(children, points)
		end
	end

end

function vphys.FromData(data)
	local children = {}
	vphys.Append(children, data)
	return children
end

function vphys.Load(path)
	return vphys.FromData(resource.ReadKV3(resource.Load(vfs, path)))
end

return vphys
