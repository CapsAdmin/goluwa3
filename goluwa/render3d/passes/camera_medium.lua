local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local glass_light = import("goluwa/render3d/glass_light.lua")
local screen_refraction = import("goluwa/render3d/screen_refraction.lua")
local medium_surface = import("goluwa/render3d/medium_surface.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local medium_common = import("goluwa/render3d/medium_common.lua")
local pvars = import("goluwa/cli/pvars.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local BINDING_OUTPUT = 0
local BINDING_UNIFORM = 3
local GLASS_BINDINGS = {scene = 6, hit = 30, materials = 8}
pvars.StartGroup("Lighting", "Camera medium", {store = false})
local enabled = pvars.Setup2{
	key = "r_camera_medium",
	default = true,
	friendly = "camera inside a medium",
	help = "when the camera is inside a closed body with a medium, every pixel is dimmed and lit by the medium over the path to its wall, as under water. costs one ray query per pixel while the scene has media",
}
pvars.EndGroup()
return {
	{
		name = "camera_medium",
		ComputePass = true,
		is_enabled = function()
			return glass_light.IsEnabled() and enabled:Get() and ddgi.HasBodies()
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {{binding_index = BINDING_OUTPUT, attachment = 1, dst_stage = "fragment"}},
		descriptor_sets = glass_light.RAY_QUERY and
			glass_light.GetDescriptorSets(GLASS_BINDINGS, "compute") or
			nil,
		on_pre_draw = function(self, cmd, frame, desc)
			if glass_light.RAY_QUERY then
				glass_light.Bind(self, cmd, desc, GLASS_BINDINGS)
			end
		end,
		uniform_buffers = {
			{
				name = "camera_medium_data",
				binding_index = BINDING_UNIFORM,
				block = {
					render3d.camera_block,
					render3d.common_block,
					gbuffer_layout.block,
					post_source.pre_exposure_block,
					medium_surface.block,
					{"source_tex", "int"},
					{"env_irradiance_tex", "int"},
					{"sun_direction", "vec3"},
					{"sun_radiance", "vec3"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteCommonBlock(self, block)
					medium_surface.WriteBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					block.source_tex = self:GetTextureIndex(post_source.GetFogSourceTexture())
					block.env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
					local lights = render3d.GetLights()
					directional_shadows.GetPrimarySunDirection(lights):CopyToFloatPointer(block.sun_direction)
					local color = directional_shadows.GetPrimarySunColor(lights) * directional_shadows.GetPrimarySunIlluminance(lights)
					color:CopyToFloatPointer(block.sun_radiance)
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
			]] .. (
				glass_light.RAY_QUERY and
				glass_light.GetDeclarationGLSL(GLASS_BINDINGS) or
				""
			) .. [[
		]],
		shader = glsl_common.GetConstantsGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("camera_medium_data") .. post_source.GetPreExposureGLSL("camera_medium_data") .. screen_refraction.GetGLSL("camera_medium_data") .. ibl.GetEnvironmentGLSLCode() .. medium_common.GetGLSL() .. (
				glass_light.RAY_QUERY and
				glass_light.GetGLSL("glass_light_scene") .. medium_surface.GetGLSL("camera_medium_data") .. medium_surface.GetCausticGLSL(
					"camera_medium_data",
					{
						name = "body_caustic",
						params = "ddgi_material body",
						gradient = "medium_surface_gradient(vec4(body.medium_wave_height, body.medium_wave_length, 0.0, 0.0), vec2(0.0), xz, filter_size, grad, hess);",
					}
				) .. [[
			float get_pixel_footprint(float t) {
				return t * 2.0 / (camera_medium_data.projection[1][1] * camera_medium_data.render_size.y);
			}

			vec3 camera_body_shaft_sample(ddgi_material body, vec3 sun_dir, vec3 attenuation, float mu, vec3 p) {
				vec3 wall_normal;
				float sun_path = get_glass_body_exit(p, sun_dir, ]] .. string.format("%.1f", glass_light.GetMaxDistance()) .. [[, wall_normal);

				if (sun_path <= 0.0) return vec3(0.0);

				vec3 sun_depth = attenuation * sun_path;
				vec3 phase = medium_multiple_scattering(sun_depth, mu, body.medium_g, 0.0, 0.0, 1.0 - dot(exp(-sun_depth), vec3(1.0 / 3.0)));
				float lit = get_medium_sun_visibility(p + sun_dir * (sun_path + 0.02), sun_dir);

				if (body.medium_wave_height > 0.0 && wall_normal.y > 0.5 && sun_dir.y > 0.0) {
					vec3 travel = normalize(vec3(-sun_dir.x / body.medium_ior, -medium_refracted_cosine(sun_dir.y, body.medium_ior), -sun_dir.z / body.medium_ior));
					float footprint = get_pixel_footprint(distance(p, camera_medium_data.camera_position));
					lit *= body_caustic(body, p, footprint, 0, 3.0, false, sun_dir.y * sun_path, travel, body.medium_ior, 0.0, body.medium_caustics).g;
				}

				return phase * lit;
			}

			]] .. medium_common.GetShaftGLSL{
					name = "camera_body_shaft",
					params = "ddgi_material body, vec3 sun_dir, vec3 attenuation, float mu",
					sample = "camera_body_shaft_sample(body, sun_dir, attenuation, mu, p)",
				} .. [[

		struct camera_body_view {
			bool inside;
			vec3 transmittance;
			vec3 inscatter;
			vec3 inside_color;
			float exit_distance;
			vec3 exit_normal;
			float ior;
		};

		camera_body_view get_camera_body_view(vec3 origin, vec3 dir, float distance, vec3 ambient, vec3 sun_dir, vec3 sun_radiance, float jitter) {
			camera_body_view view;
			view.inside = false;
			view.transmittance = vec3(1.0);
			view.inscatter = vec3(0.0);
			view.inside_color = vec3(0.0);
			view.exit_distance = 0.0;
			view.exit_normal = vec3(0.0);
			view.ior = 1.0;

			if (get_optical_header().x + get_optical_header().y == 0) return view;

			float nearest = 0.0;
			uint nearest_instance = 0u;
			uint nearest_primitive = 0u;
			vec2 nearest_barycentrics = vec2(0.0);
			ddgi_material body;
			rayQueryEXT query;
			rayQueryInitializeEXT(query, glass_light_scene, gl_RayFlagsNoneEXT, ]] .. string.format("0x%02X", scene_instances.MASK_GLASS) .. [[, origin, 0.0, dir, min(distance, ]] .. string.format("%.1f", glass_light.GetMaxDistance()) .. [[));

			while (rayQueryProceedEXT(query)) {
				ddgi_material material = ddgi_materials[scene_instance_material(uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)))];

				if ((material.glass == 0 && !ddgi_has_medium(material)) || material.double_sided != 0) continue;

				float t = rayQueryGetIntersectionTEXT(query, false);

				if (nearest == 0.0 || t < nearest) {
					nearest = t;
					view.inside = rayQueryGetIntersectionFrontFaceEXT(query, false);
					nearest_instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false));
					nearest_primitive = uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, false));
					nearest_barycentrics = rayQueryGetIntersectionBarycentricsEXT(query, false);
					body = material;
				}
			}

			if (!view.inside) return view;

			vec3 absorption = body.medium_extinction;
			vec3 scattering = vec3(0.0);
			vec3 wall_light = ambient;

			if (ddgi_has_medium(body)) {
				scattering = medium_scattering_at(body.medium_scattering, body.medium_porous_scattering, body.medium_porosity);
				wall_light *= get_material_medium_transmittance(body);
			} else {
				vec3 through = body.albedo;

				if (body.albedo_tex >= 0) through *= textureLod(TEXTURE(body.albedo_tex), vec2(0.5), 16.0).rgb;

				through *= ]] .. string.format("%.2f", glass_light.TRANSMITTANCE) .. [[;
				through = clamp(body.glass_refraction * through + (1.0 - body.glass_refraction) * (1.0 - body.glass_covering), vec3(0.001), vec3(1.0));
				absorption = -log(through) / max(body.medium_thickness, 0.01);
			}

			vec3 attenuation = absorption + scattering * (1.0 - body.medium_g);
			vec3 reflectance = medium_body_reflectance(absorption, scattering, body.medium_g);
			view.transmittance = optical_transmittance(attenuation, nearest);
			view.inscatter = wall_light * reflectance * (vec3(1.0) - view.transmittance);
			view.inside_color = wall_light * reflectance;
			view.exit_distance = nearest;
			view.ior = body.medium_ior;
			vec3 normal = scene_hit_smooth_normal(nearest_instance, nearest_primitive, nearest_barycentrics);
			view.exit_normal = dot(normal, dir) < 0.0 ? -normal : normal;

			if (body.medium_wave_height > 0.0 && view.exit_normal.y > 0.5) {
				vec2 grad;
				vec3 hess = vec3(0.0);
				medium_surface_gradient(vec4(body.medium_wave_height, body.medium_wave_length, 0.0, 0.0), vec2(0.0), (origin + dir * nearest).xz, get_pixel_footprint(nearest), grad, hess);
				view.exit_normal = normalize(view.exit_normal + vec3(-grad.x, 0.0, -grad.y));
			}

			if (dot(sun_radiance, sun_radiance) > 0.0 && dot(scattering, scattering) > 0.0) {
				view.inscatter += sun_radiance * scattering * camera_body_shaft(body, sun_dir, attenuation, dot(dir, sun_dir), origin, dir, nearest, 8, jitter, attenuation);
			}

			return view;
		}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec2 uv = get_screen_uv(pos, size);
				vec4 scene = texelFetch(TEXTURE(camera_medium_data.source_tex), pos, 0);
				float depth = gbuffer_depth(pos);
				vec4 far_view = camera_medium_data.inv_projection * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
				vec3 view_dir = normalize((camera_medium_data.inv_view * (far_view / far_view.w)).xyz - camera_medium_data.camera_position);
				float distance = 1.0e9;

				if (depth != 0.0) {
					vec4 hit_view = camera_medium_data.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
					distance = length((camera_medium_data.inv_view * (hit_view / hit_view.w)).xyz - camera_medium_data.camera_position);
				}

				vec3 ambient = sample_environment_irradiance(camera_medium_data.env_irradiance_tex, vec3(0.0, 1.0, 0.0)) / PI * get_pre_exposure();
				camera_body_view view = get_camera_body_view(camera_medium_data.camera_position, view_dir, distance, ambient, normalize(camera_medium_data.sun_direction), camera_medium_data.sun_radiance * get_pre_exposure(), fract(52.9829189 * fract(dot(vec2(pos), vec2(0.06711056, 0.00583715))) + camera_medium_data.noise_phase * 0.618034));
				vec3 seen = scene.rgb;

				if (view.inside) {
					if (view.exit_distance < distance) {
						vec3 refracted = refract(view_dir, -view.exit_normal, view.ior);
						bool total = dot(refracted, refracted) < 1e-6;
						float transmitted = total ? 0.0 : 1.0 - fresnel_dielectric(dot(view_dir, view.exit_normal), view.ior);
						vec3 exit_dir = total ? view_dir : normalize(refracted);
						vec3 exit_pos = camera_medium_data.camera_position + view_dir * view.exit_distance;
						vec3 target = screen_refraction_project(exit_pos + exit_dir * min(distance - view.exit_distance, 2000.0));

						if (target.z > -1.0 && screen_refraction_on_screen(target.xy)) {
							seen = texture(TEXTURE(camera_medium_data.source_tex), target.xy).rgb;
						}

						seen = mix(view.inside_color, seen, transmitted);
					}

					seen = seen * view.transmittance + view.inscatter;
				}

				imageStore(out_color, pos, vec4(seen, scene.a));
			}
		]] or
				[[
			void main() {
				ivec2 pos = get_screen_pos();

				if (!is_screen_pos_in_bounds(pos, imageSize(out_color))) return;

				imageStore(out_color, pos, texelFetch(TEXTURE(camera_medium_data.source_tex), pos, 0));
			}
		]]
			),
	},
}
