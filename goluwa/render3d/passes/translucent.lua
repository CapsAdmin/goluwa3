local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local surface_lighting = import("goluwa/render3d/surface_lighting.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local BINDING_CAMERA = 3
local BINDING_LIGHT_GRID = 20
local BINDING_OCCLUSION_MAP = 21
-- Translucent materials, which the gbuffer can't hold, drawn forward and lit
-- like the gbuffer's surfaces. The first pass copies the lit opaque scene and
-- its depth into its own target, so the scene stays untouched for the passes
-- that want what is behind the translucent surfaces. Visuals then draw their
-- translucent entries back to front into the copy, depth tested against the
-- opaque depth.
local camera_block = {
	name = "translucent_camera",
	binding_index = BINDING_CAMERA,
	block = {
		render3d.camera_block,
	},
	write = function(self, block)
		return render3d.WriteCameraBlock(self, block)
	end,
	upload_scope = "frame",
}
local surface_uniform_buffers = model_pipeline.GetPBRUniformBuffers()
table.insert(surface_uniform_buffers, 1, camera_block)
table.insert(
	surface_uniform_buffers,
	{
		name = "lighting_data",
		block = {
			surface_lighting.block,
			{"depth_tex", "int"},
		},
		write = function(self, block)
			surface_lighting.WriteBlock(self, block)
			block.depth_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
			return block
		end,
		upload_scope = "frame",
	}
)
return {
	{
		name = "translucent",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		DepthFormat = "d32_sfloat",
		-- the light grid and the occlusion map live as long as the engine, so
		-- each of the surface pipeline's descriptor sets is written once, before
		-- any frame uses it
		on_pre_draw = function(self, cmd)
			local surface = render3d.pipelines.translucent_surface
			-- the set Bind will pick
			local frame = render.GetCurrentFrame()

			if not surface.pipeline.descriptor_sets[frame] then frame = 1 end

			surface.surface_lighting_sets = surface.surface_lighting_sets or {}

			if surface.surface_lighting_sets[frame] then return end

			surface.surface_lighting_sets[frame] = true
			local grid = light_grid.GetBuffer(cmd)
			surface:UpdateDescriptorSet("storage_buffer", frame, BINDING_LIGHT_GRID, 0, grid, grid:GetSize())
			surface:UpdateDescriptorSet(
				"combined_image_sampler",
				frame,
				BINDING_OCCLUSION_MAP,
				0,
				unpack(light_occlusion.GetOcclusionDescriptor())
			)
		end,
		on_draw = function(self, cmd)
			self:UploadConstants()
			cmd:Draw(3, 1, 0, 0)
			event.Call("Draw3DTranslucent")
		end,
		fragment = {
			uniform_buffers = {
				{
					name = "translucent_copy",
					binding_index = 3,
					block = {
						{"scene_tex", "int"},
						{"depth_tex", "int"},
					},
					write = function(self, block)
						block.scene_tex = self:GetTextureIndex(post_source.GetOpaqueSceneTexture())
						block.depth_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
						return block
					end,
				},
			},
			shader = [[
				void main() {
					ivec2 pixel = ivec2(gl_FragCoord.xy);
					set_color(texelFetch(TEXTURE(translucent_copy.scene_tex), pixel, 0));
					gl_FragDepth = texelFetch(TEXTURE(translucent_copy.depth_tex), pixel, 0).r;
				}
			]],
		},
		CullMode = "none",
		DepthTest = true,
		DepthWrite = true,
		DepthCompareOp = "always",
	},
	{
		name = "translucent_surface",
		draw_in_prerender = false,
		dont_create_framebuffers = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		DepthFormat = "d32_sfloat",
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			texture_blend = true,
			vertex_color = true,
			include_projection_view_world = false,
			camera_uniform_block_name = "translucent_camera",
			uniform_buffers = {camera_block},
		},
		fragment = {
			uniform_buffers = surface_uniform_buffers,
			descriptor_sets = {
				{
					type = "storage_buffer",
					binding_index = BINDING_LIGHT_GRID,
					stageFlags = "fragment",
				},
				{
					type = "combined_image_sampler",
					binding_index = BINDING_OCCLUSION_MAP,
					stageFlags = "fragment",
				},
			},
			custom_declarations = surface_lighting.GetDeclarationGLSL(BINDING_LIGHT_GRID, BINDING_OCCLUSION_MAP),
			shader = model_pipeline.BuildPBRSurfaceGlsl() .. surface_lighting.GetGLSL("lighting_data") .. [[
				// the gbuffer's screen space gi, of the opaque surface behind
				// this one. a thin surface sits in about the same light
				vec3 get_gi_irradiance(vec2 screen_uv, vec3 N, out float sky_visibility) {
					bool behind_is_sky = texture(TEXTURE(lighting_data.depth_tex), screen_uv).r >= 1.0;

					if (lighting_data.gi_screen_tex < 0 || behind_is_sky) {
						sky_visibility = 1.0;
						return sample_environment_irradiance(lighting_data.env_irradiance_tex, N);
					}

					vec4 gi = texture(TEXTURE(lighting_data.gi_screen_tex), screen_uv);
					sky_visibility = gi.a;
					return gi.rgb;
				}

				void main() {
					float alpha = get_alpha();

					if (AlphaTest && alpha < factor_model.AlphaCutoff) discard;

					vec2 screen_uv = gl_FragCoord.xy / lighting_data.render_size;
					vec3 world_pos = in_position;
					vec3 V = normalize(lighting_data.camera_position.xyz - world_pos);
					mat3 tbn = get_tbn();
					vec3 N = bend_normal_to_view(get_normal(in_uv, tbn), V);
					vec3 albedo = get_albedo();
					float metallic = get_metallic(in_uv);
					float roughness = get_roughness(in_uv);
					float perceptual_roughness = sqrt(roughness);
					float subsurface = get_subsurface(in_uv);
					vec3 F0 = mix(vec3(get_specular() * 0.08), albedo, metallic);
					float NdotV = max(dot(N, V), 0.001);
					// alpha is how much of the pixel the surface covers, so it
					// scales what the surface itself scatters: its diffuse and
					// emission. reflection comes off the covered and the clear
					// parts alike, but not off texels that hold no surface at all
					vec3 diffuse_albedo = albedo * alpha;
					float specular_coverage = smoothstep(0.0, 0.1, alpha);

					vec3 direct_specular;
					vec3 direct_diffuse = get_direct_light(F0, NdotV, diffuse_albedo, roughness, perceptual_roughness, metallic, subsurface, get_transmission_blocking(in_uv), get_transmission_color(), get_transmission_view_dependency(), world_pos, V, N, get_vertex_normal(), direct_specular);

					float sky_visibility;
					vec3 irradiance = get_gi_irradiance(screen_uv, N, sky_visibility);
					vec3 raw_R = reflect(-V, N);
					vec3 R = get_specular_dominant_direction(raw_R, N, perceptual_roughness);
					vec3 sky_reflection = sample_environment_specular(lighting_data.env_tex, raw_R, N, perceptual_roughness);
					vec3 reflection = blend_probe_reflections(mix(irradiance, sky_reflection, sky_visibility), R, perceptual_roughness, world_pos);
					vec2 env_brdf = texture(TEXTURE(lighting_data.brdf_lut_tex), vec2(NdotV, perceptual_roughness)).rg;
					vec3 F_ambient = F_SchlickRoughness(F0, NdotV, perceptual_roughness);
					vec3 ambient_diffuse = (1.0 - F_ambient) * (1.0 - metallic) * irradiance * diffuse_albedo * get_ao(in_uv);
					vec3 ambient_specular = reflection * (F0 * env_brdf.x + env_brdf.y) * GGXEnergyCompensation(F0, env_brdf);
					vec3 emissive = Subsurface ? vec3(0.0) : get_emissive(in_uv) * alpha;
					vec3 color = direct_diffuse + ambient_diffuse + (direct_specular + ambient_specular) * specular_coverage + emissive;
					set_color(vec4(min(color, vec3(65504.0)), alpha));
				}
			]],
		},
		CullMode = orientation.CULL_MODE,
		FrontFace = orientation.FRONT_FACE,
		Blend = true,
		SrcColorBlendFactor = "one",
		DstColorBlendFactor = "one_minus_src_alpha",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "one_minus_src_alpha",
		AlphaBlendOp = "add",
		DepthTest = true,
		DepthWrite = false,
		DepthCompareOp = "less_or_equal",
	},
}
