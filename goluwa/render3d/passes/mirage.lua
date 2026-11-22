local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local screen_refraction = import("goluwa/render3d/screen_refraction.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local mirage = import("goluwa/render3d/mirage.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local SCREEN_EDGE_BLEND = 0.03
local TRACE_REACH = 16
return {
	{
		name = "mirage_heat",
		ComputePass = true,
		is_enabled = mirage.IsActive,
		ColorFormat = {{"r16_sfloat", {"heat", "r"}}},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = {"compute", "fragment"}}},
		uniform_buffers = {
			{
				name = "heat_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					gbuffer_layout.block,
					mirage.block,
					{"water_distance_tex", "int"},
					{"shadows", scene_lights.BuildShadowsBlockLayout()},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					mirage.WriteBlock(self, block)

					if
						render3d.IsWaterEnabled() and
						render3d.IsPassEnabled("water") and
						render3d.pipelines.water.framebuffers
					then
						block.water_distance_tex = self:GetTextureIndex(render3d.pipelines.water:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(2))
					else
						block.water_distance_tex = -1
					end

					scene_lights.WriteShadowBlock(self, block.shadows, render3d.GetLights())
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, r16f) uniform writeonly image2D out_heat;
		]],
		shader = compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("heat_data") .. screen_reconstruct.GetWorldPosFromUVGLSL("heat_data") .. glsl_common.GetSunHorizonVisibilityGLSL() .. directional_shadows.GetMediumDirectionalShadowGLSL("heat_data", "get_mirage_sun_visibility") .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_heat);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				float depth = gbuffer_depth(pos);
				vec3 sun = normalize(heat_data.mirage_sun_direction);
				vec3 normal = gbuffer_geometric_normal(pos);
				float facing = dot(normal, sun);

				if (depth == 0.0 || facing <= 0.0) {
					imageStore(out_heat, pos, vec4(0.0));
					return;
				}

				vec2 uv = get_screen_uv(pos, size);
				vec3 world = get_world_pos(uv, depth);

				if (heat_data.water_distance_tex != -1) {
					float water = textureLod(TEXTURE(heat_data.water_distance_tex), uv, 0.0).b;

					if (water >= 0.0 && water < distance(world, heat_data.camera_position)) {
						imageStore(out_heat, pos, vec4(0.0));
						return;
					}
				}

				float absorbed = (1.0 - luminance(gbuffer_albedo(pos))) * heat_data.mirage_sun_irradiance * facing * get_mirage_sun_visibility(world + normal * (0.05 * heat_data.view_scale), sun);
				imageStore(out_heat, pos, vec4(absorbed * heat_data.mirage_dryness / heat_data.mirage_heat_loss));
			}
		]],
	},
	{
		name = "mirage",
		ComputePass = true,
		is_enabled = mirage.IsActive,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = {"compute", "fragment"}}},
		uniform_buffers = {
			{
				name = "mirage_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					gbuffer_layout.block,
					post_source.pre_exposure_block,
					mirage.block,
					{"source_tex", "int"},
					{"heat_tex", "int"},
					{"env_tex", "int"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					mirage.WriteBlock(self, block)
					block.source_tex = self:GetTextureIndex(post_source.GetFogSourceTexture())
					block.heat_tex = self:GetTextureIndex(post_source.GetMirageHeatTexture())
					block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
		]],
		shader = glsl_common.GetConstantsGLSL() .. glsl_common.GetNoiseGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("mirage_data") .. post_source.GetPreExposureGLSL("mirage_data") .. screen_reconstruct.GetWorldPosFromUVGLSL("mirage_data") .. screen_refraction.GetGLSL("mirage_data") .. ibl.GetEnvironmentGLSLCode() .. mirage.GetGLSL("mirage_data") .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec4 scene = texelFetch(TEXTURE(mirage_data.source_tex), pos, 0);
				float heat = texelFetch(TEXTURE(mirage_data.heat_tex), pos, 0).r;

				if (heat <= 0.0) {
					imageStore(out_color, pos, scene);
					return;
				}

				vec2 uv = get_screen_uv(pos, size);
				vec3 world = get_world_pos(uv, gbuffer_depth(pos));
				vec3 normal = gbuffer_geometric_normal(pos);
				vec3 view_dir = normalize(world - mirage_data.camera_position);
				float grazing = -dot(view_dir, normal);

				if (grazing <= 0.0) {
					imageStore(out_color, pos, scene);
					return;
				}

				vec3 patch_pos = (world - mirage_drift(mirage_convective_velocity(heat))) / (]] .. string.format("%.9g", mirage.PATCH_SIZE) .. [[ * mirage_data.view_scale);
				float critical = mirage_critical_angle(heat * max(1.0 + ]] .. string.format("%.9g", mirage.TEMPERATURE_FLUCTUATION) .. [[ * mirage_noise(patch_pos), 0.0));
				float pixel_angle = 2.0 / (abs(mirage_data.projection[1][1]) * mirage_data.render_size.y);
				float bent = 1.0 - smoothstep(critical - pixel_angle, critical + pixel_angle, asin(min(grazing, 1.0)));

				if (bent <= 0.0) {
					imageStore(out_color, pos, scene);
					return;
				}

				vec3 dir = reflect(view_dir, normal);
				vec3 seen = sample_environment_specular(mirage_data.env_tex, dir, dir, 0.0) * get_pre_exposure();
				vec2 hit_uv;
				float hit_distance;
				float jitter = fract(52.9829189 * fract(dot(vec2(pos), vec2(0.06711056, 0.00583715))) + mirage_data.noise_phase * 0.618034);

				if (screen_refraction_trace(world, world + normal * (0.01 * mirage_data.view_scale), dir, distance(world, mirage_data.camera_position) * ]] .. TRACE_REACH .. [[.0, jitter, hit_uv, hit_distance)) {
					vec2 edge = min(hit_uv, 1.0 - hit_uv);
					seen = mix(seen, texture(TEXTURE(mirage_data.source_tex), hit_uv).rgb, smoothstep(0.0, ]] .. SCREEN_EDGE_BLEND .. [[, min(edge.x, edge.y)));
				}

				imageStore(out_color, pos, vec4(mix(scene.rgb, seen, bent), scene.a));
			}
		]],
	},
}
