local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Material = import("goluwa/render3d/material.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local render3d = import("goluwa/render3d/render3d.lua")
return {
	{
		name = "gbuffer",
		on_draw = function(self, cmd)
			event.Call("PreDraw3D", dt)
			event.Call("Draw3DGeometry", dt)
		end,
		ColorFormat = {
			{"r8g8b8a8_srgb", {"albedo", "rgb"}, {"alpha", "a"}},
			{"r16g16b16a16_sfloat", {"normal", "rgb"}},
			{"r8g8b8a8_unorm", {"metallic", "r"}, {"roughness", "g"}, {"ao", "b"}},
			{"r16g16b16a16_sfloat", {"emissive", "rgb"}}, -- HDR emissive can exceed 1.0
		},
		DepthFormat = "d32_sfloat",
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			texture_blend = true,
		},
		fragment = {
			uniform_buffers = {
				{
					name = "debug_data",
					binding_index = 3,
					block = {
						render3d.debug_block,
					},
				},
				{
					name = "model",
					block = model_pipeline.GetPBRMaterialBlock(),
				},
			},
			shader = [[
			]] .. model_pipeline.BuildPBRSamplingGlsl("model") .. [[

			void compute_translucency_and_discard(inout float alpha) {
				if (AlphaTest) {
					if (alpha < model.AlphaCutoff) discard;
				} else if (Translucent) {
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > (alpha * alpha)) discard;
				}
			}

			vec3 get_vertex_normal() {
				vec3 N = in_normal;

				if (DoubleSided && gl_FrontFacing) {
					N = -N;
				}

				return normalize(N);
			}

			vec3 get_normal() {
				if ((debug_data.debug_mode - 1) == 5) {
					return get_vertex_normal();
				}

				vec3 N;
				if (model.NormalTexture == -1) {
					N = in_normal;
				} else {
					vec3 rgb1 = texture(TEXTURE(model.NormalTexture), in_uv).xyz * 2.0 - 1.0;


					if (model.Normal2Texture != -1) {
						float blend = get_texture_blend();
						if (blend != 0) {
							vec3 rgb2 = texture(TEXTURE(model.Normal2Texture), in_uv).xyz * 2.0 - 1.0;
							rgb1 = normalize(mix(rgb1, rgb2, blend));
						}
					}
					
					vec3 normal = normalize(in_normal);
					vec3 tangent = normalize(in_tangent.xyz);
					vec3 bitangent = cross(normal, tangent) * in_tangent.w;
					mat3 TBN = mat3(tangent, bitangent, normal);

					N = TBN * rgb1;
				}

				if (DoubleSided && gl_FrontFacing) {
					N = -N;
				}

				return normalize(N);
			}

			float get_metallic() {
				float val = 1.0;

				if (model.MetallicTexture != -1) {
					val = texture(TEXTURE(model.MetallicTexture), in_uv).r;
				} else if (model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(model.MetallicRoughnessTexture), in_uv).b;
				} else {
					val = model.MetallicMultiplier;
					val = clamp(val, 0, 1);
					return val;
				}

				val *= model.MetallicMultiplier;
				val = clamp(val, 0, 1);

				return val;
			}

			float get_roughness() {
				float val = 1.0;

				if (model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
					val = texture(TEXTURE(model.AlbedoTexture), in_uv).a;
				} else if (model.NormalTexture != -1 && NormalTextureAlphaIsRoughness) {
					val = -texture(TEXTURE(model.NormalTexture), in_uv).a+1;
				} else if (AlbedoLuminanceIsRoughness) {
					val = dot(get_albedo(), vec3(0.2126, 0.7152, 0.0722));
				} else if (model.RoughnessTexture != -1) {
					val = texture(TEXTURE(model.RoughnessTexture), in_uv).r;
				} else if (model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(model.MetallicRoughnessTexture), in_uv).g;
				} else  {
					val = model.RoughnessMultiplier;
					val = clamp(val, 0.05, 0.95);
					return val;
				}

				val *= model.RoughnessMultiplier;

				if (InvertRoughnessTexture) val = -val + 1.0;

				val *= val; // roughness squared

				val = clamp(val, 0.05, 0.95);
				
				return val;
			}

			vec3 get_emissive() {
				if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;
					if (model.AlbedoTexture != -1) {
						mask = texture(TEXTURE(model.AlbedoTexture), in_uv).a;
					}
					return get_albedo() * mask * model.EmissiveMultiplier.rgb * model.EmissiveMultiplier.a;
				}
				else if (model.EmissiveTexture != -1) {
					float mask = texture(TEXTURE(model.EmissiveTexture), in_uv).r;
					return get_albedo() * mask * model.EmissiveMultiplier.rgb * model.EmissiveMultiplier.a;
				} else if (model.MetallicTexture != -1 && MetallicTextureAlphaIsEmissive) {
					float mask = texture(TEXTURE(model.MetallicTexture), in_uv).a;
					return get_albedo() * mask * model.EmissiveMultiplier.rgb * model.EmissiveMultiplier.a;
				} else if (model.EmissiveTexture != -1) {
					vec3 emissive = texture(TEXTURE(model.EmissiveTexture), in_uv).rgb;
					return emissive * model.EmissiveMultiplier.rgb * model.EmissiveMultiplier.a;
				}
									return vec3(0);

			//	return (pc.model.EmissiveMultiplier.rgb - vec3(1)) * pc.model.EmissiveMultiplier.a;
			}

			float get_ao() {
				if (model.AmbientOcclusionTexture == -1) {
					return 1.0 * model.AmbientOcclusionMultiplier;
				}
				return texture(TEXTURE(model.AmbientOcclusionTexture), in_uv).r * model.AmbientOcclusionMultiplier;
			}

			void main() {
				float alpha = get_alpha();
				compute_translucency_and_discard(alpha);
				set_alpha(alpha); // debug
				set_albedo(get_albedo());
				set_normal(get_normal());
				set_metallic(get_metallic());
				set_roughness(get_roughness());
				set_ao(get_ao());
				set_emissive(get_emissive());
			}
		]],
		},
		DepthClamp = false,
		Discard = false,
		PolygonMode = "fill",
		LineWidth = 1.0,
		CullMode = orientation.CULL_MODE,
		FrontFace = orientation.FRONT_FACE,
		DepthBias = false,
		LogicOpEnabled = false,
		LogicOp = "copy",
		BlendConstants = {0.0, 0.0, 0.0, 0.0},
		Blend = false,
		ColorWriteMask = {"r", "g", "b", "a"},
		DepthTest = true,
		DepthWrite = true,
		DepthCompareOp = "less_or_equal",
		DepthBoundsTest = false,
		StencilTest = false,
	},
}
