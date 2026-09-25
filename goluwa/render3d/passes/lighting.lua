local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local surface_lighting = import("goluwa/render3d/surface_lighting.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local BINDING_OUTPUT = 0
local BINDING_UNIFORM = 3
local BINDING_OCCLUSION_MAP = 4
local BINDING_LIGHT_GRID = 5
local BINDING_SCENE = 6
local RAY_QUERY = render.GetDevice().ray_query_supported
-- how many texels of the cascade in use the sun's contact ray reaches, past
-- the few its lookup offsets skip
local SHADOW_CONTACT_TEXELS = 8

local function resolve_lighting_frame_index(self, frame_index)
	local descriptor_set_count = self.pipeline.descriptor_sets and #self.pipeline.descriptor_sets or 0

	if descriptor_set_count > 0 then
		return math.clamp(render.GetCurrentFrame() or frame_index or 1, 1, descriptor_set_count)
	end

	if frame_index then return frame_index end

	if self.framebuffers and #self.framebuffers > 0 then
		return system.GetFrameNumber() % #self.framebuffers + 1
	end

	return 1
end

return {
	{
		name = "lighting",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
		},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = BINDING_OUTPUT,
				attachment = 1,
				dst_stage = "fragment",
			},
		},
		storage_buffers = {{binding_index = BINDING_LIGHT_GRID}},
		descriptor_sets = RAY_QUERY and
			{
				{
					type = "acceleration_structure_khr",
					binding_index = BINDING_SCENE,
					stageFlags = "compute",
				},
			} or
			nil,
		on_pre_draw = function(self, cmd, frame, desc)
			light_occlusion.Draw(cmd)
			light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)

			if RAY_QUERY then
				self:UpdateDescriptorSet(
					"acceleration_structure_khr",
					desc,
					BINDING_SCENE,
					0,
					scene_bvh.EnsureRTBuilt(cmd) or scene_bvh.GetPlaceholderTLAS(cmd)
				)
			end
		end,
		sampled_images = {
			{
				binding_index = BINDING_OCCLUSION_MAP,
				get_texture = function()
					return light_occlusion.GetOcclusionTexture()
				end,
			},
		},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = BINDING_UNIFORM,
				block = {
					surface_lighting.block,
					render3d.gbuffer_block,
					render3d.last_frame_block,
					-- the lighting shader reads its GI from gi_screen_tex, not
					-- from the probe cascades, so gi_debug is the only field of
					-- the voxel gi block it ever touched
					{"gi_debug", "int"},
					{"ssr_tex", "int"},
					{"ambient_occlusion_tex", "int"},
					{"gi_overlay_tex", "int"},
				},
				write = function(self, block)
					surface_lighting.WriteBlock(self, block)
					render3d.WriteGBufferBlock(self, block)
					render3d.WriteLastFrameBlock(self, block)
					block.gi_debug = voxel_gi.debug_mode or 0

					if render3d.pipelines.ambient_occlusion_blur then
						block.ambient_occlusion_tex = self:GetTextureIndex(render3d.pipelines.ambient_occlusion_blur:GetFramebuffer(1):GetAttachment(1))
					else
						block.ambient_occlusion_tex = -1
					end

					local gi_provider = render3d.GetGIProvider()
					local overlay = gi_provider and gi_provider.GetDebugOverlayTexture() or nil
					block.gi_overlay_tex = overlay and self:GetTextureIndex(overlay) or -1

					if render3d.pipelines.ssr then
						local current_idx = system.GetFrameNumber() % 2 + 1
						local current_ssr_fb = render3d.pipelines.ssr:GetFramebuffer(current_idx)
						block.ssr_tex = self:GetTextureIndex(current_ssr_fb:GetAttachment(1))
					else
						block.ssr_tex = -1
					end

					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
			]] .. surface_lighting.GetDeclarationGLSL(BINDING_LIGHT_GRID, BINDING_OCCLUSION_MAP) .. (
				RAY_QUERY and
				[[
			#extension GL_EXT_ray_query : require
			#define SHADOW_CONTACT_RAYS
			#define SHADOW_CONTACT_TEXELS ]] .. string.format("%.1f", SHADOW_CONTACT_TEXELS) .. [[

			layout(set = 0, binding = ]] .. BINDING_SCENE .. [[) uniform accelerationStructureEXT shadow_scene;

			float shadow_contact_visibility(vec3 world_pos, vec3 normal, vec3 light_dir, float reach) {
				rayQueryEXT query;
				// off the surface by more than depth reconstruction's error,
				// which grows with distance like the cascades' texels
				vec3 origin = world_pos + normal * (0.01 + 0.05 * reach);
				rayQueryInitializeEXT(query, shadow_scene, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, 0xFF, origin, 0.0, light_dir, reach);

				while (rayQueryProceedEXT(query)) {}

				return rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT ? 1.0 : 0.0;
			}
		]] or
				""
			),
		shader = (
				"const int LIGHT_DEBUG_DIRECT = %d;\n"
			):format(os.getenv("FOG_DEBUG") == "lighting" and 1 or 0) .. [[
			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			vec2 get_compute_uv() {
				return get_screen_uv(get_screen_pos(), imageSize(out_color));
			}

			vec2 in_uv;

			void set_color(vec4 value) {
				if (lighting_data.gi_overlay_tex >= 0) {
					vec4 overlay = texture(TEXTURE(lighting_data.gi_overlay_tex), in_uv);
					value.rgb = mix(value.rgb, overlay.rgb, overlay.a);
				}

				imageStore(out_color, get_screen_pos(), value);
			}

			vec3 get_albedo() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).rgb;
			}

			float get_alpha() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).a;
			}

			float get_depth() {
				return texture(TEXTURE(lighting_data.depth_tex), in_uv).r;
			}

			vec3 get_normal() {
				return texture(TEXTURE(lighting_data.normal_tex), in_uv).xyz * 2.0 - 1.0;
			}

			float get_transmission_view_dependency() {
				return texture(TEXTURE(lighting_data.transmission_tex), in_uv).g;
			}

			// the gbuffer holds SpecularMultiplier * 0.5; a multiplier of 1 is F0 0.04
			float get_dielectric_f0() {
				return texture(TEXTURE(lighting_data.transmission_tex), in_uv).b * 0.08;
			}

			float get_metallic() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.r;
			}

			float get_roughness() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.g;
			}

			float get_ao() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.b;
			}

			float get_subsurface() {
				return texture(TEXTURE(lighting_data.mra_tex), in_uv).a;
			}

			vec3 get_emissive() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;
			}

			float get_transmission_blocking() {
				return texture(TEXTURE(lighting_data.transmission_tex), in_uv).r;
			}

			vec3 get_transmission_color() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;
			}

			]] .. surface_lighting.GetGLSL("lighting_data") .. [[

			]] .. ibl.GetReflectionGLSLCode("lighting_data") .. [[

			vec3 get_reflection(vec3 normal, float roughness, vec3 V, vec3 world_pos, float sky_visibility, vec3 gi_reflection_fallback) {
				vec3 raw_R = reflect(-V, normal);
				vec3 R = get_specular_dominant_direction(raw_R, normal, roughness);
				vec3 sky_reflection = sample_environment_specular(lighting_data.env_tex, raw_R, normal, roughness);
				vec3 global_reflection = mix(gi_reflection_fallback, sky_reflection, sky_visibility);
				vec3 env_reflection = blend_probe_reflections(global_reflection, R, roughness, world_pos);

				if (lighting_data.ssr_tex == -1) return env_reflection;

				vec4 ssr = get_filtered_ssr_reflection(in_uv);
				return combine_reflections(env_reflection, ssr, get_ssr_blend_weight(roughness));
			}

			vec3 get_gi_irradiance(vec3 N, out float sky_visibility) {
				if (lighting_data.gi_screen_tex < 0) {
					sky_visibility = 1.0;
					return sample_environment_irradiance(lighting_data.env_irradiance_tex, N);
				}

				vec4 gi = texture(TEXTURE(lighting_data.gi_screen_tex), in_uv);
				sky_visibility = gi.a;
				return gi.rgb;
			}

			float get_ambient_occlusion(vec2 uv, vec3 world_pos, vec3 N) {
				if (lighting_data.ambient_occlusion_tex < 0) return 1.0;
				return texture(TEXTURE(lighting_data.ambient_occlusion_tex), uv).r;
			}

			vec3 get_sky() {
				vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, 1.0, 1.0);
				vec4 view_pos = lighting_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (lighting_data.inv_view * view_pos).xyz;
				vec3 sky_dir = normalize(world_pos - lighting_data.camera_position.xyz);
				vec3 sun_dir = get_primary_sun_direction();
				vec3 sky_color_output = vec3(0.0);

				]] .. atmosphere.GetGLSLMainCode("sky_dir", "sun_dir", "lighting_data.camera_position.xyz") .. [[

				return clamp(sky_color_output, vec3(0.0), vec3(65504.0));
			}

			vec3 get_indirect_light(vec3 F0, float NdotV, vec3 albedo, float roughness_alpha, float metallic, float subsurface, float transmission_blocking, vec3 transmission_color, float transmission_view_dependency, vec3 world_pos, vec3 V, vec3 N)
			{
				float subsurface_factor = subsurface;
				float blocking_detail = get_transmission_blocking_detail(transmission_blocking);
				float transmission_amount = 1.0 - blocking_detail;
				float perceptual_roughness = sqrt(clamp(roughness_alpha, 0.0, 1.0));
				float sky_visibility;
				vec3 gi_irradiance = get_gi_irradiance(N, sky_visibility);
				vec3 reflection = get_reflection(N, perceptual_roughness, V, world_pos, sky_visibility, gi_irradiance);
				float ambient_front_amount = blocking_detail;
				// the same tint as direct light passing through
				vec3 ambient_transmission_tint = mix(transmission_color, transmission_color * albedo, blocking_detail);
				float ambient_occlusion = get_ambient_occlusion(in_uv, world_pos, N) * get_ao();

				vec3 irradiance = gi_irradiance;

				vec3 back_irradiance = irradiance;
				vec3 F_ambient = F_SchlickRoughness(F0, NdotV, perceptual_roughness);
				vec3 kD_ambient = (1.0 - F_ambient) * (1.0 - metallic);
				vec3 ambient_diffuse = kD_ambient * irradiance * albedo * ambient_occlusion;
				ambient_diffuse *= mix(1.0, ambient_front_amount, subsurface_factor);
				float hemi = saturate(N.y * 0.5 + 0.5);
				vec3 subsurface_ambient = mix(ambient_diffuse * 0.5, ambient_diffuse, hemi);
				vec3 ambient_subsurface = back_irradiance * ambient_transmission_tint * transmission_amount * ambient_occlusion;
				ambient_subsurface *= mix(0.3, 1.0, transmission_view_dependency);
				subsurface_ambient += ambient_subsurface;

				vec2 envBRDF = texture(TEXTURE(lighting_data.brdf_lut_tex), vec2(NdotV, perceptual_roughness)).rg;

				vec3 ambient_specular = reflection * (F0 * envBRDF.x + envBRDF.y);
				ambient_specular *= GGXEnergyCompensation(F0, envBRDF);
				ambient_specular *= SpecularOcclusion(NdotV, ambient_occlusion, perceptual_roughness);
				ambient_specular *= 1.0 - subsurface_factor;

				vec3 ambient = ambient_diffuse + ambient_specular;
				ambient += (subsurface_ambient - ambient_diffuse) * subsurface_factor;
				return ambient;
			}


			]] .. screen_reconstruct.GetWorldPosGLSL("lighting_data") .. [[

			]] .. screen_reconstruct.GetWorldPosFromUVGLSL("lighting_data", {function_name = "get_world_pos_at"}) .. [[

			]] .. screen_reconstruct.GetGeometricNormalGLSL("lighting_data") .. [[

			vec3 get_view_normal(vec3 world_pos) {
				return normalize(lighting_data.camera_position.xyz - world_pos);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;
				in_uv = get_compute_uv();

				float depth = get_depth();

				if (depth == 1.0) {
					set_color(vec4(get_sky(), 1.0));
					return;
				}

				float alpha = get_alpha();

				if (alpha == 0.0) {
					set_color(vec4(0.0, 0.0, 0.0, 0.0));
					return;
				}

				vec3 world_pos = get_world_pos(depth);
				vec3 V = get_view_normal(world_pos);
				// a normal map can turn a pixel away from the camera; shading it
				// like that zeroes both the diffuse (fresnel -> 1) and the
				// specular (grazing brdf) terms and leaves a black rim
				vec3 N = bend_normal_to_view(get_normal(), V);


				vec3 albedo = get_albedo();
				float metallic = get_metallic();
				float roughness = get_roughness();
				float perceptual_roughness = sqrt(clamp(roughness, 0.0, 1.0));
				float subsurface = get_subsurface();
				float transmission_blocking = get_transmission_blocking();
				vec3 transmission_color = get_transmission_color();
				float transmission_view_dependency = get_transmission_view_dependency();
				vec3 emissive = subsurface > 0.0 ? vec3(0.0) : get_emissive();
				vec3 F0 = mix(vec3(get_dielectric_f0()), albedo, metallic);
				float NdotV = max(dot(N, V), 0.001);
				vec3 direct_specular;
				vec3 direct = get_direct_light(F0, NdotV, albedo, roughness, perceptual_roughness, metallic, subsurface, transmission_blocking, transmission_color, transmission_view_dependency, world_pos, V, N, get_geometric_normal(ivec2(in_uv * vec2(textureSize(TEXTURE(lighting_data.depth_tex), 0))), world_pos, depth, V, N), direct_specular);
				direct += direct_specular;

				if (LIGHT_DEBUG_DIRECT > 0) {
					set_color(vec4(direct, 1.0));
					return;
				}

				vec3 indirect = get_indirect_light(F0, NdotV, albedo, roughness, metallic, subsurface, transmission_blocking, transmission_color, transmission_view_dependency, world_pos, V, N);
				vec3 color = direct + indirect + emissive;

				if (lighting_data.gi_debug != 0) {
					float debug_sky_visibility;
					color = get_gi_irradiance(N, debug_sky_visibility);
				}

				set_color(vec4(min(color, vec3(65504.0)), alpha));
			}
		]],
	},
}
