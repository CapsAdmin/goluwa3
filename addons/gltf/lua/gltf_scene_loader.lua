local ffi = require("ffi")
local gltf = import("goluwa/codecs/gltf.lua")
local tasks = import("goluwa/tasks.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Color = import("goluwa/structs/color.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Entity = import("goluwa/entities/entity.lua")
local gltf_scene_loader = {}

-- Decompose a general affine matrix (glTF node.matrix, may carry non-uniform scale and mirroring)
-- into position/rotation/scale, using the same row-as-local-axis convention as Matrix44:GetRotation/SetRotation
local function decompose_node_matrix(m)
	local sx = math.sqrt(m.m00 * m.m00 + m.m01 * m.m01 + m.m02 * m.m02)
	local sy = math.sqrt(m.m10 * m.m10 + m.m11 * m.m11 + m.m12 * m.m12)
	local sz = math.sqrt(m.m20 * m.m20 + m.m21 * m.m21 + m.m22 * m.m22)
	local det = m.m00 * (
			m.m11 * m.m22 - m.m12 * m.m21
		) - m.m01 * (
			m.m10 * m.m22 - m.m12 * m.m20
		) + m.m02 * (
			m.m10 * m.m21 - m.m11 * m.m20
		)

	if det < 0 then sz = -sz end

	local r00, r01, r02 = m.m00 / sx, m.m01 / sx, m.m02 / sx
	local r10, r11, r12 = m.m10 / sy, m.m11 / sy, m.m12 / sy
	local r20, r21, r22 = m.m20 / sz, m.m21 / sz, m.m22 / sz
	local trace = r00 + r11 + r22
	local x, y, z, w

	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		w = 0.25 * s
		x = (r12 - r21) / s
		y = (r20 - r02) / s
		z = (r01 - r10) / s
	elseif r00 > r11 and r00 > r22 then
		local s = math.sqrt(1 + r00 - r11 - r22) * 2
		w = (r12 - r21) / s
		x = 0.25 * s
		y = (r01 + r10) / s
		z = (r02 + r20) / s
	elseif r11 > r22 then
		local s = math.sqrt(1 + r11 - r00 - r22) * 2
		w = (r20 - r02) / s
		x = (r01 + r10) / s
		y = 0.25 * s
		z = (r12 + r21) / s
	else
		local s = math.sqrt(1 + r22 - r00 - r11) * 2
		w = (r01 - r10) / s
		x = (r02 + r20) / s
		y = (r12 + r21) / s
		z = 0.25 * s
	end

	return Vec3(m.m30, m.m31, m.m32), Quat(x, y, z, w), Vec3(sx, sy, sz)
end

local function set_node_transform(transform, node)
	if node.matrix then
		local m = Matrix44()
		m.m00, m.m01, m.m02, m.m03 = node.matrix[1], node.matrix[2], node.matrix[3], node.matrix[4]
		m.m10, m.m11, m.m12, m.m13 = node.matrix[5], node.matrix[6], node.matrix[7], node.matrix[8]
		m.m20, m.m21, m.m22, m.m23 = node.matrix[9], node.matrix[10], node.matrix[11], node.matrix[12]
		m.m30, m.m31, m.m32, m.m33 = node.matrix[13], node.matrix[14], node.matrix[15], node.matrix[16]
		local position, rotation, scale = decompose_node_matrix(m)
		transform:SetPosition(position)
		transform:SetRotation(rotation)
		transform:SetScale(scale)
	else
		local t, r, s = node.translation, node.rotation, node.scale
		transform:SetPosition(Vec3(t[1], t[2], t[3]))
		transform:SetRotation(Quat(r[1], r[2], r[3], r[4]))
		transform:SetScale(Vec3(s[1], s[2], s[3]))
	end
end

-- Interleave a primitive's raw glTF accessor data into the engine's mesh vertex layout
-- (position3 + normal3 + uv2 + tangent4 + texture_blend1 + vertex_color4), and its AABB
local function build_vertex_data(primitive)
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
			-- glTF UV origin is top-left (V=0 at top); this engine's image decoders
			-- (png.lua/jpg.lua) flip pixel rows on load so V=0 is at the bottom for Vulkan,
			-- so glTF-authored V coordinates have to be flipped to land on the right texel
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

-- These textures are UV-atlas bakes (one custom unwrap per mesh, packing unrelated parts of the
-- model close together in texture space, e.g. the zeppelin's tail fins sit right next to its
-- balloon body) rather than simple tileable materials. Mip generation is a naive box filter with
-- no padding between UV islands, so deep mips blend those unrelated regions into each other and
-- look like the texture is smeared/wrongly oriented once a coarse mip gets picked. Capping how far
-- the sampler is allowed to go avoids the worst of that bleeding.
local MAX_SAMPLED_MIP_LOD = 4

local function translate_gltf_sampler(sampler_info)
	local min_filter = "linear"
	local mag_filter = "linear"
	local wrap_s = "repeat"
	local wrap_t = "repeat"

	if sampler_info then
		-- 9728 = NEAREST, 9984/9986 = *_MIPMAP_NEAREST
		if
			sampler_info.minFilter == 9728 or
			sampler_info.minFilter == 9984 or
			sampler_info.minFilter == 9986
		then
			min_filter = "nearest"
		end

		if sampler_info.magFilter == 9728 then mag_filter = "nearest" end

		-- 33071 = CLAMP_TO_EDGE, 33648 = MIRRORED_REPEAT
		if sampler_info.wrapS == 33071 then
			wrap_s = "clamp_to_edge"
		elseif sampler_info.wrapS == 33648 then
			wrap_s = "mirrored_repeat"
		end

		if sampler_info.wrapT == 33071 then
			wrap_t = "clamp_to_edge"
		elseif sampler_info.wrapT == 33648 then
			wrap_t = "mirrored_repeat"
		end
	end

	return {
		min_filter = min_filter,
		mag_filter = mag_filter,
		wrap_s = wrap_s,
		wrap_t = wrap_t,
		mipmap_mode = "linear",
		max_lod = MAX_SAMPLED_MIP_LOD,
	}
end

local function load_texture(gltf_data, texture_ref, srgb)
	if not texture_ref then return nil end

	local texture_info = gltf_data.textures[texture_ref.index + 1]

	if not texture_info then
		print("WARNING: invalid glTF texture index:", texture_ref.index)
		return Texture.GetFallback()
	end

	local image_info = gltf_data.images[texture_info.source + 1]

	if not image_info or not image_info.path then
		print("WARNING: invalid glTF image source:", texture_info.source)
		return Texture.GetFallback()
	end

	local sampler_info = texture_info.sampler and
		gltf_data.raw.samplers and
		gltf_data.raw.samplers[texture_info.sampler + 1]
	local texture = Texture.New{
		path = image_info.path,
		cache_key = gltf_data.path .. ":" .. texture_ref.index,
		format = not image_info.path:ends_with(".dds") and "r8g8b8a8_unorm" or nil,
		srgb = srgb,
		mip_map_levels = "auto",
		sampler = translate_gltf_sampler(sampler_info),
	}
	-- Decoding/uploading a texture is expensive (synchronous PNG decode); yield so frames
	-- keep presenting between textures instead of stalling the renderer for the whole scene load
	tasks.Wait()
	return texture
end

local spec_gloss_push_constant_t = ffi.typeof("int[1]")

-- KHR_materials_pbrSpecularGlossiness packs specular color in RGB and glossiness in A, a
-- completely different layout than a metallic-roughness texture (roughness in G, metallic in B),
-- so it has to be converted per-pixel on the GPU rather than reused as-is
local function shade_spec_gloss_to_metallic_roughness(metallic_roughness_texture, spec_gloss_texture)
	metallic_roughness_texture:Shade(
		[[
			vec4 spec_gloss_sample = texture(TEXTURE(spec_gloss.source_tex), uv);
			float roughness = clamp(1.0 - spec_gloss_sample.a, 0.0, 1.0);
			float max_c = max(spec_gloss_sample.r, max(spec_gloss_sample.g, spec_gloss_sample.b));
			float min_c = min(spec_gloss_sample.r, min(spec_gloss_sample.g, spec_gloss_sample.b));
			float saturation = max_c > 0.0 ? (max_c - min_c) / max_c : 0.0;
			float metallic = saturation > 0.1 ? max_c : 0.0;
			return vec4(0.0, roughness, metallic, 1.0);
		]],
		{
			textures = {spec_gloss_texture},
			custom_declarations = [[
				layout(push_constant, scalar) uniform SpecGlossPush {
					int source_tex;
				} spec_gloss;
			]],
			fragment_push_constants = {
				size = ffi.sizeof(spec_gloss_push_constant_t),
				get_data = function(_, _, pipeline)
					return spec_gloss_push_constant_t(pipeline:GetTextureIndex(spec_gloss_texture))
				end,
			},
		}
	)
end

local function build_metallic_roughness_from_spec_gloss(gltf_data, texture_ref)
	local spec_gloss_texture = load_texture(gltf_data, texture_ref)

	if not spec_gloss_texture or type(spec_gloss_texture.Shade) ~= "function" then
		return nil
	end

	local metallic_roughness_texture = Texture.New{
		width = spec_gloss_texture:GetWidth(),
		height = spec_gloss_texture:GetHeight(),
		format = "r8g8b8a8_unorm",
		mip_map_levels = spec_gloss_texture:GetMipMapLevels() > 1 and "auto" or 1,
		image = {usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"}},
	}
	shade_spec_gloss_to_metallic_roughness(metallic_roughness_texture, spec_gloss_texture)
	return metallic_roughness_texture
end

local function build_material(gltf_data, material_index)
	local info = gltf_data.materials[material_index + 1]
	local config = {
		Name = info.name,
		DoubleSided = info.double_sided,
		AlphaMode = info.alpha_mode,
		AlphaCutoff = info.alpha_cutoff,
	}
	local spec_gloss = info.pbr_specular_glossiness
	local pbr = info.pbr_metallic_roughness

	if spec_gloss then
		local diffuse = spec_gloss.diffuse_factor or {1, 1, 1, 1}
		config.ColorMultiplier = Color(diffuse[1], diffuse[2], diffuse[3], diffuse[4] or 1)
		config.AlbedoTexture = load_texture(gltf_data, spec_gloss.diffuse_texture, true)

		if spec_gloss.specular_glossiness_texture then
			config.MetallicRoughnessTexture = build_metallic_roughness_from_spec_gloss(gltf_data, spec_gloss.specular_glossiness_texture)
		end

		if config.MetallicRoughnessTexture then
			-- The texture already carries the converted per-pixel roughness/metallic; the
			-- multipliers below are applied on top of it by the shader, so keep them neutral
			config.RoughnessMultiplier = 1
			config.MetallicMultiplier = 1
		else
			config.RoughnessMultiplier = 1 - (spec_gloss.glossiness_factor or 1)
			-- Specular-glossiness has no metalness factor of its own: a grey/white specular
			-- color (any brightness) is a dielectric (e.g. wet ground), only a *tinted*
			-- specular color indicates metal, so metallic is derived from how far the
			-- specular color is from grey
			local specular = spec_gloss.specular_factor or {0, 0, 0}
			local max_c = math.max(specular[1], specular[2], specular[3])
			local min_c = math.min(specular[1], specular[2], specular[3])
			local saturation = max_c > 0 and (max_c - min_c) / max_c or 0
			config.MetallicMultiplier = saturation > 0.1 and max_c or 0
		end
	elseif pbr then
		local base_color = pbr.base_color_factor or {1, 1, 1, 1}
		config.ColorMultiplier = Color(base_color[1], base_color[2], base_color[3], base_color[4] or 1)
		config.MetallicMultiplier = pbr.metallic_factor or 1
		config.RoughnessMultiplier = pbr.roughness_factor or 1
		config.AlbedoTexture = load_texture(gltf_data, pbr.base_color_texture, true)
		config.MetallicRoughnessTexture = load_texture(gltf_data, pbr.metallic_roughness_texture)
	else
		config.ColorMultiplier = Color(1, 1, 1, 1)
		config.MetallicMultiplier = 0
		config.RoughnessMultiplier = 0.5
	end

	if info.normal_texture then
		config.NormalTexture = load_texture(gltf_data, info.normal_texture)
		config.NormalMapMultiplier = info.normal_texture.scale or 1
	end

	if info.occlusion_texture then
		config.AmbientOcclusionTexture = load_texture(gltf_data, info.occlusion_texture)
		config.AmbientOcclusionMultiplier = info.occlusion_texture.strength or 1
	end

	if info.emissive_texture then
		config.EmissiveTexture = load_texture(gltf_data, info.emissive_texture, true)
	end

	local emissive = info.emissive_factor or {0, 0, 0}
	config.EmissiveMultiplier = Color(emissive[1], emissive[2], emissive[3], 1)
	return Material.New(config)
end

-- Build (and cache) the GPU primitives for one glTF mesh: {polygon3d, material} per primitive
local function build_mesh_primitives(gltf_data, mesh, materials)
	local primitives = {}

	for i, primitive in ipairs(mesh.primitives) do
		if primitive.mode ~= "triangles" then
			print("WARNING: skipping non-triangle glTF primitive mode:", primitive.mode)

			goto continue
		end

		local vertices, vertex_count, aabb = build_vertex_data(primitive)

		if not vertices then
			print(
				"WARNING: failed to build vertex data for mesh",
				mesh.name,
				"primitive",
				i,
				":",
				vertex_count
			)

			goto continue
		end

		local index_data, index_count, index_type

		if primitive.indices then
			index_data = primitive.indices.data
			index_count = primitive.indices.count
			index_type = primitive.indices.component_type == "uint32_t" and "uint32_t" or "uint16_t"
		end

		local poly = Polygon3D.New()
		poly:SetAABB(aabb)
		poly.mesh = render3d.CreateMesh(vertices, index_data, index_type, index_count, true)
		local material

		if primitive.material then
			material = materials[primitive.material + 1]

			if not material then
				material = build_material(gltf_data, primitive.material)
				materials[primitive.material + 1] = material
			end
		end

		primitives[#primitives + 1] = {polygon3d = poly, material = material}

		::continue::
	end

	return primitives
end

-- Spawn one child entity per instance of an EXT_mesh_gpu_instancing node, each with its own
-- transform but sharing the same (cached) polygon3d/material objects as every other instance -
-- render3d's automatic instanced-draw batching (keyed on mesh GPU buffer + material) then merges
-- them back into a single draw call, the same way repeated bsp/mdl prop placements do
local function spawn_gpu_instanced_primitives(node_entity, node, primitives, mesh_name)
	local instancing = node.gpu_instancing
	local count = (
			instancing.translation and
			instancing.translation.count
		)
		or
		(
			instancing.rotation and
			instancing.rotation.count
		)
		or
		(
			instancing.scale and
			instancing.scale.count
		)
		or
		0

	for i = 0, count - 1 do
		local instance_entity = Entity.New{Name = mesh_name .. "_instance_" .. i, Parent = node_entity}
		local transform = instance_entity:AddComponent("transform")

		if instancing.translation then
			local d = instancing.translation.data
			transform:SetPosition(Vec3(d[i * 3 + 0], d[i * 3 + 1], d[i * 3 + 2]))
		end

		if instancing.rotation then
			local d = instancing.rotation.data
			transform:SetRotation(Quat(d[i * 4 + 0], d[i * 4 + 1], d[i * 4 + 2], d[i * 4 + 3]))
		end

		if instancing.scale then
			local d = instancing.scale.data
			transform:SetScale(Vec3(d[i * 3 + 0], d[i * 3 + 1], d[i * 3 + 2]))
		end

		local visual = instance_entity:AddComponent("visual")

		for prim_index, primitive in ipairs(primitives) do
			visual:CreatePrimitiveEntity(
				primitive.polygon3d,
				primitive.material,
				mesh_name .. "_instance_" .. i .. "_" .. prim_index
			)
		end

		-- Scatter/foliage instancing can run into the thousands; yield periodically so this
		-- doesn't stall frame presentation for the whole node
		if i % 256 == 255 then tasks.Wait() end
	end
end

-- Create one entity per glTF node (with its local transform) and wire up parenting
local function create_node_entities(gltf_data)
	local node_to_entity = {}

	for node_index, node in ipairs(gltf_data.nodes) do
		local entity = Entity.New{Name = node.name or ("node_" .. node_index)}
		set_node_transform(entity:AddComponent("transform"), node)
		node_to_entity[node_index] = entity
	end

	for node_index, node in ipairs(gltf_data.nodes) do
		if node.children then
			local entity = node_to_entity[node_index]

			for _, child_index in ipairs(node.children) do
				node_to_entity[child_index + 1]:SetParent(entity)
			end
		end
	end

	return node_to_entity
end

-- Collect the given node indices (0-based) plus everything reachable through node.children
local function collect_reachable_nodes(gltf_data, root_node_indices)
	local reachable = {}

	local function mark(node_index)
		if reachable[node_index] then return end

		reachable[node_index] = true
		local node = gltf_data.nodes[node_index + 1]

		if node.children then
			for _, child_index in ipairs(node.children) do
				mark(child_index)
			end
		end
	end

	for _, node_index in ipairs(root_node_indices) do
		mark(node_index)
	end

	return reachable
end

-- Decoded glTF data plus built GPU primitives, cached per path (like model_loader.model_cache)
-- so placing the same file at many transforms - the gltf equivalent of a bsp map spawning the
-- same .mdl prop many times - only decodes/builds meshes, materials and textures once. Every
-- Load() call still gets its own fresh entity hierarchy; only the expensive GPU-facing objects
-- (polygon3d, material) are shared. mesh_primitives itself only catches nodes that reference the
-- same glTF mesh index; content that's merely byte-identical across different mesh indices (e.g.
-- trees.gltf: 2712 mesh entries, 8 unique shapes) is instead deduplicated by render3d.CreateMesh's
-- own content-addressed Mesh cache (see render3d.CreateMesh(..., true) below) - deliberately not
-- duplicated here too, so there is one mesh-dedup mechanism in the engine, not two.
gltf_scene_loader.build_cache = gltf_scene_loader.build_cache or {}

-- Load a glTF file and translate it into an engine entity hierarchy under a new root entity.
-- options.only_node_name restricts mesh/material building to the subtree of the (first) node
-- with that name - the full node hierarchy above it (with its transforms, e.g. any axis-
-- conversion baked into the scene root) is still created and parented normally, only the
-- expensive part (building GPU meshes and loading textures) is skipped outside that subtree.
-- Useful for testing a single mesh without paying for the whole scene's texture load.
-- Returns root_entity, gltf_data (the raw decoded glTF, useful for stats/debugging)
function gltf_scene_loader.Load(path, options)
	options = options or {}
	local cached = gltf_scene_loader.build_cache[path]
	local gltf_data, materials, mesh_primitives

	if cached then
		gltf_data, materials, mesh_primitives = cached.gltf_data, cached.materials, cached.mesh_primitives
	else
		local err
		gltf_data, err = gltf.Load(path)

		if not gltf_data then return nil, err end

		materials, mesh_primitives = {}, {}
		gltf_scene_loader.build_cache[path] = {
			gltf_data = gltf_data,
			materials = materials,
			mesh_primitives = mesh_primitives,
		}
	end

	local scene = gltf_data.scenes[gltf_data.scene + 1]
	local root_node_indices = scene and scene.nodes or {}
	local reachable

	if options.only_node_name then
		local only_node_indices = {}

		for node_index, node in ipairs(gltf_data.nodes) do
			if node.name == options.only_node_name then
				only_node_indices[#only_node_indices + 1] = node_index - 1
			end
		end

		if not only_node_indices[1] then
			return nil, "no node named " .. options.only_node_name
		end

		reachable = collect_reachable_nodes(gltf_data, only_node_indices)
	else
		reachable = collect_reachable_nodes(gltf_data, root_node_indices)
	end

	local node_to_entity = create_node_entities(gltf_data)

	for node_index, node in ipairs(gltf_data.nodes) do
		if node.mesh ~= nil and reachable[node_index - 1] then
			local mesh_index = node.mesh + 1
			local mesh = gltf_data.meshes[mesh_index]
			local primitives = mesh_primitives[mesh_index]

			if not primitives then
				primitives = build_mesh_primitives(gltf_data, mesh, materials)
				mesh_primitives[mesh_index] = primitives
				tasks.Wait()
			end

			local entity = node_to_entity[node_index]

			if node.gpu_instancing then
				spawn_gpu_instanced_primitives(entity, node, primitives, mesh.name or "mesh")
			else
				local visual = entity:AddComponent("visual")

				for prim_index, primitive in ipairs(primitives) do
					visual:CreatePrimitiveEntity(
						primitive.polygon3d,
						primitive.material,
						(mesh.name or "mesh") .. "_" .. prim_index
					)
				end
			end
		end
	end

	local root_entity = Entity.New{Name = options.name or path, Parent = options.parent}
	root_entity:AddComponent("transform")

	for _, root_node_index in ipairs(root_node_indices) do
		node_to_entity[root_node_index + 1]:SetParent(root_entity)
	end

	return root_entity, gltf_data
end

return gltf_scene_loader
