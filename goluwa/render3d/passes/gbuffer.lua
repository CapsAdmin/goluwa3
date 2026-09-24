local event = import("goluwa/event.lua")
local Material = import("goluwa/render3d/material.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local commands = import("goluwa/cli/commands.lua")
local camera_block = {
	name = "gbuffer_data",
	binding_index = 3,
	block = {
		render3d.camera_block,
		render3d.prev_camera_block,
	},
	write = function(self, block)
		render3d.WriteCameraBlock(self, block)
		render3d.WritePreviousCameraBlock(self, block)
		return block
	end,
	upload_scope = "frame",
}

commands.Add("velocity_buffer=boolean[true]", function(enabled)
	render3d.SetVelocityEnabled(enabled)
	logf(
		"[gbuffer] velocity buffer %s, consumers %s\n",
		enabled ~= false and "enabled" or "disabled",
		enabled ~= false and
			"follow moving surfaces" or
			"reproject through the previous camera only"
	)
end)

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

			int get_height_layers() {
				return clamp(]] .. displacement_var .. [[.HeightLayers, 4, 64);
			}

			float get_texture_blend_uv(vec2 uv) {
				if (]] .. detail_var .. [[.BlendTexture == -1) {
					return in_texture_blend;
				}

				// source blendmodulate: g is the transition center, r its half width
				vec2 modulate = texture(TEXTURE(]] .. detail_var .. [[.BlendTexture), uv).rg;
				return smoothstep(clamp(modulate.g - modulate.r, 0.0, 1.0), clamp(modulate.g + modulate.r, 0.0, 1.0), in_texture_blend);
			}

			float get_texture_blend() {
				return get_texture_blend_uv(in_uv);
			}

			vec3 get_terrain_world_normal(vec2 uv) {
				if (]] .. model_var .. [[.NormalTexture == -1) {
					return vec3(0.0, 1.0, 0.0);
				}

				vec2 n = texture(TEXTURE(]] .. model_var .. [[.NormalTexture), uv).xy * 2.0 - 1.0;
				return normalize(vec3(n.x, sqrt(max(1.0 - dot(n, n), 0.0)), n.y));
			}

			vec3 get_terrain_triplanar_weights(vec3 normal) {
				vec3 w = pow(abs(normal), vec3(4.0));
				return w / max(w.x + w.y + w.z, 0.0001);
			}

			vec4 sample_terrain_layer_triplanar(int tex, vec3 world_pos, float scale, vec3 blend) {
				float safe_scale = max(scale, 0.0001);
				vec4 result = vec4(0.0);

				if (blend.y > 0.001) {
					result += texture(TEXTURE(tex), world_pos.xz / safe_scale) * blend.y;
				}

				if (blend.x > 0.001) {
					result += texture(TEXTURE(tex), world_pos.zy / safe_scale) * blend.x;
				}

				if (blend.z > 0.001) {
					result += texture(TEXTURE(tex), world_pos.xy / safe_scale) * blend.z;
				}

				return result;
			}

			vec4 sample_terrain_layer_normal_triplanar(int tex, vec3 world_pos, float scale, vec3 blend, vec3 N) {
				float safe_scale = max(scale, 0.0001);
				vec3 n = vec3(0.0);
				float ao = 0.0;

				if (blend.y > 0.001) {
					vec4 t = texture(TEXTURE(tex), world_pos.xz / safe_scale);
					vec3 tn = t.xyz * 2.0 - 1.0;
					tn = vec3(tn.xy + N.xz, abs(tn.z) * N.y);
					n += tn.xzy * blend.y;
					ao += t.a * blend.y;
				}

				if (blend.x > 0.001) {
					vec4 t = texture(TEXTURE(tex), world_pos.zy / safe_scale);
					vec3 tn = t.xyz * 2.0 - 1.0;
					tn = vec3(tn.xy + N.zy, abs(tn.z) * N.x);
					n += tn.zyx * blend.x;
					ao += t.a * blend.x;
				}

				if (blend.z > 0.001) {
					vec4 t = texture(TEXTURE(tex), world_pos.xy / safe_scale);
					vec3 tn = t.xyz * 2.0 - 1.0;
					tn = vec3(tn.xy + N.xy, abs(tn.z) * N.z);
					n += tn.xyz * blend.z;
					ao += t.a * blend.z;
				}

				return vec4(n, ao);
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

			struct TerrainLayerSample {
				vec3 albedo;
				float roughness;
				vec3 normal;
				float ao;
				float normal_weight;
			};

			TerrainLayerSample terrain_layer_cache;
			bool terrain_layer_cache_valid = false;

			void accumulate_terrain_layer(inout TerrainLayerSample s, int albedo_tex, int normal_tex, vec3 world_pos, vec3 blend, vec3 N, float weight, float scale) {
				if (weight <= 0.001) {
					return;
				}

				if (albedo_tex != -1) {
					vec4 albedo = sample_terrain_layer_triplanar(albedo_tex, world_pos, scale, blend);
					s.albedo += albedo.rgb * weight;
					s.roughness += albedo.a * weight;
				} else {
					s.albedo += vec3(weight);
					s.roughness += weight;
				}

				if (normal_tex != -1) {
					vec4 n = sample_terrain_layer_normal_triplanar(normal_tex, world_pos, scale, blend, N);
					s.normal += n.xyz * weight;
					s.ao += n.w * weight;
					s.normal_weight += weight;
				}
			}

			TerrainLayerSample get_terrain_layer_sample(vec2 uv, vec3 world_pos) {
				if (terrain_layer_cache_valid) {
					return terrain_layer_cache;
				}

				TerrainLayerSample s;
				s.albedo = vec3(0.0);
				s.roughness = 0.0;
				s.normal = vec3(0.0);
				s.ao = 0.0;
				s.normal_weight = 0.0;
				vec4 weights = get_terrain_material_weights_uv(uv);
				vec3 N = get_terrain_world_normal(uv);
				vec3 blend = get_terrain_triplanar_weights(N);
				vec4 scales = ]] .. terrain_var .. [[.TerrainLayerScales;
				accumulate_terrain_layer(s, ]] .. terrain_var .. [[.TerrainLayer1Texture, ]] .. terrain_var .. [[.TerrainLayer1NormalTexture, world_pos, blend, N, weights.x, scales.x);
				accumulate_terrain_layer(s, ]] .. terrain_var .. [[.TerrainLayer2Texture, ]] .. terrain_var .. [[.TerrainLayer2NormalTexture, world_pos, blend, N, weights.y, scales.y);
				accumulate_terrain_layer(s, ]] .. terrain_var .. [[.TerrainLayer3Texture, ]] .. terrain_var .. [[.TerrainLayer3NormalTexture, world_pos, blend, N, weights.z, scales.z);
				accumulate_terrain_layer(s, ]] .. terrain_var .. [[.TerrainLayer4Texture, ]] .. terrain_var .. [[.TerrainLayer4NormalTexture, world_pos, blend, N, weights.w, scales.w);

				if (s.normal_weight > 0.001) {
					s.normal = normalize(mix(N, normalize(s.normal), s.normal_weight));
					s.ao = mix(1.0, s.ao / s.normal_weight, s.normal_weight);
				} else {
					s.normal = N;
					s.ao = 1.0;
				}

				terrain_layer_cache = s;
				terrain_layer_cache_valid = true;
				return s;
			}

			vec3 get_terrain_albedo_uv(vec2 uv, vec3 world_pos) {
				vec4 weights = get_terrain_material_weights_uv(uv);

				if (dot(weights, vec4(1.0)) <= 0.0001) {
					return ]] .. color_var .. [[.ColorMultiplier.rgb;
				}

				vec3 color = get_terrain_layer_sample(uv, world_pos).albedo;

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

				if (]] .. detail_var .. [[.DetailTexture != -1) {
					vec2 detail_uv = uv * ]] .. detail_var .. [[.DetailTiling;
					float detail = texture(TEXTURE(]] .. detail_var .. [[.DetailTexture), detail_uv).a + texture(TEXTURE(]] .. detail_var .. [[.DetailTexture), detail_uv * 2.0).a;
					rgb1 = mix(rgb1, rgb1 * detail, ]] .. detail_var .. [[.DetailBlendAmount);
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
			{"b10g11r11_ufloat_pack32", {"normal", "rgb"}},
			{
				"r8g8b8a8_unorm",
				{"metallic", "r"},
				{"roughness", "g"},
				{"ao", "b"},
				{"subsurface", "a"},
			},
			{"b10g11r11_ufloat_pack32", {"emissive", "rgb"}},
			{
				"r8g8b8a8_unorm",
				{"transmission_blocking", "r"},
				{"transmission_view_dep", "g"},
				{"specular", "b"},
			},
			{"r16g16b16a16_sfloat", {"velocity", "rg"}, {"prev_view_depth", "b"}},
		},
		DepthFormat = "d32_sfloat",
		fragment = {
			uniform_buffers = {
				camera_block,
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

					vec3 decode_normal_map(vec2 xy) {
						xy = xy * 2.0 - 1.0;

						if (ReverseXZNormalMap) {
							xy = -xy;
						}

						return vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
					}

					vec3 get_normal_map(vec2 uv) {
						vec3 N = vec3(0.0, 0.0, 1.0);

						if (model.NormalTexture != -1) {
							N = decode_normal_map(texture(TEXTURE(model.NormalTexture), uv).xy);
						} else if (has_heightmap()) {
							N = get_height_normal_tangent(uv);
						}

						if (detail_model.Normal2Texture != -1) {
							float blend = get_texture_blend_uv(uv);

							if (blend != 0) {
								N = normalize(mix(N, decode_normal_map(texture(TEXTURE(detail_model.Normal2Texture), uv).xy), blend));
							}
						}

						// crysis detail bump: two octaves centered on 0.5 offset the normal's slope
						if (detail_model.DetailTexture != -1) {
							vec2 detail_uv = uv * detail_model.DetailTiling;
							vec2 detail = texture(TEXTURE(detail_model.DetailTexture), detail_uv).xy + texture(TEXTURE(detail_model.DetailTexture), detail_uv * 2.0).xy;
							detail = (detail - 1.0) * detail_model.DetailBumpScale;
							N.xy += ReverseXZNormalMap ? -detail : detail;
						}

						return normalize(N);
					}

					vec3 get_combined_normal(vec2 uv, mat3 tbn) {
						vec3 N = tbn * get_normal_map(uv);

						if (DoubleSided && gl_FrontFacing) {
							N = -N;
						}

						return normalize(N);
					}

					vec3 get_normal(vec2 uv, mat3 tbn) {
						vec3 N = get_combined_normal(uv, tbn);

						if (terrain_model.TerrainMaterialTexture != -1) {
							return get_terrain_layer_sample(uv, in_position).normal;
						}

						return N;
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
							val = dot(get_terrain_material_weights_uv(uv), terrain_model.TerrainLayerRoughness) * get_terrain_layer_sample(uv, in_position).roughness;
						} else {
							val = factor_model.RoughnessMultiplier;
							return clamp(val * val, 0.002, 1.0);
						}

						val *= factor_model.RoughnessMultiplier;

						if (InvertRoughnessTexture) val = -val + 1.0;

						// perceptual roughness in, GGX alpha out
						val *= val;
						val = clamp(val, 0.002, 1.0);
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

					]] .. render3d.GetEmissiveGLSL() .. [[

					vec3 get_emissive(vec2 uv) {
						if (Subsurface) {
							return get_transmission_color();
						}

						vec3 emissive = vec3(0.0);

						if (AlbedoAlphaIsEmissive) {
							float mask = 1.0;
							if (model.AlbedoTexture != -1) {
								mask = texture(TEXTURE(model.AlbedoTexture), uv).a;
							}
							emissive = get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
						} else if (aux_model.EmissiveTexture != -1) {
							float mask = texture(TEXTURE(aux_model.EmissiveTexture), uv).r;
							emissive = get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
						} else if (aux_model.MetallicTexture != -1 && MetallicTextureAlphaIsEmissive) {
							float mask = texture(TEXTURE(aux_model.MetallicTexture), uv).a;
							emissive = get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
						} else {
							return vec3(0.0);
						}

						return min(emissive * EMISSIVE_REFERENCE_LUMINANCE, vec3(EMISSIVE_MAX_LUMINANCE));
					}

					// both endpoints go through their own frame's camera, so a still
					// object under a moving camera and a moving object under a still
					// camera come out of the same subtraction. the divide by w is
					// what makes it a screen offset rather than a world one
					vec3 get_screen_velocity(vec3 world_pos, vec3 prev_world_pos) {
						vec4 clip = gbuffer_data.projection * gbuffer_data.view * vec4(world_pos, 1.0);
						vec4 prev_view_pos = gbuffer_data.prev_view * vec4(prev_world_pos, 1.0);
						vec4 prev_clip = gbuffer_data.prev_projection * prev_view_pos;

						// behind the eye either frame there is no honest offset to
						// give, and a reprojection is better off treating the pixel
						// as new than following a mirrored one
						if (clip.w <= 0.0001 || prev_clip.w <= 0.0001) {
							return vec3(0.0, 0.0, -prev_view_pos.z);
						}

						vec2 uv = (clip.xy / clip.w) * 0.5;
						vec2 prev_uv = (prev_clip.xy / prev_clip.w) * 0.5;
						return vec3(uv - prev_uv, -prev_view_pos.z);
					}

					void write_velocity(vec3 world_pos, vec3 prev_world_pos) {
						vec3 motion = get_screen_velocity(world_pos, prev_world_pos);
						set_velocity(motion.xy);
						set_prev_view_depth(motion.z);
					}

					// half the multiplier, so 1 lands mid range and 2 still fits the unorm target
					float get_specular() {
						return clamp(factor_model.SpecularMultiplier * 0.5, 0.0, 1.0);
					}

					float get_ao(vec2 uv) {
						if (aux_model.AmbientOcclusionTexture == -1) {
							if (terrain_model.TerrainMaterialTexture != -1) {
								return dot(get_terrain_material_weights_uv(uv), terrain_model.TerrainLayerAmbientOcclusion) * get_terrain_layer_sample(uv, in_position).ao * aux_model.AmbientOcclusionMultiplier;
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
		ColorWriteMask = "rgba",
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
			velocity = true,
			include_projection_view_world = false,
			camera_uniform_block_name = "gbuffer_data",
			uniform_buffers = {
				camera_block,
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
		velocity = true,
		include_projection_view = false,
		camera_uniform_block_name = "gbuffer_data",
		uniform_buffers = {
			camera_block,
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
			set_normal(get_normal(displacement.uv, tbn) * 0.5 + 0.5);
			set_transmission_view_dep(get_transmission_view_dependency());
			set_metallic(get_metallic(displacement.uv));
			set_roughness(get_roughness(displacement.uv));
			set_ao(get_ao(displacement.uv));
			set_specular(get_specular());
			set_subsurface(get_subsurface(displacement.uv));
			set_transmission_blocking(get_transmission_blocking(displacement.uv));
			set_emissive(get_emissive(displacement.uv));
			// the undisplaced position on both sides. parallax shifts the surface
			// by the same amount in both frames when the view barely changed, so
			// including it would mostly add noise to the offset
			write_velocity(in_position, in_prev_position);
			gl_FragDepth = has_heightmap() ? get_projected_depth(displacement.world_pos) : gl_FragCoord.z;
		}
	]]
end

local fallback = build_base_pass(build_ssdm_fragment_shader("displacement_model"), false)
local fallback_anim = build_base_pass(build_ssdm_fragment_shader("displacement_model"), true)
fallback_anim.name = "gbuffer_anim"
fallback_anim.draw_in_prerender = false
fallback_anim.dont_create_framebuffers = true
local instanced = build_instanced_pass(build_ssdm_fragment_shader("displacement_model"))
return {fallback, fallback_anim, instanced}
