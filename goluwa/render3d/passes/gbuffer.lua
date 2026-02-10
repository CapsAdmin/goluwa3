local event = require("event")
local orientation = require("render3d.orientation")
local Material = require("render3d.material")
local render3d = require("render3d.render3d")
return {
	{
		name = "gbuffer",
		on_draw = function(self, cmd)
			event.Call("PreDraw3D", cmd, dt)
			event.Call("Draw3DGeometry", cmd, dt)
		end,
		color_format = {
			{"r8g8b8a8_srgb", {"albedo", "rgb"}, {"alpha", "a"}},
			{"r16g16b16a16_sfloat", {"normal", "rgb"}},
			{"r8g8b8a8_unorm", {"metallic", "r"}, {"roughness", "g"}, {"ao", "b"}},
			{"r16g16b16a16_sfloat", {"emissive", "rgb"}}, -- HDR emissive can exceed 1.0
		},
		depth_format = "d32_sfloat",
		vertex = {
			binding_index = 0,
			attributes = {
				{"position", "vec3", "r32g32b32_sfloat"},
				{"normal", "vec3", "r32g32b32_sfloat"},
				{"uv", "vec2", "r32g32_sfloat"},
				{"tangent", "vec4", "r32g32b32a32_sfloat"},
				{"texture_blend", "float", "r32_sfloat"},
			},
			uniform_buffers = {
				{
					name = "pass_data",
					binding_index = 2,
					block = {
						{
							"projection_view_world",
							"mat4",
							function(self, block, key)
								render3d.GetProjectionViewWorldMatrix():CopyToFloatPointer(block[key])
							end,
						},
					},
				},
			},
			push_constants = {
				{
					name = "vertex",
					block = {
						{
							"world",
							"mat4",
							function(self, block, key)
								render3d.GetWorldMatrix():CopyToFloatPointer(block[key])
							end,
						},
					},
				},
			},
			shader = [[
			void main() {
				gl_Position = pass_data.projection_view_world * vec4(in_position, 1.0);
				out_position = (pc.vertex.world * vec4(in_position, 1.0)).xyz;						
				out_normal = normalize(mat3(pc.vertex.world) * in_normal);
				out_tangent = vec4(normalize(mat3(pc.vertex.world) * in_tangent.xyz), in_tangent.w);
				out_uv = in_uv;
				out_texture_blend = in_texture_blend;
			}
		]],
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
					name = "material_data",
					binding_index = 4,
					block = {
						{
							"ColorMultiplier",
							"vec4",
							function(self, block, key)
								render3d.GetMaterial():GetColorMultiplier():CopyToFloatPointer(block[key])
							end,
						},
						{
							"MetallicMultiplier",
							"float",
							function(self, block, key)
								block[key] = render3d.GetMaterial():GetMetallicMultiplier()
							end,
						},
						{
							"RoughnessMultiplier",
							"float",
							function(self, block, key)
								block[key] = render3d.GetMaterial():GetRoughnessMultiplier()
							end,
						},
						{
							"AmbientOcclusionMultiplier",
							"float",
							function(self, block, key)
								block[key] = render3d.GetMaterial():GetAmbientOcclusionMultiplier()
							end,
						},
						{
							"EmissiveMultiplier",
							"vec4",
							function(self, block, key)
								render3d.GetMaterial():GetEmissiveMultiplier():CopyToFloatPointer(block[key])
							end,
						},
						{
							"AlphaCutoff",
							"float",
							function(self, block, key)
								block[key] = render3d.GetMaterial():GetAlphaCutoff()
							end,
						},
					},
				},
			},
			push_constants = {
				{
					name = "model",
					block = {
						{
							"Flags",
							"int",
							function(self, block, key)
								block[key] = render3d.GetMaterial():GetFillFlags()
							end,
						},
						{
							"AlbedoTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetAlbedoTexture())
							end,
						},
						{
							"Albedo2Texture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetAlbedo2Texture())
							end,
						},
						{
							"NormalTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetNormalTexture())
							end,
						},
						{
							"Normal2Texture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetNormal2Texture())
							end,
						},
						{
							"BlendTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetBlendTexture())
							end,
						},
						{
							"MetallicRoughnessTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetMetallicRoughnessTexture())
							end,
						},
						{
							"AmbientOcclusionTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetAmbientOcclusionTexture())
							end,
						},
						{
							"EmissiveTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetEmissiveTexture())
							end,
						},
						{
							"MetallicTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetMetallicTexture())
							end,
						},
						{
							"RoughnessTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetRoughnessTexture())
							end,
						},
					},
				},
			},
			shader = [[
			]] .. Material.BuildGlslFlags("pc.model.Flags") .. [[

			float get_texture_blend() {
				if (pc.model.BlendTexture == -1) {
					return in_texture_blend;
				}

				float blend = in_texture_blend;
			
				vec2 blend_data = texture(TEXTURE(pc.model.BlendTexture), in_uv).rg;
				float minb = blend_data.r;
				float maxb = blend_data.g;
				
				// Remap vertex blend through the min/max range
				blend = clamp((blend - minb) / (maxb - minb + 0.001), 0.0, 1.0);

				return blend;
			}

			vec3 get_albedo() {
				if (pc.model.AlbedoTexture == -1) {
					return material_data.ColorMultiplier.rgb;
				}
				
				vec3 rgb1 = texture(TEXTURE(pc.model.AlbedoTexture), in_uv).rgb;
				
				if (pc.model.Albedo2Texture != -1) {
					float blend = get_texture_blend();
					
					if (blend != 0) {
						vec3 rgb2 = texture(TEXTURE(pc.model.Albedo2Texture), in_uv).rgb;
						rgb1 = mix(rgb1, rgb2, blend);
					}
				}
			
				return rgb1 * material_data.ColorMultiplier.rgb;
			}

			float get_alpha() {

				if (
					pc.model.AlbedoTexture == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive
				) {
					return material_data.ColorMultiplier.a;	
				}

				return texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a * material_data.ColorMultiplier.a;
			}

			void compute_translucency_and_discard(inout float alpha) {
				if (AlphaTest) {
					if (alpha < material_data.AlphaCutoff) discard;
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
				if (pc.model.NormalTexture == -1) {
					N = in_normal;
				} else {
					vec3 rgb1 = texture(TEXTURE(pc.model.NormalTexture), in_uv).xyz * 2.0 - 1.0;


					if (pc.model.Normal2Texture != -1) {
						float blend = get_texture_blend();
						if (blend != 0) {
							vec3 rgb2 = texture(TEXTURE(pc.model.Normal2Texture), in_uv).xyz * 2.0 - 1.0;
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

				if (pc.model.MetallicTexture != -1) {
					val = texture(TEXTURE(pc.model.MetallicTexture), in_uv).r;
				} else if (pc.model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).b;
				} else {
					val = material_data.MetallicMultiplier;
					val = clamp(val, 0, 1);
					return val;
				}

				val *= material_data.MetallicMultiplier;
				val = clamp(val, 0, 1);

				return val;
			}

			float get_roughness() {
				float val = 1.0;

				if (pc.model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
					val = texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a;
				} else if (pc.model.NormalTexture != -1 && NormalTextureAlphaIsRoughness) {
					val = -texture(TEXTURE(pc.model.NormalTexture), in_uv).a+1;
				} else if (AlbedoLuminanceIsRoughness) {
					val = dot(get_albedo(), vec3(0.2126, 0.7152, 0.0722));
				} else if (pc.model.RoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.RoughnessTexture), in_uv).r;
				} else if (pc.model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).g;
				} else  {
					val = material_data.RoughnessMultiplier;
					val = clamp(val, 0.05, 0.95);
					return val;
				}

				val *= material_data.RoughnessMultiplier;

				if (InvertRoughnessTexture) val = -val + 1.0;

				val *= val; // roughness squared

				val = clamp(val, 0.05, 0.95);
				
				return val;
			}

			vec3 get_emissive() {
				if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;
					if (pc.model.AlbedoTexture != -1) {
						mask = texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a;
					}
					return get_albedo() * mask * material_data.EmissiveMultiplier.rgb * material_data.EmissiveMultiplier.a;
				}
				else if (pc.model.EmissiveTexture != -1) {
					float mask = texture(TEXTURE(pc.model.EmissiveTexture), in_uv).r;
					return get_albedo() * mask * material_data.EmissiveMultiplier.rgb * material_data.EmissiveMultiplier.a;
				} else if (pc.model.MetallicTexture != -1 && MetallicTextureAlphaIsEmissive) {
					float mask = texture(TEXTURE(pc.model.MetallicTexture), in_uv).a;
					return get_albedo() * mask * material_data.EmissiveMultiplier.rgb * material_data.EmissiveMultiplier.a;
				} else if (pc.model.EmissiveTexture != -1) {
					vec3 emissive = texture(TEXTURE(pc.model.EmissiveTexture), in_uv).rgb;
					return emissive * material_data.EmissiveMultiplier.rgb * material_data.EmissiveMultiplier.a;
				}
									return vec3(0);

			//	return (material_data.EmissiveMultiplier.rgb - vec3(1)) * material_data.EmissiveMultiplier.a;
			}

			float get_ao() {
				if (pc.model.AmbientOcclusionTexture == -1) {
					return 1.0 * material_data.AmbientOcclusionMultiplier;
				}
				return texture(TEXTURE(pc.model.AmbientOcclusionTexture), in_uv).r * material_data.AmbientOcclusionMultiplier;
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
		rasterizer = {
			depth_clamp = false,
			discard = false,
			polygon_mode = "fill",
			line_width = 1.0,
			cull_mode = orientation.CULL_MODE,
			front_face = orientation.FRONT_FACE,
			depth_bias = 0,
		},
		dynamic_state = {
			"cull_mode",
		},
		color_blend = {
			logic_op_enabled = false,
			logic_op = "copy",
			constants = {0.0, 0.0, 0.0, 0.0},
			attachments = {
				{blend = false, color_write_mask = {"r", "g", "b", "a"}},
				{blend = false, color_write_mask = {"r", "g", "b", "a"}},
				{blend = false, color_write_mask = {"r", "g", "b", "a"}},
				{blend = false, color_write_mask = {"r", "g", "b", "a"}},
			},
		},
		depth_stencil = {
			depth_test = true,
			depth_write = true,
			depth_compare_op = "less_or_equal",
			depth_bounds_test_enabled = false,
			stencil_test_enabled = false,
		},
	},
}
