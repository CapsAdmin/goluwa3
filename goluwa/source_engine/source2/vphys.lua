local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local surface_properties = import("goluwa/source_engine/source2/surface_properties.lua")
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

local function to_engine(x, y, z, pose)
	if pose then
		x, y, z = pose[1] * x + pose[2] * y + pose[3] * z + pose[4],
		pose[5] * x + pose[6] * y + pose[7] * z + pose[8],
		pose[9] * x + pose[10] * y + pose[11] * z + pose[12]
	end

	return Vec3(-y * SCALE, z * SCALE, -x * SCALE)
end

-- shapes of a part are in the space of its bone; the bind pose (3x4, row major) places them in the model
local function get_part_pose(data, part_index)
	local poses = data.m_bindPose
	local pose = poses and poses[#poses == #data.m_parts and part_index or 1]

	if not pose or #pose < 12 then return nil end

	if
		pose[1] == 1 and
		pose[2] == 0 and
		pose[3] == 0 and
		pose[4] == 0 and
		pose[5] == 0 and
		pose[6] == 1 and
		pose[7] == 0 and
		pose[8] == 0 and
		pose[9] == 0 and
		pose[10] == 0 and
		pose[11] == 1 and
		pose[12] == 0
	then
		return nil
	end

	return pose
end

local function add_mesh(children, mesh, pose)
	if type(mesh.m_Triangles) ~= "string" then return end

	local vertices = ffi.cast(f32_ptr_t, mesh.m_Vertices)
	local triangles = ffi.cast(i32_ptr_t, mesh.m_Triangles)
	local chunks = {}

	for t = 0, #mesh.m_Triangles / 12 - 1 do
		local a, b, c = triangles[t * 3], triangles[t * 3 + 1], triangles[t * 3 + 2]
		local center = to_engine(
			(vertices[a * 3] + vertices[b * 3] + vertices[c * 3]) / 3,
			(vertices[a * 3 + 1] + vertices[b * 3 + 1] + vertices[c * 3 + 1]) / 3,
			(vertices[a * 3 + 2] + vertices[b * 3 + 2] + vertices[c * 3 + 2]) / 3,
			pose
		)
		local ex, ey, ez = center.x, center.y, center.z
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
					pos = to_engine(
						vertices[source_index * 3],
						vertices[source_index * 3 + 1],
						vertices[source_index * 3 + 2],
						pose
					),
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

local capsule_hulls = {}

local function add_hull_points(children, points)
	local polygon = {Vertices = {}}

	for i, point in ipairs(points) do
		polygon.Vertices[i] = {pos = point}
	end

	local child = convex_hull.FromPolygon3D(polygon)

	if child then children[#children + 1] = child end
end

function vphys.NewBody()
	return {
		mass = 0,
		linear_damping = 0,
		angular_damping = 0,
		weight = 0,
		friction = 0,
		elasticity = 0,
		density = 0,
	}
end

local function add_surface(body, hashes, index, weight)
	local surface = surface_properties.GetByHash(hashes[index + 1])
	body.weight = body.weight + weight
	body.friction = body.friction + surface.friction * weight
	body.elasticity = body.elasticity + surface.elasticity * weight
	body.density = body.density + surface.density * weight
end

-- the engine has one material per body, so the surfaces of all shapes are averaged by triangle (a hull counts as one)
function vphys.GetBodyProperties(body)
	local properties = {
		Friction = body.friction / body.weight,
		Restitution = body.elasticity / body.weight,
		FrictionCombineMode = "multiply",
		RestitutionCombineMode = "multiply",
	}

	if body.mass == 0 then
		properties.Density = body.density / body.weight
	else
		properties.Mass = body.mass
		properties.AutomaticMass = false
		properties.LinearDamping = body.linear_damping / body.mass
		properties.AirLinearDamping = properties.LinearDamping
		properties.AngularDamping = body.angular_damping / body.mass
		properties.AirAngularDamping = properties.AngularDamping
	end

	return properties
end

function vphys.Append(children, data, body)
	local hashes = data.m_surfacePropertyHashes

	for part_index, part in ipairs(data.m_parts) do
		local shape = part.m_rnShape
		local pose = get_part_pose(data, part_index)
		body.mass = body.mass + part.m_flMass
		body.linear_damping = body.linear_damping + part.m_flLinearDamping * part.m_flMass
		body.angular_damping = body.angular_damping + part.m_flAngularDamping * part.m_flMass

		for _, mesh in ipairs(shape.m_meshes) do
			add_mesh(children, mesh.m_Mesh, pose)
			local materials = mesh.m_Mesh.m_Materials

			if materials[1] then
				local counts = {}

				for i = 1, #materials do
					counts[materials[i]] = (counts[materials[i]] or 0) + 1
				end

				for index, count in pairs(counts) do
					add_surface(body, hashes, index, count)
				end
			else
				add_surface(body, hashes, mesh.m_nSurfacePropertyIndex, #mesh.m_Mesh.m_Triangles / 12)
			end
		end

		for _, hull in ipairs(shape.m_hulls) do
			add_surface(body, hashes, hull.m_nSurfacePropertyIndex, 1)
			local points = {}

			for i, v in ipairs(hull.m_Hull.m_Vertices) do
				points[i] = to_engine(v[1], v[2], v[3], pose)
			end

			add_hull_points(children, points)
		end

		for _, sphere in ipairs(shape.m_spheres) do
			add_surface(body, hashes, sphere.m_nSurfacePropertyIndex, 1)
			local c = sphere.m_Sphere.m_vCenter
			children[#children + 1] = {
				Shape = SphereShape.New(sphere.m_Sphere.m_flRadius * SCALE),
				Position = to_engine(c[1], c[2], c[3], pose),
			}
		end

		for _, capsule in ipairs(shape.m_capsules) do
			add_surface(body, hashes, capsule.m_nSurfacePropertyIndex, 1)
			local a, b = capsule.m_Capsule.m_vCenter[1], capsule.m_Capsule.m_vCenter[2]
			local radius = capsule.m_Capsule.m_flRadius * SCALE
			local from, to = to_engine(a[1], a[2], a[3], pose), to_engine(b[1], b[2], b[3], pose)
			local half = (to - from) * 0.5
			local key = string.format("%.4f:%.4f:%.4f:%.4f", half.x, half.y, half.z, radius)
			local cached = capsule_hulls[key]

			if not cached then
				local vertices = {}

				for _, end_point in ipairs{half, half * -1} do
					for _, direction in ipairs(DIRECTIONS) do
						vertices[#vertices + 1] = {pos = end_point + direction * radius}
					end
				end

				cached = convex_hull.FromPolygon3D({Vertices = vertices})
				capsule_hulls[key] = cached
			end

			if cached.ConvexHull then
				children[#children + 1] = {ConvexHull = cached.ConvexHull, Position = cached.Position + (from + to) * 0.5}
			end
		end
	end
end

function vphys.FromData(data)
	local children, body = {}, vphys.NewBody()
	vphys.Append(children, data, body)
	return children, body.weight > 0 and vphys.GetBodyProperties(body) or nil
end

function vphys.Load(path)
	return vphys.FromData(resource.ReadKV3(resource.Load(vfs, path)))
end

return vphys
