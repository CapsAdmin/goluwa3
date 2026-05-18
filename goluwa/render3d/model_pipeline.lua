local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local model_pipeline = library()
local SURFACE_MATERIAL_FIELDS = {
	{type = "int", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
	{type = "float", name = "AlphaCutoff", getter = "GetAlphaCutoff"},
}
local PBR_MATERIAL_FIELDS = {
	{type = "int", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "Albedo2Texture", getter = "GetAlbedo2Texture"},
	{type = "texture", name = "NormalTexture", getter = "GetNormalTexture"},
	{type = "texture", name = "Normal2Texture", getter = "GetNormal2Texture"},
	{type = "texture", name = "HeightTexture", getter = "GetHeightTexture"},
	{type = "texture", name = "BlendTexture", getter = "GetBlendTexture"},
	{
		type = "texture",
		name = "TerrainMaterialTexture",
		getter = "GetTerrainMaterialTexture",
	},
	{
		type = "texture",
		name = "MetallicRoughnessTexture",
		getter = "GetMetallicRoughnessTexture",
	},
	{
		type = "texture",
		name = "AmbientOcclusionTexture",
		getter = "GetAmbientOcclusionTexture",
	},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{
		type = "vec4",
		name = "TerrainCheckerScales",
		getter = "GetTerrainCheckerScales",
	},
	{type = "vec4", name = "TerrainLayer1ColorA", getter = "GetTerrainLayer1ColorA"},
	{type = "vec4", name = "TerrainLayer1ColorB", getter = "GetTerrainLayer1ColorB"},
	{type = "vec4", name = "TerrainLayer2ColorA", getter = "GetTerrainLayer2ColorA"},
	{type = "vec4", name = "TerrainLayer2ColorB", getter = "GetTerrainLayer2ColorB"},
	{type = "vec4", name = "TerrainLayer3ColorA", getter = "GetTerrainLayer3ColorA"},
	{type = "vec4", name = "TerrainLayer3ColorB", getter = "GetTerrainLayer3ColorB"},
	{type = "vec4", name = "TerrainLayer4ColorA", getter = "GetTerrainLayer4ColorA"},
	{type = "vec4", name = "TerrainLayer4ColorB", getter = "GetTerrainLayer4ColorB"},
	{
		type = "vec4",
		name = "TerrainLayerRoughness",
		getter = "GetTerrainLayerRoughness",
	},
	{
		type = "vec4",
		name = "TerrainLayerAmbientOcclusion",
		getter = "GetTerrainLayerAmbientOcclusion",
	},
	{type = "float", name = "MetallicMultiplier", getter = "GetMetallicMultiplier"},
	{type = "float", name = "RoughnessMultiplier", getter = "GetRoughnessMultiplier"},
	{type = "float", name = "HeightScale", getter = "GetHeightScale"},
	{type = "float", name = "HeightCenter", getter = "GetHeightCenter"},
	{type = "int", name = "HeightLayers", getter = "GetHeightLayers"},
	{type = "float", name = "TessellationFactor", getter = "GetTessellationFactor"},
	{
		type = "float",
		name = "AmbientOcclusionMultiplier",
		getter = "GetAmbientOcclusionMultiplier",
	},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
	{type = "float", name = "AlphaCutoff", getter = "GetAlphaCutoff"},
	{type = "texture", name = "MetallicTexture", getter = "GetMetallicTexture"},
	{type = "texture", name = "RoughnessTexture", getter = "GetRoughnessTexture"},
}
local PROBE_MATERIAL_FIELDS = {
	{type = "int", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "Albedo2Texture", getter = "GetAlbedo2Texture"},
	{type = "texture", name = "NormalTexture", getter = "GetNormalTexture"},
	{type = "texture", name = "Normal2Texture", getter = "GetNormal2Texture"},
	{type = "texture", name = "HeightTexture", getter = "GetHeightTexture"},
	{type = "texture", name = "BlendTexture", getter = "GetBlendTexture"},
	{
		type = "texture",
		name = "TerrainMaterialTexture",
		getter = "GetTerrainMaterialTexture",
	},
	{
		type = "texture",
		name = "MetallicRoughnessTexture",
		getter = "GetMetallicRoughnessTexture",
	},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{
		type = "vec4",
		name = "TerrainCheckerScales",
		getter = "GetTerrainCheckerScales",
	},
	{type = "vec4", name = "TerrainLayer1ColorA", getter = "GetTerrainLayer1ColorA"},
	{type = "vec4", name = "TerrainLayer1ColorB", getter = "GetTerrainLayer1ColorB"},
	{type = "vec4", name = "TerrainLayer2ColorA", getter = "GetTerrainLayer2ColorA"},
	{type = "vec4", name = "TerrainLayer2ColorB", getter = "GetTerrainLayer2ColorB"},
	{type = "vec4", name = "TerrainLayer3ColorA", getter = "GetTerrainLayer3ColorA"},
	{type = "vec4", name = "TerrainLayer3ColorB", getter = "GetTerrainLayer3ColorB"},
	{type = "vec4", name = "TerrainLayer4ColorA", getter = "GetTerrainLayer4ColorA"},
	{type = "vec4", name = "TerrainLayer4ColorB", getter = "GetTerrainLayer4ColorB"},
	{type = "float", name = "MetallicMultiplier", getter = "GetMetallicMultiplier"},
	{type = "float", name = "RoughnessMultiplier", getter = "GetRoughnessMultiplier"},
	{type = "float", name = "HeightScale", getter = "GetHeightScale"},
	{type = "float", name = "HeightCenter", getter = "GetHeightCenter"},
	{type = "int", name = "HeightLayers", getter = "GetHeightLayers"},
	{type = "float", name = "TessellationFactor", getter = "GetTessellationFactor"},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
}

local function get_material()
	return render3d.GetMaterial()
end

function model_pipeline.GetVertexAttributes()
	return {
		{"position", "vec3", "r32g32b32_sfloat"},
		{"normal", "vec3", "r32g32b32_sfloat"},
		{"uv", "vec2", "r32g32_sfloat"},
		{"tangent", "vec4", "r32g32b32a32_sfloat"},
		{"texture_blend", "float", "r32_sfloat"},
	}
end

function model_pipeline.GetTransformBlock(get_projection_view_world_matrix)
	get_projection_view_world_matrix = get_projection_view_world_matrix or render3d.GetProjectionViewWorldMatrix
	return {
		{
			"projection_view_world",
			"mat4",
			function(self, block, key)
				get_projection_view_world_matrix():CopyToFloatPointer(block[key])
			end,
		},
		{
			"world",
			"mat4",
			function(self, block, key)
				render3d.GetWorldMatrix():CopyToFloatPointer(block[key])
			end,
		},
	}
end

local function build_vertex_shader(options)
	local lines = {
		"void main() {",
		"\tgl_Position = vertex.projection_view_world * vec4(in_position, 1.0);",
	}

	if options.position ~= false then
		lines[#lines + 1] = "\tout_position = (vertex.world * vec4(in_position, 1.0)).xyz;"
	end

	if options.normal then
		lines[#lines + 1] = "\tout_normal = normalize(mat3(vertex.world) * in_normal);"
	end

	if options.tangent then
		lines[#lines + 1] = "\tout_tangent = vec4(normalize(mat3(vertex.world) * in_tangent.xyz), in_tangent.w);"
	end

	if options.uv then lines[#lines + 1] = "\tout_uv = in_uv;" end

	if options.texture_blend then
		lines[#lines + 1] = "\tout_texture_blend = in_texture_blend;"
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

function model_pipeline.CreateVertexStage(options)
	options = options or {}
	local storage_key = options.transform_storage or "push_constants"
	return {
		binding_index = options.binding_index or 0,
		attributes = model_pipeline.GetVertexAttributes(),
		[storage_key] = {
			{
				name = options.transform_block_name or "vertex",
				block = model_pipeline.GetTransformBlock(options.get_projection_view_world_matrix),
			},
		},
		shader = build_vertex_shader(options),
	}
end

local function build_texture_field(field_name, getter_name)
	return {
		field_name,
		"int",
		function(self, block, key)
			local material = get_material()
			block[key] = self:GetTextureIndex(material[getter_name](material))
		end,
	}
end

local function build_scalar_field(field_name, field_type, getter_name)
	return {
		field_name,
		field_type,
		function(self, block, key)
			local material = get_material()
			block[key] = material[getter_name](material)
		end,
	}
end

local function build_vec4_field(field_name, getter_name)
	return {
		field_name,
		"vec4",
		function(self, block, key)
			local material = get_material()
			material[getter_name](material):CopyToFloatPointer(block[key])
		end,
	}
end

local function build_material_block(field_defs)
	local block = {}

	for i, def in ipairs(field_defs) do
		if def.type == "texture" then
			block[i] = build_texture_field(def.name, def.getter)
		elseif def.type == "vec4" then
			block[i] = build_vec4_field(def.name, def.getter)
		else
			block[i] = build_scalar_field(def.name, def.type, def.getter)
		end
	end

	return block
end

function model_pipeline.GetSurfaceMaterialBlock()
	return build_material_block(SURFACE_MATERIAL_FIELDS)
end

function model_pipeline.GetPBRMaterialBlock()
	return build_material_block(PBR_MATERIAL_FIELDS)
end

function model_pipeline.GetProbeMaterialBlock()
	return build_material_block(PROBE_MATERIAL_FIELDS)
end

function model_pipeline.BuildSurfaceSamplingGlsl(model_var)
	model_var = model_var or "model"
	return Material.BuildGlslFlags(model_var .. ".Flags") .. [[

			vec4 get_surface_color() {
				vec4 color = ]] .. model_var .. [[.ColorMultiplier;

				if (]] .. model_var .. [[.AlbedoTexture != -1) {
					color *= texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), in_uv);
				}

				return color;
			}

			void discard_surface_alpha(vec4 color) {
				if (AlphaTest && color.a < ]] .. model_var .. [[.AlphaCutoff) discard;
			}

			vec3 get_surface_emissive(vec3 albedo) {
				if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;

					if (]] .. model_var .. [[.AlbedoTexture != -1) {
						mask = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), in_uv).a;
					}

					return albedo * mask * ]] .. model_var .. [[.EmissiveMultiplier.rgb * ]] .. model_var .. [[.EmissiveMultiplier.a;
				}

				if (]] .. model_var .. [[.EmissiveTexture != -1) {
					vec3 emissive = texture(TEXTURE(]] .. model_var .. [[.EmissiveTexture), in_uv).rgb;
					return emissive * ]] .. model_var .. [[.EmissiveMultiplier.rgb * ]] .. model_var .. [[.EmissiveMultiplier.a;
				}

				return vec3(0.0);
			}
	]]
end

function model_pipeline.BuildPBRSamplingGlsl(model_var)
	model_var = model_var or "model"
	return Material.BuildGlslFlags(model_var .. ".Flags") .. [[

			bool has_heightmap() {
				return ]] .. model_var .. [[.HeightTexture != -1 && ]] .. model_var .. [[.HeightScale > 0.0;
			}

			float get_height_sample(vec2 uv) {
				if (!has_heightmap()) {
					return 1.0;
				}

				return texture(TEXTURE(]] .. model_var .. [[.HeightTexture), uv).r;
			}

			float get_height_centered_sample(vec2 uv) {
				return get_height_sample(uv) - ]] .. model_var .. [[.HeightCenter;
			}

			bool use_tessellated_displacement() {
				return has_heightmap() && ]] .. model_var .. [[.TessellationFactor > 1.0;
			}

			float get_tessellation_factor() {
				return clamp(]] .. model_var .. [[.TessellationFactor, 1.0, 64.0);
			}

			int get_height_layers() {
				return clamp(]] .. model_var .. [[.HeightLayers, 4, 64);
			}

			float get_texture_blend_uv(vec2 uv) {
				if (]] .. model_var .. [[.BlendTexture == -1) {
					return in_texture_blend;
				}

				float blend = in_texture_blend;
				vec2 blend_data = texture(TEXTURE(]] .. model_var .. [[.BlendTexture), uv).rg;
				float minb = blend_data.r;
				float maxb = blend_data.g;
				blend = clamp((blend - minb) / (maxb - minb + 0.001), 0.0, 1.0);
				return blend;
			}

			float get_texture_blend() {
				return get_texture_blend_uv(in_uv);
			}

			float sample_terrain_hash(vec2 p) {
				return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
			}

			float sample_terrain_noise(vec2 p) {
				vec2 cell = floor(p);
				vec2 frac = fract(p);
				frac = frac * frac * (3.0 - 2.0 * frac);
				return mix(
					mix(sample_terrain_hash(cell), sample_terrain_hash(cell + vec2(1.0, 0.0)), frac.x),
					mix(sample_terrain_hash(cell + vec2(0.0, 1.0)), sample_terrain_hash(cell + vec2(1.0, 1.0)), frac.x),
					frac.y
				);
			}

			vec3 sample_terrain_checker(vec2 world_pos, float checker_scale, vec3 color_a, vec3 color_b) {
				float safe_scale = max(checker_scale, 0.0001);
				vec2 sample_pos = world_pos / safe_scale;
				float macro = sample_terrain_noise(sample_pos);
				float micro = sample_terrain_noise(sample_pos * 2.7 + vec2(19.1, -7.3));
				float blend = clamp(macro * 0.72 + micro * 0.28, 0.0, 1.0);
				return mix(color_a, color_b, blend);
			}

			vec4 get_terrain_material_weights_uv(vec2 uv) {
				if (]] .. model_var .. [[.TerrainMaterialTexture == -1) {
					return vec4(0.0);
				}

				vec4 weights = texture(TEXTURE(]] .. model_var .. [[.TerrainMaterialTexture), uv);
				weights = max(weights, vec4(0.0));
				float weight_sum = dot(weights, vec4(1.0));

				if (weight_sum <= 0.0001) {
					return vec4(0.0);
				}

				return weights / weight_sum;
			}

			vec3 get_terrain_albedo_uv(vec2 uv, vec3 world_pos) {
				vec4 weights = get_terrain_material_weights_uv(uv);

				if (dot(weights, vec4(1.0)) <= 0.0001) {
					return ]] .. model_var .. [[.ColorMultiplier.rgb;
				}
				vec2 terrain_pos = world_pos.xz;
				vec3 layer1 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.x, ]] .. model_var .. [[.TerrainLayer1ColorA.rgb, ]] .. model_var .. [[.TerrainLayer1ColorB.rgb);
				vec3 layer2 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.y, ]] .. model_var .. [[.TerrainLayer2ColorA.rgb, ]] .. model_var .. [[.TerrainLayer2ColorB.rgb);
				vec3 layer3 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.z, ]] .. model_var .. [[.TerrainLayer3ColorA.rgb, ]] .. model_var .. [[.TerrainLayer3ColorB.rgb);
				vec3 layer4 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.w, ]] .. model_var .. [[.TerrainLayer4ColorA.rgb, ]] .. model_var .. [[.TerrainLayer4ColorB.rgb);
				vec3 color = layer1 * weights.r + layer2 * weights.g + layer3 * weights.b + layer4 * weights.a;

				if (]] .. model_var .. [[.AlbedoTexture != -1) {
					vec3 detail = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;
					color *= detail;
				}

				return color * ]] .. model_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_world(vec2 uv, vec3 world_pos) {
				if (]] .. model_var .. [[.TerrainMaterialTexture != -1) {
					return get_terrain_albedo_uv(uv, world_pos);
				}

				if (]] .. model_var .. [[.AlbedoTexture == -1) {
					return ]] .. model_var .. [[.ColorMultiplier.rgb;
				}

				vec3 rgb1 = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;

				if (]] .. model_var .. [[.Albedo2Texture != -1) {
					float blend = get_texture_blend_uv(uv);

					if (blend != 0) {
						vec3 rgb2 = texture(TEXTURE(]] .. model_var .. [[.Albedo2Texture), uv).rgb;
						rgb1 = mix(rgb1, rgb2, blend);
					}
				}

				return rgb1 * ]] .. model_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_uv(vec2 uv) {
				return get_albedo_world(uv, in_position);
			}

			vec3 get_albedo() {
				return get_albedo_uv(in_uv);
			}

			float get_alpha_uv(vec2 uv) {
				if (
					]] .. model_var .. [[.AlbedoTexture == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive
				) {
					return ]] .. model_var .. [[.ColorMultiplier.a;
				}

				return texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).a * ]] .. model_var .. [[.ColorMultiplier.a;
			}

			float get_alpha() {
				return get_alpha_uv(in_uv);
			}
	]]
end

function model_pipeline.BuildProbeSamplingGlsl(model_var)
	model_var = model_var or "model"
	return Material.BuildGlslFlags(model_var .. ".Flags") .. [[

			float get_texture_blend_uv(vec2 uv) {
				if (]] .. model_var .. [[.BlendTexture == -1) {
					return in_texture_blend;
				}

				float blend = in_texture_blend;
				vec2 blend_data = texture(TEXTURE(]] .. model_var .. [[.BlendTexture), uv).rg;
				float minb = blend_data.r;
				float maxb = blend_data.g;
				blend = clamp((blend - minb) / (maxb - minb + 0.001), 0.0, 1.0);
				return blend;
			}

			float sample_terrain_hash(vec2 p) {
				return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
			}

			float sample_terrain_noise(vec2 p) {
				vec2 cell = floor(p);
				vec2 frac = fract(p);
				frac = frac * frac * (3.0 - 2.0 * frac);
				return mix(
					mix(sample_terrain_hash(cell), sample_terrain_hash(cell + vec2(1.0, 0.0)), frac.x),
					mix(sample_terrain_hash(cell + vec2(0.0, 1.0)), sample_terrain_hash(cell + vec2(1.0, 1.0)), frac.x),
					frac.y
				);
			}

			vec3 sample_terrain_checker(vec2 world_pos, float checker_scale, vec3 color_a, vec3 color_b) {
				float safe_scale = max(checker_scale, 0.0001);
				vec2 sample_pos = world_pos / safe_scale;
				float macro = sample_terrain_noise(sample_pos);
				float micro = sample_terrain_noise(sample_pos * 2.7 + vec2(19.1, -7.3));
				float blend = clamp(macro * 0.72 + micro * 0.28, 0.0, 1.0);
				return mix(color_a, color_b, blend);
			}

			vec4 get_terrain_material_weights_uv(vec2 uv) {
				if (]] .. model_var .. [[.TerrainMaterialTexture == -1) {
					return vec4(0.0);
				}

				vec4 weights = texture(TEXTURE(]] .. model_var .. [[.TerrainMaterialTexture), uv);
				weights = max(weights, vec4(0.0));
				float weight_sum = dot(weights, vec4(1.0));

				if (weight_sum <= 0.0001) {
					return vec4(0.0);
				}

				return weights / weight_sum;
			}

			vec3 get_terrain_albedo_uv(vec2 uv, vec3 world_pos) {
				vec4 weights = get_terrain_material_weights_uv(uv);

				if (dot(weights, vec4(1.0)) <= 0.0001) {
					return ]] .. model_var .. [[.ColorMultiplier.rgb;
				}

				vec2 terrain_pos = world_pos.xz;
				vec3 layer1 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.x, ]] .. model_var .. [[.TerrainLayer1ColorA.rgb, ]] .. model_var .. [[.TerrainLayer1ColorB.rgb);
				vec3 layer2 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.y, ]] .. model_var .. [[.TerrainLayer2ColorA.rgb, ]] .. model_var .. [[.TerrainLayer2ColorB.rgb);
				vec3 layer3 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.z, ]] .. model_var .. [[.TerrainLayer3ColorA.rgb, ]] .. model_var .. [[.TerrainLayer3ColorB.rgb);
				vec3 layer4 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.w, ]] .. model_var .. [[.TerrainLayer4ColorA.rgb, ]] .. model_var .. [[.TerrainLayer4ColorB.rgb);
				vec3 color = layer1 * weights.r + layer2 * weights.g + layer3 * weights.b + layer4 * weights.a;

				if (]] .. model_var .. [[.AlbedoTexture != -1) {
					vec3 detail = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;
					color *= detail;
				}

				return color * ]] .. model_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_world(vec2 uv, vec3 world_pos) {
				if (]] .. model_var .. [[.TerrainMaterialTexture != -1) {
					return get_terrain_albedo_uv(uv, world_pos);
				}

				if (]] .. model_var .. [[.AlbedoTexture == -1) {
					return ]] .. model_var .. [[.ColorMultiplier.rgb;
				}

				vec3 rgb1 = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;

				if (]] .. model_var .. [[.Albedo2Texture != -1) {
					float blend = get_texture_blend_uv(uv);

					if (blend != 0) {
						vec3 rgb2 = texture(TEXTURE(]] .. model_var .. [[.Albedo2Texture), uv).rgb;
						rgb1 = mix(rgb1, rgb2, blend);
					}
				}

				return rgb1 * ]] .. model_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_uv(vec2 uv) {
				return get_albedo_world(uv, in_position);
			}

			vec3 get_albedo() {
				return get_albedo_uv(in_uv);
			}
	]]
end

return model_pipeline
