local mtl_material = import("goluwa/cry_engine/mtl_material.lua")
local Color = import("goluwa/structs/color.lua")
local Texture = import("goluwa/render/texture.lua")
local ffi = require("ffi")
local terrain = {}
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

		vec4 texel = texture(TEXTURE(atlas_node.source), cell);
		float red = (texel.r + 0.001012) * (31.0 / 30.0);
		vec3 color = vec3(red, texel.g, 1.0 - red - texel.g) * 3.0 * texel.b;
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
					scatter = 0,
					roughness = 1,
					surface = material:GetSurfaceType(),
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

-- the terrain of a level in the data of the engine's heightmap source (see
-- terrain/heightmap_source.lua): the cover sectors become the color map, the surface types the layers.
-- The world of cry has x and z swapped and mirrored in the map, hence the uv.
function terrain.Translate(level_data)
	local terrain = level_data.terrain
	local has_layers = terrain.surface_indices ~= nil
	return {
		size = math.max(terrain.world_size or 0, 1),
		origin = {0, 0},
		uv = {0, -1, 1, 0},
		outside = "zero",
		max_height = terrain.heightmap_max_height,
		height = {
			width = terrain.height_sample_width,
			height = terrain.height_sample_height,
			samples = assert(terrain.height_samples),
		},
		color = get_or_create_cry_albedo_texture(terrain),
		indices = has_layers and
			{
				width = terrain.surface_slot_width,
				height = terrain.surface_slot_height,
				samples = terrain.surface_indices,
			} or
			nil,
		layers = has_layers and get_or_create_cry_terrain_layers(terrain) or nil,
	}
end

-- adds a terrain component with the level's terrain to parent
function terrain.SpawnTerrain(level_data, parent)
	local source = level_data and level_data.terrain

	if not source or not source.height_data then return nil end

	parent:AddComponent("terrain"):SetData(terrain.Translate(level_data))
	return parent
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
			if prototype.use_terrain_color then
				for _, material_path in ipairs(prototype.material_paths) do
					for _, material in ipairs(mtl_material.FromCryMTLList(material_path)) do
						if material:GetGroundColorBlend() == 0 then
							material:SetGroundColorBlend(0.5)
						end

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
