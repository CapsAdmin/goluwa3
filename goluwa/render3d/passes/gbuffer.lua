local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Material = import("goluwa/render3d/material.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local render3d = import("goluwa/render3d/render3d.lua")

local function build_base_pass(fragment_shader, enable_vertex_animation)
	local function BuildPBRSamplingGlsl(
		model_var,
		terrain_var,
		displacement_var,
		detail_var,
		aux_var,
		factor_var,
		color_var
	)
		model_var = model_var or "model"
		terrain_var = terrain_var or model_var
		displacement_var = displacement_var or model_var
		detail_var = detail_var or model_var
		aux_var = aux_var or model_var
		factor_var = factor_var or model_var
		color_var = color_var or factor_var
		return Material.BuildGlslFlags(model_var .. ".Flags") .. [[

			bool has_heightmap() {
				return ]] .. displacement_var .. [[.HeightTexture != -1 && ]] .. displacement_var .. [[.HeightScale > 0.0;
			}

			float get_height_sample(vec2 uv) {
				if (!has_heightmap()) {
					return 1.0;
				}

				return texture(TEXTURE(]] .. displacement_var .. [[.HeightTexture), uv).r;
			}

			float get_height_centered_sample(vec2 uv) {
				return get_height_sample(uv) - ]] .. displacement_var .. [[.HeightCenter;
			}

			bool use_tessellated_displacement() {
				return has_heightmap() && ]] .. displacement_var .. [[.TessellationFactor > 1.0;
			}

			float get_tessellation_factor() {
				return clamp(]] .. displacement_var .. [[.TessellationFactor, 1.0, 64.0);
			}

			int get_height_layers() {
				return clamp(]] .. displacement_var .. [[.HeightLayers, 4, 64);
			}

			float get_texture_blend_uv(vec2 uv) {
				if (]] .. detail_var .. [[.BlendTexture == -1) {
					return in_texture_blend;
				}

				float blend = in_texture_blend;
				vec2 blend_data = texture(TEXTURE(]] .. detail_var .. [[.BlendTexture), uv).rg;
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

			vec3 sample_terrain_layer_detail(int tex, vec2 world_pos, float checker_scale, float detail_strength, vec3 color_a, vec3 color_b) {
				vec3 base = sample_terrain_checker(world_pos, checker_scale, color_a, color_b);

				if (tex == -1) {
					return base;
				}

				float safe_scale = max(checker_scale, 0.0001);
				vec2 sample_pos = world_pos / safe_scale;
				vec3 detail = texture(TEXTURE(tex), sample_pos).rgb;
				return base * mix(vec3(1.0), detail, clamp(detail_strength, 0.0, 2.0));
			}

			vec4 get_terrain_material_weights_uv(vec2 uv) {
				if (]] .. terrain_var .. [[.TerrainMaterialTexture == -1) {
					return vec4(0.0);
				}

				vec4 weights = texture(TEXTURE(]] .. terrain_var .. [[.TerrainMaterialTexture), uv);
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
					return ]] .. color_var .. [[.ColorMultiplier.rgb;
				}
				vec2 terrain_pos = world_pos.xz;
				vec3 layer1 = sample_terrain_layer_detail(]] .. terrain_var .. [[.TerrainLayer1Texture, terrain_pos, ]] .. terrain_var .. [[.TerrainCheckerScales.x, ]] .. terrain_var .. [[.TerrainLayerDetailStrength.x, ]] .. terrain_var .. [[.TerrainLayer1ColorA.rgb, ]] .. terrain_var .. [[.TerrainLayer1ColorB.rgb);
				vec3 layer2 = sample_terrain_layer_detail(]] .. terrain_var .. [[.TerrainLayer2Texture, terrain_pos, ]] .. terrain_var .. [[.TerrainCheckerScales.y, ]] .. terrain_var .. [[.TerrainLayerDetailStrength.y, ]] .. terrain_var .. [[.TerrainLayer2ColorA.rgb, ]] .. terrain_var .. [[.TerrainLayer2ColorB.rgb);
				vec3 layer3 = sample_terrain_layer_detail(]] .. terrain_var .. [[.TerrainLayer3Texture, terrain_pos, ]] .. terrain_var .. [[.TerrainCheckerScales.z, ]] .. terrain_var .. [[.TerrainLayerDetailStrength.z, ]] .. terrain_var .. [[.TerrainLayer3ColorA.rgb, ]] .. terrain_var .. [[.TerrainLayer3ColorB.rgb);
				vec3 layer4 = sample_terrain_layer_detail(]] .. terrain_var .. [[.TerrainLayer4Texture, terrain_pos, ]] .. terrain_var .. [[.TerrainCheckerScales.w, ]] .. terrain_var .. [[.TerrainLayerDetailStrength.w, ]] .. terrain_var .. [[.TerrainLayer4ColorA.rgb, ]] .. terrain_var .. [[.TerrainLayer4ColorB.rgb);
				vec3 color = layer1 * weights.r + layer2 * weights.g + layer3 * weights.b + layer4 * weights.a;

				if (]] .. model_var .. [[.AlbedoTexture != -1) {
					vec3 detail = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;
					color *= detail;
				}

				return color * ]] .. color_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_world(vec2 uv, vec3 world_pos) {
				if (]] .. terrain_var .. [[.TerrainMaterialTexture != -1) {
					return get_terrain_albedo_uv(uv, world_pos);
				}

				if (]] .. model_var .. [[.AlbedoTexture == -1) {
					return ]] .. color_var .. [[.ColorMultiplier.rgb;
				}

				vec3 rgb1 = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;

				if (]] .. detail_var .. [[.Albedo2Texture != -1) {
					float blend = get_texture_blend_uv(uv);

					if (blend != 0) {
						vec3 rgb2 = texture(TEXTURE(]] .. detail_var .. [[.Albedo2Texture), uv).rgb;
						rgb1 = mix(rgb1, rgb2, blend);
					}
				}

				return rgb1 * ]] .. color_var .. [[.ColorMultiplier.rgb;
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
					return ]] .. color_var .. [[.ColorMultiplier.a;
				}

				return texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).a * ]] .. color_var .. [[.ColorMultiplier.a;
			}

			float get_alpha() {
				return get_alpha_uv(in_uv);
			}
	]]
	end

	return {
		name = "gbuffer",
		on_draw = function(self, cmd)
			render3d.ResetQueuedGBufferInstances()
			event.Call("PreDraw3D", dt)
			event.Call("Draw3DGeometry", dt)
			render3d.FlushQueuedGBufferInstances()
		end,
		ColorFormat = {
			{"r8g8b8a8_srgb", {"albedo", "rgb"}, {"alpha", "a"}},
			{"r16g16b16a16_sfloat", {"normal", "rgb"}, {"transmission_view_dep", "a"}},
			{
				"r8g8b8a8_unorm",
				{"metallic", "r"},
				{"roughness", "g"},
				{"ao", "b"},
				{"subsurface", "a"},
			},
			{"r16g16b16a16_sfloat", {"emissive", "rgb"}, {"transmission_blocking", "a"}},
			{"r16_sfloat", {"transmission_blocking_raw", "r"}},
		},
		DepthFormat = "d32_sfloat",
		fragment = {
			uniform_buffers = {
				{
					name = "gbuffer_data",
					binding_index = 3,
					upload_scope = "frame",
					block = {
						render3d.camera_block,
						render3d.debug_block,
					},
					write = render3d.WriteCameraDebugBlock,
				},
				{
					name = "model",
					upload_scope = "persistent_keyed",
					upload_key = render3d.GetMaterialUploadKey,
					block = model_pipeline.GetPBRMaterialBlock(),
					write = model_pipeline.WritePBRMaterialBlock,
				},
				{
					name = "color_model",
					upload_scope = "frame_keyed",
					upload_key = model_pipeline.GetPBRColorUploadKey,
					block = model_pipeline.GetPBRColorMaterialBlock(),
					write = model_pipeline.WritePBRColorMaterialBlock,
				},
				{
					name = "factor_model",
					upload_scope = "persistent_keyed",
					upload_key = model_pipeline.GetPBRFactorUploadKey,
					block = model_pipeline.GetPBRFactorMaterialBlock(),
					write = model_pipeline.WritePBRFactorMaterialBlock,
				},
				{
					name = "detail_model",
					upload_scope = "persistent_keyed",
					upload_key = model_pipeline.GetPBRDetailUploadKey,
					block = model_pipeline.GetPBRDetailMaterialBlock(),
					write = model_pipeline.WritePBRDetailMaterialBlock,
				},
				{
					name = "aux_model",
					upload_scope = "frame_keyed",
					upload_key = model_pipeline.GetPBRAuxUploadKey,
					block = model_pipeline.GetPBRAuxMaterialBlock(),
					write = model_pipeline.WritePBRAuxMaterialBlock,
				},
				{
					name = "displacement_model",
					upload_scope = "frame_keyed",
					upload_key = model_pipeline.GetPBRDisplacementUploadKey,
					block = model_pipeline.GetPBRDisplacementMaterialBlock(),
					write = model_pipeline.WritePBRDisplacementMaterialBlock,
				},
				{
					name = "terrain_model",
					upload_scope = "frame_keyed",
					upload_key = model_pipeline.GetPBRTerrainUploadKey,
					block = model_pipeline.GetPBRTerrainMaterialBlock(),
					write = model_pipeline.WritePBRTerrainMaterialBlock,
				},
				{
					name = "transmission_model",
					upload_scope = "frame_keyed",
					upload_key = model_pipeline.GetPBRTransmissionUploadKey,
					block = model_pipeline.GetPBRTransmissionMaterialBlock(),
					write = model_pipeline.WritePBRTransmissionMaterialBlock,
				},
			},
			shader = [[
			]] .. BuildPBRSamplingGlsl(
					"model",
					"terrain_model",
					"displacement_model",
					"detail_model",
					"aux_model",
					"factor_model",
					"color_model"
				) .. model_pipeline.BuildAlphaDiscardGlsl("factor_model.AlphaCutoff") .. [[
					vec3 get_vertex_normal() {
						vec3 N = in_normal;

						if (DoubleSided && gl_FrontFacing) {
							N = -N;
						}

						return normalize(N);
					}

					mat3 get_tbn() {
						vec3 normal = normalize(in_normal);
						vec3 tangent = normalize(in_tangent.xyz);
						vec3 bitangent = cross(normal, tangent) * in_tangent.w;

						if (DoubleSided && gl_FrontFacing) {
							normal = -normal;
							bitangent = -bitangent;
						}

						return mat3(tangent, bitangent, normal);
					}

					vec3 get_vertex_tangent(mat3 tbn) {
						return normalize(tbn[0]);
					}

					vec3 get_vertex_bitangent(mat3 tbn) {
						return normalize(tbn[1]);
					}

					vec4 get_vertex_color() {
						return clamp(in_vertex_color, 0.0, 1.0);
					}

					vec3 encode_debug_vector(vec3 v) {
						return normalize(v) * 0.5 + 0.5;
					}

					vec3 encode_debug_basis(vec3 v) {
						return abs(normalize(v));
					}

					vec3 get_height_normal_tangent(vec2 uv) {
						vec2 texel = 1.0 / vec2(textureSize(TEXTURE(displacement_model.HeightTexture), 0));
						float left = get_height_centered_sample(uv - vec2(texel.x, 0.0));
						float right = get_height_centered_sample(uv + vec2(texel.x, 0.0));
						float down = get_height_centered_sample(uv - vec2(0.0, texel.y));
						float up = get_height_centered_sample(uv + vec2(0.0, texel.y));
						return normalize(vec3(left - right, down - up, max(displacement_model.HeightScale, 0.0001)));
					}

					vec3 get_normal_map(vec2 uv) {
						if (model.NormalTexture == -1) {
							if (has_heightmap()) {
								return get_height_normal_tangent(uv);
							}

							return vec3(0.0, 0.0, 1.0);
						}

						vec2 normal_xy1 = texture(TEXTURE(model.NormalTexture), uv).xy * 2.0 - 1.0;

						if (ReverseXZNormalMap) {
							normal_xy1 = -normal_xy1;
						}

						vec3 rgb1 = vec3(normal_xy1, sqrt(max(1.0 - dot(normal_xy1, normal_xy1), 0.0)));

						if (detail_model.Normal2Texture != -1) {
							float blend = get_texture_blend_uv(uv);

							if (blend != 0) {
								vec2 normal_xy2 = texture(TEXTURE(detail_model.Normal2Texture), uv).xy * 2.0 - 1.0;

								if (ReverseXZNormalMap) {
									normal_xy2 = -normal_xy2;
								}

								vec3 rgb2 = vec3(normal_xy2, sqrt(max(1.0 - dot(normal_xy2, normal_xy2), 0.0)));
								rgb1 = normalize(mix(rgb1, rgb2, blend));
							}
						}

						return normalize(rgb1);
					}

					vec3 get_combined_normal(vec2 uv, mat3 tbn) {
						vec3 N = tbn * get_normal_map(uv);

						if (DoubleSided && gl_FrontFacing) {
							N = -N;
						}

						return normalize(N);
					}

					vec3 get_normal(vec2 uv, mat3 tbn) {
						vec4 vertex_color = get_vertex_color();

						if ((gbuffer_data.debug_mode - 1) == 5) {
							return get_vertex_normal();
						}

						if (gbuffer_data.gbuffer_normal_debug_view == 1) {
							return encode_debug_vector(get_normal_map(uv));
						}

						if (gbuffer_data.gbuffer_normal_debug_view == 2) {
							return encode_debug_vector(get_vertex_normal());
						}

						if (gbuffer_data.gbuffer_normal_debug_view == 3) {
							return encode_debug_basis(get_vertex_tangent(tbn));
						}

						if (gbuffer_data.gbuffer_normal_debug_view == 4) {
							return encode_debug_basis(get_vertex_bitangent(tbn));
						}

						if (gbuffer_data.gbuffer_normal_debug_view == 5) {
							return vertex_color.rgb;
						}

						if (gbuffer_data.gbuffer_normal_debug_view == 6) {
							return vec3(vertex_color.r);
						}

						if (gbuffer_data.gbuffer_normal_debug_view == 7) {
							return vec3(vertex_color.g);
						}

						if (gbuffer_data.gbuffer_normal_debug_view == 8) {
							return vec3(vertex_color.b);
						}

						if (gbuffer_data.gbuffer_normal_debug_view == 9) {
							return vec3(vertex_color.a);
						}

						return get_combined_normal(uv, tbn);
					}

					float get_metallic(vec2 uv) {
						float val = 1.0;

						if (aux_model.MetallicTexture != -1) {
							val = texture(TEXTURE(aux_model.MetallicTexture), uv).r;
						} else if (aux_model.MetallicRoughnessTexture != -1) {
							val = texture(TEXTURE(aux_model.MetallicRoughnessTexture), uv).b;
						} else {
							val = factor_model.MetallicMultiplier;
							val = clamp(val, 0, 1);
							return val;
						}

						val *= factor_model.MetallicMultiplier;
						val = clamp(val, 0, 1);

						return val;
					}

					float get_roughness(vec2 uv) {
						float val = 1.0;

						if (model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
							val = texture(TEXTURE(model.AlbedoTexture), uv).a;
						} else if (model.NormalTexture != -1 && NormalTextureAlphaIsRoughness) {
							val = -texture(TEXTURE(model.NormalTexture), uv).a + 1.0;
						} else if (AlbedoLuminanceIsRoughness) {
							val = dot(get_albedo_uv(uv), vec3(0.2126, 0.7152, 0.0722));
						} else if (aux_model.RoughnessTexture != -1) {
							val = texture(TEXTURE(aux_model.RoughnessTexture), uv).r;
						} else if (aux_model.MetallicRoughnessTexture != -1) {
							val = texture(TEXTURE(aux_model.MetallicRoughnessTexture), uv).g;
						} else if (terrain_model.TerrainMaterialTexture != -1) {
							val = dot(get_terrain_material_weights_uv(uv), terrain_model.TerrainLayerRoughness);
						} else {
							val = factor_model.RoughnessMultiplier;
							val = clamp(val, 0.05, 0.95);
							return val;
						}

						val *= factor_model.RoughnessMultiplier;

						if (InvertRoughnessTexture) val = -val + 1.0;

						val *= val;
						val = clamp(val, 0.05, 0.95);
						return val;
					}

					float get_subsurface(vec2 uv) {
						if (!Subsurface) return 0.0;

						float strength = DoubleSided ? 1.0 : 0.35;

						if (model.AlbedoTexture != -1) {
							strength *= clamp(texture(TEXTURE(model.AlbedoTexture), uv).g, 0.35, 1.0);
						}

						return clamp(strength, 0.0, 1.0);
					}

					float get_transmission_view_dependency() {
						if (!Subsurface) return 0.0;
						return clamp(transmission_model.TransmissionViewDependency, 0.0, 1.0);
					}

					vec3 get_transmission_color() {
						if (!Subsurface) return vec3(0.0);
						return transmission_model.TransmissionColor.rgb * transmission_model.TransmissionColor.a;
					}

					float get_transmission_blocking_raw(vec2 uv) {
						if (!Subsurface) return 0.0;

						if (aux_model.RoughnessTexture != -1) {
							return clamp(texture(TEXTURE(aux_model.RoughnessTexture), uv).a, 0.0, 1.0);
						}

						if (aux_model.OpacityTexture != -1) {
							vec4 mask = texture(TEXTURE(aux_model.OpacityTexture), uv);
							return clamp(max(max(mask.r, mask.g), max(mask.b, mask.a)), 0.0, 1.0);
						}

						return clamp(get_alpha_uv(uv), 0.0, 1.0);
					}

					float get_transmission_blocking(vec2 uv) {
						if (!Subsurface) return 0.0;

						float blocking = transmission_model.TransmissionBlocking;

						if (aux_model.RoughnessTexture != -1) {
							blocking *= texture(TEXTURE(aux_model.RoughnessTexture), uv).a;
							return clamp(blocking, 0.0, 1.0);
						}

						if (aux_model.OpacityTexture != -1) {
							vec4 mask = texture(TEXTURE(aux_model.OpacityTexture), uv);
							blocking *= max(max(mask.r, mask.g), max(mask.b, mask.a));
							return clamp(blocking, 0.0, 1.0);
						}

						blocking *= get_alpha_uv(uv);
						return clamp(blocking, 0.0, 1.0);
					}

					vec3 get_emissive(vec2 uv) {
						if (Subsurface) {
							return get_transmission_color();
						}

						if (AlbedoAlphaIsEmissive) {
							float mask = 1.0;
							if (model.AlbedoTexture != -1) {
								mask = texture(TEXTURE(model.AlbedoTexture), uv).a;
							}
							return get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
						} else if (aux_model.EmissiveTexture != -1) {
							float mask = texture(TEXTURE(aux_model.EmissiveTexture), uv).r;
							return get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
						} else if (aux_model.MetallicTexture != -1 && MetallicTextureAlphaIsEmissive) {
							float mask = texture(TEXTURE(aux_model.MetallicTexture), uv).a;
							return get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
						} else if (aux_model.EmissiveTexture != -1) {
							vec3 emissive = texture(TEXTURE(aux_model.EmissiveTexture), uv).rgb;
							return emissive * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
						}

						return vec3(0.0);
					}

					float get_ao(vec2 uv) {
						if (aux_model.AmbientOcclusionTexture == -1) {
							if (terrain_model.TerrainMaterialTexture != -1) {
								return dot(get_terrain_material_weights_uv(uv), terrain_model.TerrainLayerAmbientOcclusion) * aux_model.AmbientOcclusionMultiplier;
							}

							return 1.0 * aux_model.AmbientOcclusionMultiplier;
						}

						return texture(TEXTURE(aux_model.AmbientOcclusionTexture), uv).r * aux_model.AmbientOcclusionMultiplier;
					}
			]] .. fragment_shader,
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
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			texture_blend = true,
			vertex_color = true,
			include_projection_view_world = false,
			camera_uniform_block_name = "gbuffer_data",
			uniform_buffers = {
				{
					name = "gbuffer_data",
					binding_index = 3,
					upload_scope = "frame",
					block = {
						render3d.camera_block,
						render3d.debug_block,
					},
					write = render3d.WriteCameraDebugBlock,
				},
			},
			enable_vertex_animation = enable_vertex_animation,
		},
	}
end

local function build_instanced_pass(fragment_shader)
	local pass = build_base_pass(fragment_shader, true)
	pass.name = "gbuffer_instanced"
	pass.draw_in_prerender = false
	pass.dont_create_framebuffers = true
	pass.on_draw = nil
	pass.vertex = model_pipeline.CreateInstancedVertexStage{
		normal = true,
		tangent = true,
		uv = true,
		texture_blend = true,
		vertex_color = true,
		include_projection_view = false,
		camera_uniform_block_name = "gbuffer_data",
		uniform_buffers = {
			{
				name = "gbuffer_data",
				binding_index = 3,
				upload_scope = "frame",
				block = {
					render3d.camera_block,
					render3d.debug_block,
				},
				write = render3d.WriteCameraDebugBlock,
			},
		},
		enable_vertex_animation = true,
	}
	return pass
end

local function build_ssdm_fragment_shader(displacement_var)
	displacement_var = displacement_var or "model"
	return [[
		struct SSDMData {
			vec2 uv;
			float height;
			vec3 world_pos;
		};

		vec3 get_view_dir_world(vec3 world_pos) {
			return normalize(gbuffer_data.camera_position.xyz - world_pos);
		}

		float get_projected_depth(vec3 world_pos) {
			vec4 clip_pos = gbuffer_data.projection * gbuffer_data.view * vec4(world_pos, 1.0);
			float clip_w = max(clip_pos.w, 0.0001);
			return clamp(clip_pos.z / clip_w, 0.0, 1.0);
		}

		SSDMData get_ssdm_data(mat3 tbn) {
			SSDMData data;
			data.uv = in_uv;
			data.height = 0.0;
			data.world_pos = in_position;

			if (!has_heightmap()) {
				return data;
			}

			vec3 view_dir_world = get_view_dir_world(in_position);
			vec3 view_dir_tangent = normalize(transpose(tbn) * view_dir_world);
			float view_z = max(view_dir_tangent.z, 0.05);
			int layer_count = get_height_layers();
			float layer_depth = 1.0 / float(layer_count);
			float current_layer_depth = 0.0;
			vec2 current_uv = in_uv;
			vec2 delta_uv = -(view_dir_tangent.xy / view_z) * displacement_model.HeightScale / float(layer_count);
			float current_map_depth = 1.0 - (get_height_centered_sample(current_uv) + displacement_model.HeightCenter);
			vec2 previous_uv = current_uv;
			float previous_layer_depth = current_layer_depth;
			float previous_map_depth = current_map_depth;

			for (int i = 0; i < 64; i++) {
				if (i >= layer_count || current_layer_depth >= current_map_depth) {
					break;
				}

				previous_uv = current_uv;
				previous_layer_depth = current_layer_depth;
				previous_map_depth = current_map_depth;
				current_uv = current_uv + delta_uv;
				current_layer_depth += layer_depth;
				current_map_depth = 1.0 - (get_height_centered_sample(current_uv) + displacement_model.HeightCenter);
			}

			float after_depth = current_map_depth - current_layer_depth;
			float before_depth = previous_map_depth - previous_layer_depth;
			float weight = 0.0;
			float denominator = after_depth - before_depth;

			if (abs(denominator) > 0.0001) {
				weight = clamp(after_depth / denominator, 0.0, 1.0);
			}

			float parallax_depth = mix(current_layer_depth, previous_layer_depth, weight);
			float centered_height = parallax_depth - displacement_model.HeightCenter;
			data.uv = mix(current_uv, previous_uv, weight);
			data.height = centered_height * displacement_model.HeightScale;
			data.world_pos = in_position - view_dir_world * (data.height / view_z);
			return data;
		}

		void main() {
			mat3 tbn = get_tbn();
			SSDMData displacement = get_ssdm_data(tbn);
			float alpha = get_alpha_uv(displacement.uv);
			compute_translucency_and_discard(alpha);

			set_alpha(alpha);
			set_albedo(get_albedo_world(displacement.uv, displacement.world_pos));
			set_normal(get_normal(displacement.uv, tbn));
			set_transmission_view_dep(get_transmission_view_dependency());
			set_metallic(get_metallic(displacement.uv));
			set_roughness(get_roughness(displacement.uv));
			set_ao(get_ao(displacement.uv));
			set_subsurface(get_subsurface(displacement.uv));
			set_transmission_blocking(get_transmission_blocking(displacement.uv));
			set_transmission_blocking_raw(get_transmission_blocking_raw(displacement.uv));
			set_emissive(get_emissive(displacement.uv));
			gl_FragDepth = has_heightmap() ? get_projected_depth(displacement.world_pos) : gl_FragCoord.z;
		}
	]]
end

if render.GetDevice().physical_device:GetFeatures().tessellationShader == 1 then
	local function build_tessellation_evaluation_shader(enable_vertex_animation, displacement_var)
		enable_vertex_animation = enable_vertex_animation ~= false
		displacement_var = displacement_var or "model"
		local str = Material.BuildGlslFlags("model.Flags")

		if enable_vertex_animation then
			str = str .. model_pipeline.BuildVertexAnimationGlsl("vertex_animation")
		end

		str = str .. [[
			bool has_heightmap() {
				return displacement_model.HeightTexture != -1 && displacement_model.HeightScale > 0.0;
			}

			float get_height_sample(vec2 uv) {
				if (!has_heightmap()) {
					return 1.0;
				}

				return texture(TEXTURE(displacement_model.HeightTexture), uv).r;
			}

			float get_height_centered_sample(vec2 uv) {
				return get_height_sample(uv) - displacement_model.HeightCenter;
			}

			bool use_tessellated_displacement() {
				return has_heightmap() && displacement_model.TessellationFactor > 1.0;
			}

			layout(triangles, equal_spacing, cw) in;

		]] .. model_pipeline.BuildTriangleInterpolationGlsl() .. [[

		void main() {
			vec3 world_pos = interpolate_vec3(in_position[0], in_position[1], in_position[2]);
			vec3 normal = normalize(interpolate_vec3(in_normal[0], in_normal[1], in_normal[2]));
			vec3 displacement_normal = vec3(0.0, 1.0, 0.0);
			vec3 tangent_xyz = normalize(interpolate_vec3(in_tangent[0].xyz, in_tangent[1].xyz, in_tangent[2].xyz));
			float tangent_w = interpolate_float(in_tangent[0].w, in_tangent[1].w, in_tangent[2].w);
			vec2 uv = interpolate_vec2(in_uv[0], in_uv[1], in_uv[2]);
			float texture_blend = interpolate_float(in_texture_blend[0], in_texture_blend[1], in_texture_blend[2]);
			vec4 vertex_color = interpolate_vec4(in_vertex_color[0], in_vertex_color[1], in_vertex_color[2]);

			if (use_tessellated_displacement()) {
				world_pos += displacement_normal * (get_height_centered_sample(uv) * displacement_model.HeightScale);
			}

			]]

		if enable_vertex_animation then
			str = str .. [[
					vec3 world_offset = get_vertex_animation_offset(world_pos, normal, tangent_xyz, uv, texture_blend, vertex_color);
					world_pos += world_offset;
					normal = bend_vertex_animation_direction(normal, world_offset);
					tangent_xyz = bend_vertex_animation_direction(tangent_xyz, world_offset);
			]]
		end

		str = str .. [[

					out_position = world_pos;
					out_normal = normal;
					out_tangent = vec4(tangent_xyz, tangent_w >= 0.0 ? 1.0 : -1.0);
					out_uv = uv;
					out_texture_blend = texture_blend;
					out_vertex_color = vertex_color;
					gl_Position = gbuffer_data.projection * gbuffer_data.view * vec4(world_pos, 1.0);
				}
		]]
		return str
	end

	local fragment = [[
		void main() {
			mat3 tbn = get_tbn();
			float alpha = get_alpha_uv(in_uv);
			compute_translucency_and_discard(alpha);

			set_alpha(alpha);
			set_albedo(get_albedo_world(in_uv, in_position));
			set_normal(get_normal(in_uv, tbn));
			set_transmission_view_dep(get_transmission_view_dependency());
			set_metallic(get_metallic(in_uv));
			set_roughness(get_roughness(in_uv));
			set_ao(get_ao(in_uv));
			set_subsurface(get_subsurface(in_uv));
			set_transmission_blocking(get_transmission_blocking(in_uv));
			set_transmission_blocking_raw(get_transmission_blocking_raw(in_uv));
			set_emissive(get_emissive(in_uv));
		}
	]]
	local fallback = build_base_pass(build_ssdm_fragment_shader("displacement_model"), false)
	local fallback_anim = build_base_pass(build_ssdm_fragment_shader("displacement_model"), true)
	fallback_anim.name = "gbuffer_anim"
	fallback_anim.draw_in_prerender = false
	local instanced = build_instanced_pass(build_ssdm_fragment_shader("displacement_model"))
	local pass = build_base_pass(fragment, false)
	pass.name = "gbuffer_tess"
	pass.draw_in_prerender = false
	pass.Topology = "patch_list"
	pass.PatchControlPoints = 3
	pass.FrontFace = orientation.FRONT_FACE
	local pass_anim = build_base_pass(fragment, true)
	pass_anim.name = "gbuffer_tess_anim"
	pass_anim.draw_in_prerender = false
	pass_anim.Topology = "patch_list"
	pass_anim.PatchControlPoints = 3
	pass_anim.FrontFace = orientation.FRONT_FACE
	pass.tessellation_control = {
		uniform_buffers = {
			{
				name = "gbuffer_data",
				binding_index = 3,
				upload_scope = "frame",
				block = {
					render3d.camera_block,
					render3d.debug_block,
				},
				write = render3d.WriteCameraDebugBlock,
			},
			{
				name = "model",
				upload_scope = "frame_keyed",
				upload_key = render3d.GetMaterialUploadKey,
				block = model_pipeline.GetPBRMaterialBlock(),
				write = model_pipeline.WritePBRMaterialBlock,
			},
			{
				name = "displacement_model",
				upload_scope = "frame_keyed",
				upload_key = model_pipeline.GetPBRDisplacementUploadKey,
				block = model_pipeline.GetPBRDisplacementMaterialBlock(),
				write = model_pipeline.WritePBRDisplacementMaterialBlock,
			},
		},
		shader = Material.BuildGlslFlags("model.Flags") .. [[
			bool has_heightmap() {
				return displacement_model.HeightTexture != -1 && displacement_model.HeightScale > 0.0;
			}

			bool use_tessellated_displacement() {
				return has_heightmap() && displacement_model.TessellationFactor > 1.0;
			}

			float get_tessellation_factor() {
				return clamp(displacement_model.TessellationFactor, 1.0, 64.0);
			}

			float get_edge_tessellation(vec3 a, vec3 b, float max_tess) {
				vec4 clip_a = gbuffer_data.projection * gbuffer_data.view * vec4(a, 1.0);
				vec4 clip_b = gbuffer_data.projection * gbuffer_data.view * vec4(b, 1.0);
				float inv_w_a = 1.0 / max(abs(clip_a.w), 0.0001);
				float inv_w_b = 1.0 / max(abs(clip_b.w), 0.0001);
				vec2 ndc_a = clip_a.xy * inv_w_a;
				vec2 ndc_b = clip_b.xy * inv_w_b;
				vec2 edge_pixels = (ndc_b - ndc_a) * 0.5 * gbuffer_data.render_size;
				float projected_length = max(length(edge_pixels), 0.0001);
				float displacement_boost = clamp(1.0 + displacement_model.HeightScale * 48.0, 1.0, 4.0);
				float target_segment_pixels = 5.0 / displacement_boost;
				float tess = projected_length / max(target_segment_pixels, 1.0);
				return clamp(tess, 1.0, max_tess);
			}

			layout(vertices = 3) out;

			void main() {
				out_position[gl_InvocationID] = in_position[gl_InvocationID];
				out_normal[gl_InvocationID] = in_normal[gl_InvocationID];
				out_tangent[gl_InvocationID] = in_tangent[gl_InvocationID];
				out_uv[gl_InvocationID] = in_uv[gl_InvocationID];
				out_texture_blend[gl_InvocationID] = in_texture_blend[gl_InvocationID];
				out_vertex_color[gl_InvocationID] = in_vertex_color[gl_InvocationID];
				gl_out[gl_InvocationID].gl_Position = gl_in[gl_InvocationID].gl_Position;

				if (gl_InvocationID == 0) {
					float max_tess = use_tessellated_displacement() ? get_tessellation_factor() : 1.0;
					float edge0 = get_edge_tessellation(in_position[1], in_position[2], max_tess);
					float edge1 = get_edge_tessellation(in_position[2], in_position[0], max_tess);
					float edge2 = get_edge_tessellation(in_position[0], in_position[1], max_tess);
					float inner = clamp((edge0 + edge1 + edge2) / 3.0, 1.0, max_tess);
					gl_TessLevelOuter[0] = edge0;
					gl_TessLevelOuter[1] = edge1;
					gl_TessLevelOuter[2] = edge2;
					gl_TessLevelInner[0] = inner;
				}
			}
	]],
	}
	pass.tessellation_evaluation = {
		uniform_buffers = {
			{
				name = "gbuffer_data",
				binding_index = 3,
				upload_scope = "frame",
				block = {
					render3d.camera_block,
					render3d.debug_block,
				},
				write = render3d.WriteCameraDebugBlock,
			},
			{
				name = "model",
				upload_scope = "frame_keyed",
				upload_key = render3d.GetMaterialUploadKey,
				block = model_pipeline.GetPBRMaterialBlock(),
				write = model_pipeline.WritePBRMaterialBlock,
			},
			{
				name = "displacement_model",
				upload_scope = "frame_keyed",
				upload_key = model_pipeline.GetPBRDisplacementUploadKey,
				block = model_pipeline.GetPBRDisplacementMaterialBlock(),
				write = model_pipeline.WritePBRDisplacementMaterialBlock,
			},
		},
		shader = build_tessellation_evaluation_shader(false, "displacement_model"),
		outputs = {
			{"position", "vec3"},
			{"normal", "vec3"},
			{"tangent", "vec4"},
			{"uv", "vec2"},
			{"texture_blend", "float"},
			{"vertex_color", "vec4"},
		},
	}
	pass_anim.tessellation_control = pass.tessellation_control
	pass_anim.tessellation_evaluation = {
		uniform_buffers = {
			{
				name = "gbuffer_data",
				binding_index = 3,
				upload_scope = "frame",
				block = {
					render3d.camera_block,
					render3d.debug_block,
				},
				write = render3d.WriteCameraDebugBlock,
			},
			{
				name = "model",
				upload_scope = "frame_keyed",
				upload_key = render3d.GetMaterialUploadKey,
				block = model_pipeline.GetPBRMaterialBlock(),
				write = model_pipeline.WritePBRMaterialBlock,
			},
			{
				name = "displacement_model",
				upload_scope = "frame_keyed",
				upload_key = model_pipeline.GetPBRDisplacementUploadKey,
				block = model_pipeline.GetPBRDisplacementMaterialBlock(),
				write = model_pipeline.WritePBRDisplacementMaterialBlock,
			},
			{
				name = "vertex_animation",
				upload_scope = "frame_keyed",
				upload_key = model_pipeline.GetVertexAnimationUploadKey,
				block = model_pipeline.GetVertexAnimationBlock(),
				write = model_pipeline.WriteVertexAnimationBlock,
			},
		},
		shader = build_tessellation_evaluation_shader(true, "displacement_model"),
		outputs = {
			{"position", "vec3"},
			{"normal", "vec3"},
			{"tangent", "vec4"},
			{"uv", "vec2"},
			{"texture_blend", "float"},
			{"vertex_color", "vec4"},
		},
	}
	return {fallback, fallback_anim, instanced, pass, pass_anim}
end

local fallback = build_base_pass(build_ssdm_fragment_shader("displacement_model"), false)
local fallback_anim = build_base_pass(build_ssdm_fragment_shader("displacement_model"), true)
fallback_anim.name = "gbuffer_anim"
fallback_anim.draw_in_prerender = false
local instanced = build_instanced_pass(build_ssdm_fragment_shader("displacement_model"))
return {fallback, fallback_anim, instanced}
