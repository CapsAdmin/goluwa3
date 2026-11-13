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
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local fs = import("goluwa/filesystem/fs.lua")
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
			vertex.uv[0], vertex.uv[1] = texcoord.data[i * 2 + 0], texcoord.data[i * 2 + 1]
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

local function extract_texture(data, texture_index)
	local source = data.textures[texture_index + 1].source
	local image = data.images[source + 1]

	if image.path then return image.path end

	local view = data.raw.bufferViews[image.buffer_view + 1]
	local extension = image.mime_type == "image/png" and ".png" or ".jpg"
	local path = string.format(
		"storage/cache/glb_%s_%d_%d%s",
		(data.path:match("([^/]+)$") or "model"):gsub("[^%w]", "_"),
		source,
		view.byteLength,
		extension
	)

	if not fs.exists(path) then
		assert(fs.create_directory_recursive("storage/cache/"))
		local buffer = data.buffers[view.buffer + 1]
		assert(fs.write_file(path, ffi.string(buffer + (view.byteOffset or 0), view.byteLength)))
	end

	return path
end

local function node_matrix(node)
	if node.matrix then return node.matrix end

	local x, y, z, w = node.rotation[1], node.rotation[2], node.rotation[3], node.rotation[4]
	local sx, sy, sz = node.scale[1], node.scale[2], node.scale[3]
	local xx, yy, zz, xy, xz, yz, wx, wy, wz = x * x, y * y, z * z, x * y, x * z, y * z, w * x, w * y, w * z
	return {
		(
			1 - 2 * (
				yy + zz
			)
		) * sx,
		2 * (
			xy + wz
		) * sx,
		2 * (
			xz - wy
		) * sx,
		0,
		2 * (
			xy - wz
		) * sy,
		(
			1 - 2 * (
				xx + zz
			)
		) * sy,
		2 * (
			yz + wx
		) * sy,
		0,
		2 * (
			xz + wy
		) * sz,
		2 * (
			yz - wx
		) * sz,
		(
			1 - 2 * (
				xx + yy
			)
		) * sz,
		0,
		node.translation[1],
		node.translation[2],
		node.translation[3],
		1,
	}
end

local function multiply_matrices(a, b)
	local out = {}

	for column = 0, 3 do
		for row = 0, 3 do
			local sum = 0

			for k = 0, 3 do
				sum = sum + a[k * 4 + row + 1] * b[column * 4 + k + 1]
			end

			out[column * 4 + row + 1] = sum
		end
	end

	return out
end

local IDENTITY = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

local function decode_static(path, data, mesh_callback)
	local materials = {}

	local function build_material(primitive)
		local info = data.materials[primitive.material + 1]
		local pbr = info.pbr_metallic_roughness
		local color = pbr.base_color_factor or {1, 1, 1, 1}
		local material = Material.New{
			Name = info.name,
			DoubleSided = info.double_sided,
			ColorMultiplier = Color(color[1], color[2], color[3], color[4] or 1),
			MetallicMultiplier = pbr.metallic_factor or 1,
			RoughnessMultiplier = pbr.roughness_factor or 1,
		}

		if pbr.base_color_texture then
			material:SetAlbedoTexture(Material.SRGBTexture(extract_texture(data, pbr.base_color_texture.index)))
		end

		if info.normal_texture then
			material:SetNormalTexture(Material.LinearTexture(extract_texture(data, info.normal_texture.index)))
		end

		return material
	end

	local function emit_primitive(primitive, m)
		local vertices, vertex_count = assert(gltf_decoder.BuildVertices(primitive))
		local index_count = primitive.indices.count
		local indices = ffi.new("uint32_t[?]", index_count)
		local det = m[1] * (
				m[6] * m[11] - m[7] * m[10]
			) - m[5] * (
				m[2] * m[11] - m[3] * m[10]
			) + m[9] * (
				m[2] * m[7] - m[3] * m[6]
			)

		for i = 0, index_count - 3, 3 do
			local a, b, c = primitive.indices.data[i], primitive.indices.data[i + 1], primitive.indices.data[i + 2]

			if det < 0 then
				indices[i], indices[i + 1], indices[i + 2] = a, b, c
			else
				indices[i], indices[i + 1], indices[i + 2] = a, c, b
			end
		end

		local min_x, min_y, min_z = math.huge, math.huge, math.huge
		local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

		for i = 0, vertex_count - 1 do
			local position, normal = vertices[i].position, vertices[i].normal
			local px, py, pz = position[0], position[1], position[2]
			local nx, ny, nz = normal[0], normal[1], normal[2]
			px, py, pz = m[1] * px + m[5] * py + m[9] * pz + m[13],
			m[2] * px + m[6] * py + m[10] * pz + m[14],
			m[3] * px + m[7] * py + m[11] * pz + m[15]
			nx, ny, nz = m[1] * nx + m[5] * ny + m[9] * nz,
			m[2] * nx + m[6] * ny + m[10] * nz,
			m[3] * nx + m[7] * ny + m[11] * nz
			local length = math.sqrt(nx * nx + ny * ny + nz * nz)

			if length > 0 then nx, ny, nz = nx / length, ny / length, nz / length end

			position[0], position[1], position[2] = px, py, pz
			normal[0], normal[1], normal[2] = nx, ny, nz
			min_x, min_y, min_z = math.min(min_x, px), math.min(min_y, py), math.min(min_z, pz)
			max_x, max_y, max_z = math.max(max_x, px), math.max(max_y, py), math.max(max_z, pz)
		end

		if not primitive.attributes.NORMAL then
			local normals = ffi.new("double[?]", vertex_count * 3)

			for i = 0, index_count - 3, 3 do
				local a, b, c = vertices[indices[i]].position, vertices[indices[i + 1]].position, vertices[indices[i + 2]].position
				local ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
				local vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
				local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx

				for k = 0, 2 do
					local v = indices[i + k] * 3
					normals[v], normals[v + 1], normals[v + 2] = normals[v] - nx, normals[v + 1] - ny, normals[v + 2] - nz
				end
			end

			for i = 0, vertex_count - 1 do
				local nx, ny, nz = normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]
				local length = math.sqrt(nx * nx + ny * ny + nz * nz)

				if length > 0 then
					nx, ny, nz = nx / length, ny / length, nz / length
				else
					nx, ny, nz = 0, 1, 0
				end

				vertices[i].normal[0], vertices[i].normal[1], vertices[i].normal[2] = nx, ny, nz
			end
		end

		if not primitive.attributes.TANGENT then
			vertex_math.BuildTangents(vertices, vertex_count, indices, index_count)
		end

		local poly = Polygon3D.New()
		poly:SetAABB(AABB(min_x, min_y, min_z, max_x, max_y, max_z))
		poly:SetName(path)
		poly.mesh = render3d.CreateMesh(vertices, indices, "uint32_t", index_count, true)

		if not materials[primitive.material] then
			materials[primitive.material] = build_material(primitive)
		end

		mesh_callback(poly, materials[primitive.material])
	end

	local function visit(index, parent)
		local node = data.nodes[index + 1]
		local m = multiply_matrices(parent, node_matrix(node))

		if node.mesh then
			for _, primitive in ipairs(data.meshes[node.mesh + 1].primitives) do
				emit_primitive(primitive, m)
			end
		end

		for _, child in ipairs(node.children or {}) do
			visit(child, m)
		end
	end

	for _, root in ipairs(data.scenes[data.scene + 1].nodes) do
		visit(root, IDENTITY)
	end
end

local function decode(path, full_path, mesh_callback, physics_callback, skeleton_callback)
	local data = assert(gltf.Load(full_path))

	if not data.skins[1] then return decode_static(path, data, mesh_callback) end

	local skin = data.skins[1]
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
