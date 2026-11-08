local ffi = require("ffi")
local codec = import("goluwa/codec.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local model_file = {}
model_file.Extension = ".mesh"
model_file.FileName = "model.mesh"
local MAGIC = "GLWM"
local VERSION = 2

local function u32(value)
	return string.char(
		value % 256,
		math.floor(value / 256) % 256,
		math.floor(value / 65536) % 256,
		math.floor(value / 16777216) % 256
	)
end

-- The CPU side of an uploaded mesh: the packed vertices and the indices it was created with.
-- Returns nil and a reason for a mesh that cannot be written.
function model_file.GetGeometry(polygon)
	local mesh = polygon.mesh

	if not mesh or not mesh:IsValid() then return nil, "no mesh" end

	local vertex_buffer = mesh.vertex_buffer

	if not vertex_buffer or not vertex_buffer.data then
		return nil, "no vertex data"
	end

	local count = vertex_buffer:GetVertexCount()

	if vertex_buffer.byte_size ~= count * vertex_layout.Stride then
		return nil, "unexpected vertex layout"
	end

	local index_buffer = mesh.index_buffer
	local indices, index_count, index_type = nil, 0, nil

	if index_buffer then
		indices = index_buffer:GetData()
		index_count = index_buffer:GetIndexCount()
		index_type = index_buffer:GetIndexTypeFFI()
	end

	return {
		vertices = vertex_buffer.data,
		vertex_count = count,
		indices = indices,
		index_count = index_count,
		index_type = index_type,
	}
end

-- What of a model the file carries, for a model that is loaded: its meshes with their skin, the
-- skeleton (bones, parents, bind pose, inverse bind) and the physics children (convex hulls and
-- mesh colliders) with the mass properties. Animations, pose parameters, flexes and ragdolls are
-- not carried, they are listed in the returned `dropped`.
function model_file.GetDropped(loaded)
	local dropped = {}
	local skeleton = loaded.skeleton

	if skeleton then
		if skeleton.Clips and skeleton.Clips[1] then
			dropped[#dropped + 1] = "animations"
		end

		if skeleton.PoseParameterNames and skeleton.PoseParameterNames[1] then
			dropped[#dropped + 1] = "pose parameters"
		end

		if skeleton.Flex then dropped[#dropped + 1] = "flexes" end
	end

	if loaded.physics and loaded.physics.ragdoll then
		dropped[#dropped + 1] = "ragdoll"
	end

	return dropped
end

-- model: {meshes = {{polygon, material = path relative to the model file's directory or nil}},
-- bounds = {min, max}, source = path it came from, physics = model.physics, skeleton = Skeleton}.
-- Returns the file contents.
function model_file.Serialize(model)
	local header = {
		version = VERSION,
		vertex_stride = vertex_layout.Stride,
		source = model.source,
		meshes = {},
	}
	local blobs, size = {}, 0

	local function add(pointer, bytes)
		local offset = size
		blobs[#blobs + 1] = ffi.string(pointer, bytes)
		size = size + bytes
		return offset
	end

	local skin_ids = {}

	for i, entry in ipairs(model.meshes) do
		local polygon = entry.polygon
		local geometry = assert(model_file.GetGeometry(polygon))
		local aabb = polygon.AABB
		local info = {
			material = entry.material,
			vertex_count = geometry.vertex_count,
			vertex_offset = add(geometry.vertices, geometry.vertex_count * vertex_layout.Stride),
			index_count = geometry.index_count,
			index_type = geometry.index_type,
			aabb = {aabb.min_x, aabb.min_y, aabb.min_z, aabb.max_x, aabb.max_y, aabb.max_z},
			bend_height = polygon.BendHeight,
			root_chain = polygon.RootChain,
			material_slot = polygon.MaterialSlot,
			lod_level = polygon.LODLevel,
			lod_distance = polygon.LODDistance,
			lod_billboard = polygon.LODBillboard,
		}

		if geometry.index_count > 0 then
			info.index_offset = add(geometry.indices, geometry.index_count * ffi.sizeof(geometry.index_type))
		end

		local skin = polygon.Skin

		if skin then
			if not skin_ids[skin] then
				header.skins = header.skins or {}
				header.skins[#header.skins + 1] = {
					indices_offset = add(skin.BoneIndices, ffi.sizeof(skin.BoneIndices)),
					indices_bytes = ffi.sizeof(skin.BoneIndices),
					weights_offset = add(skin.BoneWeights, ffi.sizeof(skin.BoneWeights)),
					weights_bytes = ffi.sizeof(skin.BoneWeights),
				}
				skin_ids[skin] = #header.skins
			end

			info.skin = skin_ids[skin]
		end

		header.meshes[i] = info
	end

	if model.bounds then header.bounds = {model.bounds.min, model.bounds.max} end

	local skeleton = model.skeleton

	if skeleton then
		local parents = {}

		for bone = 1, skeleton.BoneCount do
			parents[bone] = skeleton.parents[bone - 1]
		end

		header.skeleton = {
			bone_names = skeleton.BoneNames,
			parents = parents,
			bind_offset = add(skeleton.BindLocal, skeleton.BoneCount * Skeleton.PoseSize * 4),
			inverse_bind_offset = add(skeleton.InverseBind, skeleton.BoneCount * Skeleton.MatrixSize * 4),
		}
	end

	local physics = model.physics

	if physics then
		local out = {
			mass = physics.mass,
			surface_property = physics.surface_property,
			center_of_mass = physics.center_of_mass,
			damping = physics.damping,
			rotation_damping = physics.rotation_damping,
			inertia = physics.inertia,
			children = {},
		}

		for i, child in ipairs(physics.children) do
			if child.ConvexHull then
				out.children[i] = {hull = convex_hull.ToPlain(child.ConvexHull), position = child.Position}
			else
				local polygon = child.Polygon3D
				local count = #polygon.Vertices
				local positions = ffi.new("float[?]", count * 3)

				for v = 1, count do
					local pos = polygon.Vertices[v].pos
					positions[(v - 1) * 3], positions[(v - 1) * 3 + 1], positions[(v - 1) * 3 + 2] = pos.x, pos.y, pos.z
				end

				local indices = ffi.new("uint32_t[?]", #polygon.indices)

				for k = 1, #polygon.indices do
					indices[k - 1] = polygon.indices[k]
				end

				out.children[i] = {
					vertex_count = count,
					positions_offset = add(positions, count * 12),
					index_count = #polygon.indices,
					indices_offset = add(indices, #polygon.indices * 4),
				}
			end
		end

		header.physics = out
	end

	local text = codec.Encode("luadata", header, true)
	return MAGIC .. u32(#text) .. text .. table.concat(blobs)
end

-- Returns the header and the reader of what is in the blob.
function model_file.Read(data)
	assert(data:sub(1, 4) == MAGIC, "not a model file")
	local b1, b2, b3, b4 = data:byte(5, 8)
	local header_length = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	local header = assert(codec.Decode("luadata", data:sub(9, 8 + header_length)))
	assert(
		header.version == VERSION,
		"unsupported model file version " .. tostring(header.version)
	)
	assert(
		header.vertex_stride == vertex_layout.Stride,
		"model file vertex layout does not match the engine"
	)
	local blob = ffi.cast("const char*", data) + 8 + header_length
	-- blob points into the string, the reader keeps the string alive
	local reader = {data = data}

	local function copy(ctype, offset, count)
		local array = ffi.new(ctype .. "[?]", count)
		ffi.copy(array, blob + offset, count * ffi.sizeof(ctype))
		return array
	end

	function reader.Mesh(mesh)
		local vertices = vertex_layout.ArrayType(mesh.vertex_count)
		ffi.copy(vertices, blob + mesh.vertex_offset, mesh.vertex_count * vertex_layout.Stride)
		local indices

		if mesh.index_count > 0 then
			indices = copy(mesh.index_type, mesh.index_offset, mesh.index_count)
		end

		return vertices, indices
	end

	function reader.Skin(info)
		return {
			BoneIndices = copy("uint8_t", info.indices_offset, info.indices_bytes),
			BoneWeights = copy("float", info.weights_offset, info.weights_bytes / 4),
			Flexes = {},
		}
	end

	function reader.Skeleton(info)
		local count = #info.bone_names
		return Skeleton.New{
			BoneNames = info.bone_names,
			Parents = info.parents,
			BindLocal = copy("float", info.bind_offset, count * Skeleton.PoseSize),
			InverseBind = copy("float", info.inverse_bind_offset, count * Skeleton.MatrixSize),
		}
	end

	function reader.Physics(info)
		local children = {}

		for i, child in ipairs(info.children) do
			if child.hull then
				children[i] = {ConvexHull = convex_hull.FromPlain(child.hull), Position = child.position}
			else
				local positions = copy("float", child.positions_offset, child.vertex_count * 3)
				local indices = copy("uint32_t", child.indices_offset, child.index_count)
				local polygon = Polygon3D.New()

				for v = 1, child.vertex_count do
					polygon.Vertices[v] = {
						pos = Vec3(positions[(v - 1) * 3], positions[(v - 1) * 3 + 1], positions[(v - 1) * 3 + 2]),
					}
				end

				polygon.indices = {}

				for k = 1, child.index_count do
					polygon.indices[k] = indices[k - 1]
				end

				polygon:BuildBoundingBox()
				children[i] = {Polygon3D = polygon}
			end
		end

		return {
			children = children,
			mass = info.mass,
			surface_property = info.surface_property,
			center_of_mass = info.center_of_mass,
			damping = info.damping,
			rotation_damping = info.rotation_damping,
			inertia = info.inertia,
		}
	end

	return header, reader
end

return model_file
