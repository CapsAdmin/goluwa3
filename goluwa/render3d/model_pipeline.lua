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
	{type = "texture", name = "BlendTexture", getter = "GetBlendTexture"},
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
	{type = "float", name = "MetallicMultiplier", getter = "GetMetallicMultiplier"},
	{type = "float", name = "RoughnessMultiplier", getter = "GetRoughnessMultiplier"},
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
	{type = "texture", name = "BlendTexture", getter = "GetBlendTexture"},
	{
		type = "texture",
		name = "MetallicRoughnessTexture",
		getter = "GetMetallicRoughnessTexture",
	},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{type = "float", name = "MetallicMultiplier", getter = "GetMetallicMultiplier"},
	{type = "float", name = "RoughnessMultiplier", getter = "GetRoughnessMultiplier"},
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

			float get_texture_blend() {
				if (]] .. model_var .. [[.BlendTexture == -1) {
					return in_texture_blend;
				}

				float blend = in_texture_blend;
				vec2 blend_data = texture(TEXTURE(]] .. model_var .. [[.BlendTexture), in_uv).rg;
				float minb = blend_data.r;
				float maxb = blend_data.g;
				blend = clamp((blend - minb) / (maxb - minb + 0.001), 0.0, 1.0);
				return blend;
			}

			vec3 get_albedo() {
				if (]] .. model_var .. [[.AlbedoTexture == -1) {
					return ]] .. model_var .. [[.ColorMultiplier.rgb;
				}

				vec3 rgb1 = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), in_uv).rgb;

				if (]] .. model_var .. [[.Albedo2Texture != -1) {
					float blend = get_texture_blend();

					if (blend != 0) {
						vec3 rgb2 = texture(TEXTURE(]] .. model_var .. [[.Albedo2Texture), in_uv).rgb;
						rgb1 = mix(rgb1, rgb2, blend);
					}
				}

				return rgb1 * ]] .. model_var .. [[.ColorMultiplier.rgb;
			}

			float get_alpha() {
				if (
					]] .. model_var .. [[.AlbedoTexture == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive
				) {
					return ]] .. model_var .. [[.ColorMultiplier.a;
				}

				return texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), in_uv).a * ]] .. model_var .. [[.ColorMultiplier.a;
			}
	]]
end

return model_pipeline
