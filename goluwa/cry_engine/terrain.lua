local mtl_material = import("goluwa/cry_engine/mtl_material.lua")
local Color = import("goluwa/structs/color.lua")
local Texture = import("goluwa/render/texture.lua")
local ffi = require("ffi")
local terrain = {}

local function get_or_create_cry_height_texture(terrain)
	if terrain.height_texture and terrain.height_texture:IsValid() then
		return terrain.height_texture
	end

	terrain.height_texture = Texture.New{
		width = terrain.height_sample_width,
		height = terrain.height_sample_height,
		format = "r16_unorm",
		buffer = terrain.height_samples or terrain.height_data,
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	return terrain.height_texture
end

local get_or_create_cry_albedo_texture

do
	local AtlasNodeConstants = ffi.typeof("struct { int source; int x; int y; int span; }")
	local ATLAS_NODE_DECLARATIONS = [[
		layout(push_constant, scalar) uniform CryAtlasNode {
			int source;
			int x;
			int y;
			int span;
		} atlas_node;
	]]
	local ATLAS_NODE_GLSL = [[
		vec2 cell = uv * float(atlas_node.span) - vec2(atlas_node.x, atlas_node.y);

		if (any(lessThan(cell, vec2(0.0))) || any(greaterThanEqual(cell, vec2(1.0)))) discard;

		// cry's tex2DTerrain: red and green are the color's share of r + g + b, blue is its brightness.
		// the red tweak compensates for 565 red only reaching 30/31 for a perfect gray
		vec4 texel = texture(TEXTURE(atlas_node.source), cell);
		float red = (texel.r + 0.001012) * (31.0 / 30.0);
		vec3 color = vec3(red, texel.g, 1.0 - red - texel.g) * 3.0 * texel.b;
		// opinionated for goluwa
		color = pow(color, vec3(1.5)) * 0.5;
		return vec4(color, 1.0);
	]]
	local LINEAR_CLAMP = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "clamp_to_edge",
		wrap_t = "clamp_to_edge",
	}

	function get_or_create_cry_albedo_texture(terrain)
		if terrain.albedo_texture and terrain.albedo_texture:IsValid() then
			return terrain.albedo_texture
		end

		local cover = terrain.cover
		local sector_size = cover.sector_size
		local data = ffi.cast("const uint8_t *", cover.data)
		local atlas = Texture.New{
			width = sector_size * 2 ^ cover.max_level,
			height = sector_size * 2 ^ cover.max_level,
			format = "r8g8b8a8_srgb",
			mip_map_levels = 1,
			image = {
				usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			sampler = LINEAR_CLAMP,
		}

		for i, node in ipairs(cover.nodes) do
			local source = Texture.New{
				decoded = {
					width = sector_size,
					height = sector_size,
					vulkan_format = "bc3_unorm_block",
					is_compressed = true,
					mip_count = 1,
					mip_info = {
						{
							width = sector_size,
							height = sector_size,
							depth = 1,
							size = cover.sector_bytes,
							offset = 0,
						},
					},
					data_size = cover.sector_bytes,
					data = data + node.offset,
				},
				mip_map_levels = 1,
				sampler = LINEAR_CLAMP,
			}
			local constants = AtlasNodeConstants(0, node.x, node.y, 2 ^ node.level)
			atlas:Shade(
				ATLAS_NODE_GLSL,
				{
					textures = {source},
					load_op = i == 1 and "clear" or "load",
					custom_declarations = ATLAS_NODE_DECLARATIONS,
					fragment_push_constants = {
						size = ffi.sizeof(AtlasNodeConstants),
						get_data = function(_, _, pipeline)
							constants.source = pipeline:GetTextureIndex(source)
							return constants
						end,
					},
				}
			)
			source:Remove()
		end

		terrain.albedo_texture = atlas
		return atlas
	end
end

local function get_or_create_cry_surface_index_texture(terrain)
	if terrain.surface_index_texture and terrain.surface_index_texture:IsValid() then
		return terrain.surface_index_texture
	end

	terrain.surface_index_texture = Texture.New{
		width = terrain.surface_slot_width,
		height = terrain.surface_slot_height,
		format = "r8_unorm",
		buffer = terrain.surface_indices,
		mip_map_levels = 1,
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	return terrain.surface_index_texture
end

local function get_or_create_cry_terrain_layers(terrain)
	if terrain.detail_layers then return terrain.detail_layers end

	local Material = import("goluwa/render3d/material.lua")
	local layers = {}

	for i, surface_type in ipairs(terrain.surface_types) do
		if surface_type.detail_material_path then
			local material = mtl_material.FromCryMTL(surface_type.detail_material_path)

			if not (material.cry_texture_maps and material.cry_texture_maps.Diffuse) then
				material = mtl_material.FromCryMTL(surface_type.detail_material_path, "z")
			end

			local diffuse = material.cry_texture_maps and material.cry_texture_maps.Diffuse

			if diffuse then
				layers[i] = {
					albedo = diffuse.resolved and
						Texture.New{path = diffuse.resolved, srgb = false} or
						material:GetAlbedoTexture(),
					normal = material:GetNormalTexture(),
					height = material:HasHeightMap() and material:GetHeightTexture() or nil,
					height_scale = material:GetHeightScale(),
					scale = 1 / (surface_type.detail_scale_x * diffuse.tile_u),
					detail = tonumber(material.cry_public_params.DetailTextureStrength) or 1,
					additive_detail = material:GetColorMultiplier():GetLuminance(),
					specular = material:GetSpecularMultiplier(),
					grass = 0,
					roughness = 1,
					ao = 1,
				}
			else
				wlog(
					"cry terrain detail material %s has no diffuse texture",
					surface_type.detail_material_path
				)
			end
		end
	end

	terrain.detail_layers = layers
	return layers
end

local guess_cry_surface_color
guess_cry_surface_color = function(surface_type)
	local key = (
			(
				surface_type and
				surface_type.name
			)
			or
			""
		) .. " " .. (
			(
				surface_type and
				surface_type.detail_material
			)
			or
			""
		)
	key = key:lower()

	if
		key:find("grass", 1, true) or
		key:find("fern", 1, true) or
		key:find("leaf", 1, true)
	then
		return Color(0.28, 0.40, 0.18, 1)
	end

	if key:find("sand", 1, true) or key:find("beach", 1, true) then
		return Color(0.72, 0.66, 0.46, 1)
	end

	if
		key:find("cliff", 1, true) or
		key:find("rock", 1, true) or
		key:find("stone", 1, true) or
		key:find("pep", 1, true)
	then
		return Color(0.47, 0.45, 0.42, 1)
	end

	if
		key:find("road", 1, true) or
		key:find("asphalt", 1, true) or
		key:find("con", 1, true)
	then
		return Color(0.36, 0.35, 0.33, 1)
	end

	if
		key:find("soil", 1, true) or
		key:find("earth", 1, true) or
		key:find("ground", 1, true) or
		key:find("mud", 1, true)
	then
		return Color(0.41, 0.31, 0.21, 1)
	end

	if
		key:find("river", 1, true) or
		key:find("wet", 1, true) or
		key:find("underwater", 1, true)
	then
		return Color(0.30, 0.34, 0.30, 1)
	end

	return Color(0.5, 0.48, 0.43, 1)
end

local function build_cry_terrain_source(terrain)
	local ShaderSource = import("goluwa/terrain/shader_source.lua")
	local world_size = math.max(terrain.world_size or 0, 1)
	local has_layers = terrain.surface_indices ~= nil
	local detail_layers = has_layers and get_or_create_cry_terrain_layers(terrain) or nil
	local surface_indices = terrain.surface_indices
	local index_width = terrain.surface_slot_width
	local index_height = terrain.surface_slot_height
	local cells_per_meter_x = has_layers and index_width / world_size or 0
	local cells_per_meter_y = has_layers and index_height / world_size or 0
	return ShaderSource.New{
		Textures = {
			get_or_create_cry_height_texture(terrain),
			get_or_create_cry_albedo_texture(terrain),
			has_layers and get_or_create_cry_surface_index_texture(terrain) or nil,
		},
		HeightGLSL = string.format(
			[[
			vec2 cry_terrain_uv(vec2 world) {
				// texture columns run along cry +y (engine -z), rows along cry +x (engine +x)
				return clamp(vec2(-world.y / %.6f, world.x / %.6f), vec2(0.0), vec2(1.0));
			}

			float terrain_height(vec2 world) {
				return texture(TEXTURE(terrain_bake.texture0), cry_terrain_uv(world)).r * %.6f;
			}
		]],
			world_size,
			world_size,
			terrain.heightmap_max_height
		),
		SplatGLSL = has_layers and
			[[
			vec4 terrain_splat(vec2 world, float h, vec3 n) {
				ivec2 size = textureSize(TEXTURE(terrain_bake.texture2), 0);
				vec2 p = cry_terrain_uv(world) * vec2(size) - 0.5;
				ivec2 base = ivec2(floor(p));
				vec2 f = p - vec2(base);
				vec4 weights = vec4(0.0);

				for (int i = 0; i < 4; i++) {
					ivec2 offset = ivec2(i & 1, i >> 1);
					ivec2 cell = clamp(base + offset, ivec2(0), size - 1);
					int id = int(texelFetch(TEXTURE(terrain_bake.texture2), cell, 0).r * 255.0 + 0.5);
					float weight = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y);

					if (id == terrain_bake.layer1) {
						weights.y += weight;
					} else if (id == terrain_bake.layer2) {
						weights.z += weight;
					} else if (id == terrain_bake.layer3) {
						weights.w += weight;
					} else {
						weights.x += weight;
					}
				}

				return weights;
			}
		]] or
			nil,
		ColorGLSL = [[
			vec3 terrain_color(vec2 world, float h, vec3 n) {
				return texture(TEXTURE(terrain_bake.texture1), cry_terrain_uv(world)).rgb;
			}
		]],
		ColorFormat = "r8g8b8a8_srgb",
		SelectChunkLayers = has_layers and
			function(request)
				local first_row = math.clamp(math.floor(request.min_x * cells_per_meter_y), 0, index_height - 1)
				local last_row = math.clamp(math.ceil((request.min_x + request.size) * cells_per_meter_y), 0, index_height - 1)
				local first_column = math.clamp(math.floor(-(request.min_z + request.size) * cells_per_meter_x), 0, index_width - 1)
				local last_column = math.clamp(math.ceil(-request.min_z * cells_per_meter_x), 0, index_width - 1)
				local stride = math.max(math.floor(math.max(last_row - first_row, last_column - first_column) / 64), 1)
				local counts = {}
				local ids = {}

				for row = first_row, last_row, stride do
					for column = first_column, last_column, stride do
						local id = surface_indices[row * index_width + column]

						if id ~= 0 and detail_layers[id] then
							if not counts[id] then ids[#ids + 1] = id end

							counts[id] = (counts[id] or 0) + 1
						end
					end
				end

				table.sort(ids, function(a, b)
					return counts[a] > counts[b]
				end)

				local layers = {}

				for i = 5, #ids do
					ids[i] = nil
				end

				for i, id in ipairs(ids) do
					layers[i] = detail_layers[id]
				end

				return layers, ids
			end or
			nil,
		MinHeight = 0,
		MaxHeight = terrain.heightmap_max_height,
		Layers = {},
	}
end

function terrain.SpawnTerrain(level_data, parent)
	local terrain = level_data and level_data.terrain

	if not terrain or not terrain.height_data then return nil end

	local Terrain = import("goluwa/terrain/terrain.lua")
	local renderer = Terrain.New{
		Name = "cry_terrain",
		Source = build_cry_terrain_source(terrain),
		Levels = 6,
		BaseChunkSize = 64,
		Samples = 65,
		DetailSize = 256,
		ColorSize = 256,
		BuildsPerUpdate = 3,
		Physics = {
			chunk_size = 64,
			samples = 65,
			radius = 2,
		},
	}:Start()
	renderer.Root:SetName("cry_terrain")
	renderer.Root.spawned_from_cry_level = true
	parent:AddChild(renderer.Root)
	return renderer
end

function terrain.ApplyVegetationMaterialState(level_data)
	local Material = import("goluwa/render3d/material.lua")
	local terrain = level_data.terrain
	local prototypes = level_data.vegetation_prototypes

	if not prototypes then return end

	if terrain and terrain.cover then
		local texture = get_or_create_cry_albedo_texture(terrain)
		local uv = Color(0, -1 / terrain.world_size, 1 / terrain.world_size, 0)

		for _, prototype in ipairs(prototypes.list) do
			if prototype.use_terrain_color and prototype.material_path then
				for _, material in ipairs(mtl_material.FromCryMTLList(prototype.material_path)) do
					if material:GetGroundColorBlend() > 0 then
						material:SetGroundColorTexture(texture)
						material:SetGroundColorUV(uv)
					end
				end
			end
		end
	end

	for _, prototype in ipairs(prototypes.list) do
		for _, material_path in ipairs(prototype.material_paths) do
			for _, material in ipairs(mtl_material.FromCryMTLList(material_path)) do
				material:SetBending(prototype.bending)
			end
		end
	end
end

return terrain
