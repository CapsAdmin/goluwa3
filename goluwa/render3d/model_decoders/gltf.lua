local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local gltf = import("goluwa/codecs/gltf.lua")
local animation_bank = import("goluwa/render3d/animation_bank.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local gltf_decoder = {}
local CLIP_FPS = 30

function gltf_decoder.BuildVertices(primitive)
	local position = primitive.attributes.POSITION
	local normal = primitive.attributes.NORMAL
	local texcoord = primitive.attributes.TEXCOORD_0
	local tangent = primitive.attributes.TANGENT

	if not position then return nil, "POSITION attribute is required" end

	local vertex_count = position.count
	local vertices = Polygon3D.VertexType(vertex_count)
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for i = 0, vertex_count - 1 do
		local vertex = vertices[i]
		local px, py, pz = position.data[i * 3 + 0], position.data[i * 3 + 1], position.data[i * 3 + 2]
		vertex.position[0], vertex.position[1], vertex.position[2] = px, py, pz
		min_x, min_y, min_z = math.min(min_x, px), math.min(min_y, py), math.min(min_z, pz)
		max_x, max_y, max_z = math.max(max_x, px), math.max(max_y, py), math.max(max_z, pz)

		if normal then
			vertex.normal[0], vertex.normal[1], vertex.normal[2] = normal.data[i * 3 + 0], normal.data[i * 3 + 1], normal.data[i * 3 + 2]
		else
			vertex.normal[0], vertex.normal[1], vertex.normal[2] = 0, 0, 1
		end

		if texcoord then
			vertex.uv[0], vertex.uv[1] = texcoord.data[i * 2 + 0], 1 - texcoord.data[i * 2 + 1]
		end

		if tangent then
			vertex.tangent[0], vertex.tangent[1], vertex.tangent[2], vertex.tangent[3] = tangent.data[i * 4 + 0],
			tangent.data[i * 4 + 1],
			tangent.data[i * 4 + 2],
			tangent.data[i * 4 + 3]
		else
			vertex.tangent[0], vertex.tangent[1], vertex.tangent[2], vertex.tangent[3] = 1, 0, 0, 1
		end

		vertex.texture_blend = 0
		vertex.vertex_color[0], vertex.vertex_color[1], vertex.vertex_color[2], vertex.vertex_color[3] = 1, 1, 1, 1
	end

	return vertices, vertex_count, AABB(min_x, min_y, min_z, max_x, max_y, max_z)
end

local function decode(path, full_path, mesh_callback, physics_callback, skeleton_callback)
	local data = assert(gltf.Load(full_path))
	local skin = assert(data.skins[1], path .. " has no skin")
	local bank = animation_bank.FromData(data, CLIP_FPS)
	local count = #bank.bone_names
	local inverse_bind = ffi.new("float[?]", count * Skeleton.MatrixSize)
	local matrices = skin.inverse_bind_matrices.data

	for joint = 0, count - 1 do
		for row = 0, 2 do
			for column = 0, 3 do
				inverse_bind[joint * 12 + row * 4 + column] = matrices[joint * 16 + column * 4 + row]
			end
		end
	end

	local skeleton = Skeleton.New{
		BoneNames = bank.bone_names,
		Parents = bank.parents,
		BindLocal = bank.bind,
		InverseBind = inverse_bind,
	}
	animation_bank.AddNativeClips(skeleton, bank)
	skeleton_callback(skeleton)
	local materials = {}

	for _, node in ipairs(data.nodes) do
		if node.skin == 0 and node.mesh then
			for _, primitive in ipairs(data.meshes[node.mesh + 1].primitives) do
				local vertices, vertex_count, aabb = assert(gltf_decoder.BuildVertices(primitive))
				local joints, weights = primitive.attributes.JOINTS_0, primitive.attributes.WEIGHTS_0
				assert(joints and weights, path .. " has a primitive without joints")
				assert(weights.component_type == "float", "only float skin weights are supported")
				local bone_indices = ffi.new("uint8_t[?]", vertex_count * 4)
				local bone_weights = ffi.new("float[?]", vertex_count * 4)

				for i = 0, vertex_count * 4 - 1 do
					bone_indices[i] = joints.data[i]
					bone_weights[i] = weights.data[i]
				end

				local poly = Polygon3D.New()
				poly:SetAABB(aabb)
				poly:SetName(path)
				poly.mesh = render3d.CreateMesh(
					vertices,
					primitive.indices.data,
					primitive.indices.component_type == "uint32_t" and "uint32_t" or "uint16_t",
					primitive.indices.count,
					true
				)
				poly.Skin = {BoneIndices = bone_indices, BoneWeights = bone_weights, Flexes = {}}
				local material = materials[primitive.material]

				if not material then
					local info = data.materials[primitive.material + 1]
					local pbr = info.pbr_metallic_roughness
					local color = pbr.base_color_factor or {1, 1, 1, 1}
					material = Material.New{
						Name = info.name,
						DoubleSided = info.double_sided,
						ColorMultiplier = Color(color[1], color[2], color[3], color[4] or 1),
						MetallicMultiplier = pbr.metallic_factor or 1,
						RoughnessMultiplier = pbr.roughness_factor or 1,
					}
					materials[primitive.material] = material
				end

				mesh_callback(poly, material)
			end
		end
	end
end

model_loader.AddModelDecoder("glb", decode)
model_loader.AddModelDecoder("gltf", decode)
return gltf_decoder
