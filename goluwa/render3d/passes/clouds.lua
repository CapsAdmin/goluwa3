local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local CLOUD_PREP_SIZE = 512
local get_primary_sun_direction = directional_shadows.GetPrimarySunDirection

if not render.clouds then return {} end

local cloud_map_glsl = [[
	const float CLOUD_PREP_WORLD_HALF = 120.0;
	const float CLOUD_PREP_TEX_SIZE = ]] .. CLOUD_PREP_SIZE .. [[.0;

	vec2 get_cloud_prep_origin(vec3 camera_position_meters) {
		float texel_world = (2.0 * CLOUD_PREP_WORLD_HALF) / CLOUD_PREP_TEX_SIZE;
		vec2 camera_km = camera_position_meters.xz * 0.001;
		return floor(camera_km / texel_world) * texel_world;
	}

	vec2 get_cloud_prep_uv_from_world_km(vec2 world_xz_km, vec3 camera_position_meters) {
		vec2 origin = get_cloud_prep_origin(camera_position_meters);
		return (world_xz_km - origin) / (2.0 * CLOUD_PREP_WORLD_HALF) + 0.5;
	}

	vec2 get_cloud_prep_uv_from_world_m(vec2 world_xz_meters, vec3 camera_position_meters) {
		return get_cloud_prep_uv_from_world_km(world_xz_meters * 0.001, camera_position_meters);
	}

	vec2 get_cloud_prep_world_from_uv(vec2 uv, vec3 camera_position_meters) {
		vec2 origin = get_cloud_prep_origin(camera_position_meters);
		return origin + (uv - 0.5) * (2.0 * CLOUD_PREP_WORLD_HALF);
	}

	vec3 sample_cloud_prep_km(vec2 world_xz_km, int prep_tex, vec3 camera_position_meters) {
		if (prep_tex == -1) return vec3(0.0, 0.0, 1.0);
		vec2 uv = get_cloud_prep_uv_from_world_km(world_xz_km, camera_position_meters);
		if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return vec3(0.0, 0.0, 1.0);
		return texture(TEXTURE(prep_tex), uv).rgb;
	}

	float sample_cloud_shadow_m(vec3 world_pos_meters, int prep_tex, vec3 camera_position_meters) {
		if (prep_tex == -1) return 1.0;
		vec2 uv = get_cloud_prep_uv_from_world_m(world_pos_meters.xz, camera_position_meters);
		if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
		return texture(TEXTURE(prep_tex), uv).b;
	}
]]
return {
	{
		name = "cloud_prep",
		FramebufferSize = {x = CLOUD_PREP_SIZE, y = CLOUD_PREP_SIZE},
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "cloud_prep_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						render3d.common_block,
						{"blue_noise_tex", "int"},
						{"sun_direction", "vec4"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						render3d.WriteCommonBlock(self, block)
						block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
						get_primary_sun_direction(render3d.GetLights()):CopyToFloatPointer(block.sun_direction)
						return block
					end,
				},
			},
			custom_declarations = atmosphere.GetAerialPerspectiveGLSLCode() .. cloud_map_glsl,
			shader = [[
				vec3 get_sun_direction() {
					vec3 sun_dir = cloud_prep_data.sun_direction.xyz;
					if (length(sun_dir) < 0.0001) sun_dir = vec3(0.0, 1.0, 0.0);
					return normalize(sun_dir);
				}

				void main() {
					vec3 sun_dir = get_sun_direction();
					CloudsParameters params = get_clouds_parameters(sun_dir);
					vec2 world_xz = get_cloud_prep_world_from_uv(in_uv, cloud_prep_data.camera_position.xyz);
					vec3 cumulus_point = vec3(world_xz.x, PLANET_RADIUS + 0.5 * (CLOUD_CUMULUS_BASE_HEIGHT + CLOUD_CUMULUS_TOP_HEIGHT), world_xz.y);
					vec3 alto_point = vec3(world_xz.x, PLANET_RADIUS + 0.5 * (CLOUD_ALTO_BASE_HEIGHT + CLOUD_ALTO_TOP_HEIGHT), world_xz.y);
					float cumulus = clouds_cumulus_density(cumulus_point, cloud_prep_data.time, cloud_prep_data.blue_noise_tex, params);
					float alto = clouds_altocumulus_density(alto_point, cloud_prep_data.time, cloud_prep_data.blue_noise_tex, params);
					float shadow = 1.0;
					float shadow_density = max(cumulus, alto * 0.6);
					if (shadow_density > 1e-4) {
						shadow = get_cloud_shadow_visibility(cumulus_point, cumulus_point, normalize(cumulus_point), sun_dir, cloud_prep_data.time, cloud_prep_data.blue_noise_tex);
					}
					set_color(vec4(cumulus, alto, shadow, 1.0));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "clouds",
		scale = 1.0,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r16g16_sfloat", {"data", "rg"}},
		},
		fragment = {
			uniform_buffers = {
				{
					name = "clouds_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						render3d.common_block,
						{"blue_noise_tex", "int"},
						{"depth_tex", "int"},
						{"cloud_prep_tex", "int"},
						{"sun_direction", "vec4"},
						{"atmosphere_transmittance_texture_index", "int"},
						{"atmosphere_sky_view_texture_index", "int"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						render3d.WriteCommonBlock(self, block)
						block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
						block.depth_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
						block.cloud_prep_tex = self:GetTextureIndex(render3d.pipelines.cloud_prep:GetFramebuffer():GetAttachment(1))
						block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
						block.atmosphere_sky_view_texture_index = self:GetTextureIndex(
							atmosphere.GetSkyViewTexture(render3d.GetCamera():GetPosition(), get_primary_sun_direction(render3d.GetLights()))
						)
						get_primary_sun_direction(render3d.GetLights()):CopyToFloatPointer(block.sun_direction)
						return block
					end,
				},
			},
			custom_declarations = atmosphere.GetGLSLCode() .. cloud_map_glsl,
			shader = screen_reconstruct.GetViewRayFromUVGLSL("clouds_data") .. [[
				vec3 get_clouds_sun_direction() {
					vec3 sun_dir = clouds_data.sun_direction.xyz;
					if (length(sun_dir) < 0.0001) sun_dir = vec3(0.0, 1.0, 0.0);
					return normalize(sun_dir);
				}

				void main() {
					vec3 ray_dir = get_view_ray(in_uv);
					vec3 sun_dir = get_clouds_sun_direction();
					vec3 camera_origin = get_atmosphere_camera_origin(clouds_data.camera_position.xyz);
					vec3 up = normalize(camera_origin);
					float horizon = dot(ray_dir, up);
					float horizon_fade = smoothstep(-0.01, 0.05, horizon);

					if (horizon_fade <= 1e-4 || ray_hits_planet(ray_dir, clouds_data.camera_position.xyz)) {
						set_color(vec4(0.0, 0.0, 0.0, 1.0));
						set_data(vec2(1e6, 0.0));
						return;
					}

					vec3 clear_sky = sample_sky_view_lut(clouds_data.atmosphere_sky_view_texture_index, ray_dir, sun_dir, clouds_data.camera_position.xyz);
					clear_sky += get_sun_disc(ray_dir, sun_dir, clouds_data.camera_position.xyz, clouds_data.atmosphere_transmittance_texture_index);
					CloudsResult result = draw_clouds(camera_origin, ray_dir, clear_sky, sun_dir, clouds_data.time, clouds_data.blue_noise_tex);
					if (result.apparent_distance < 1e5) {
						vec3 cloud_point = camera_origin + ray_dir * result.apparent_distance;
						vec3 prep = sample_cloud_prep_km(cloud_point.xz, clouds_data.cloud_prep_tex, clouds_data.camera_position.xyz);
						float prep_weight = clamp(max(prep.r, prep.g), 0.0, 1.0);
						result.scattering *= mix(0.85, 1.15, prep_weight);
						result.transmittance = mix(1.0, result.transmittance, smoothstep(0.02, 0.35, prep_weight));
					}
					result.scattering *= horizon_fade;
					result.transmittance = mix(1.0, result.transmittance, horizon_fade);
					set_color(vec4(result.scattering, result.transmittance));
					set_data(vec2(result.apparent_distance, 0.0));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "clouds_resolve",
		framebuffer_count = 2,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r16g16_sfloat", {"data", "rg"}},
		},
		fragment = {
			uniform_buffers = {
				{
					name = "clouds_resolve_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{"current_cloud_tex", "int"},
						{"current_cloud_data_tex", "int"},
						{"history_cloud_tex", "int"},
						{"history_cloud_data_tex", "int"},
						{"depth_tex", "int"},
						{"prev_view", "mat4"},
						{"prev_projection", "mat4"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						block.current_cloud_tex = self:GetTextureIndex(render3d.pipelines.clouds:GetFramebuffer():GetAttachment(1))
						block.current_cloud_data_tex = self:GetTextureIndex(render3d.pipelines.clouds:GetFramebuffer():GetAttachment(2))
						block.depth_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())

						if
							not render3d.pipelines.clouds_resolve or
							not render3d.pipelines.clouds_resolve.framebuffers
						then
							block.history_cloud_tex = -1
							block.history_cloud_data_tex = -1
						else
							local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
							block.history_cloud_tex = self:GetTextureIndex(render3d.pipelines.clouds_resolve:GetFramebuffer(prev_idx):GetAttachment(1))
							block.history_cloud_data_tex = self:GetTextureIndex(render3d.pipelines.clouds_resolve:GetFramebuffer(prev_idx):GetAttachment(2))
						end

						local prev_view = render3d.prev_view_matrix
						local prev_projection = render3d.prev_projection_matrix

						if prev_view then
							prev_view:CopyToFloatPointer(block.prev_view)
						else
							render3d.camera:BuildViewMatrix():CopyToFloatPointer(block.prev_view)
						end

						if prev_projection then
							prev_projection:CopyToFloatPointer(block.prev_projection)
						else
							render3d.camera:BuildProjectionMatrix():CopyToFloatPointer(block.prev_projection)
						end

						return block
					end,
				},
			},
			shader = screen_reconstruct.GetWorldPosFromUVGLSL("clouds_resolve_data") .. [[
				vec4 get_current_cloud(vec2 uv) {
					if (clouds_resolve_data.current_cloud_tex == -1) return vec4(0.0, 0.0, 0.0, 1.0);
					return texture(TEXTURE(clouds_resolve_data.current_cloud_tex), uv);
				}

				vec2 get_current_cloud_data(vec2 uv) {
					if (clouds_resolve_data.current_cloud_data_tex == -1) return vec2(1e6, 0.0);
					return texture(TEXTURE(clouds_resolve_data.current_cloud_data_tex), uv).rg;
				}

				vec4 get_history_cloud(vec2 uv) {
					if (clouds_resolve_data.history_cloud_tex == -1) return vec4(0.0, 0.0, 0.0, 1.0);
					return texture(TEXTURE(clouds_resolve_data.history_cloud_tex), uv);
				}

				vec2 get_history_cloud_data(vec2 uv) {
					if (clouds_resolve_data.history_cloud_data_tex == -1) return vec2(1e6, 0.0);
					return texture(TEXTURE(clouds_resolve_data.history_cloud_data_tex), uv).rg;
				}

				void main() {
					vec4 current = get_current_cloud(in_uv);
					vec2 current_data = get_current_cloud_data(in_uv);

					if (clouds_resolve_data.history_cloud_tex == -1) {
						set_color(current);
						set_data(current_data);
						return;
					}

					float depth = texture(TEXTURE(clouds_resolve_data.depth_tex), in_uv).r;
					vec2 prev_uv = in_uv;

					if (depth < 1.0) {
						vec3 world_pos = get_world_pos(in_uv, depth);
						vec4 prev_view_pos = clouds_resolve_data.prev_view * vec4(world_pos, 1.0);
						vec4 prev_clip = clouds_resolve_data.prev_projection * prev_view_pos;
						prev_uv = (prev_clip.xy / prev_clip.w) * 0.5 + 0.5;
					}

					if (prev_uv.x < 0.0 || prev_uv.x > 1.0 || prev_uv.y < 0.0 || prev_uv.y > 1.0) {
						set_color(current);
						set_data(current_data);
						return;
					}

					vec4 history = get_history_cloud(prev_uv);
					vec2 history_data = get_history_cloud_data(prev_uv);
					vec3 m1 = vec3(0.0);
					vec3 m2 = vec3(0.0);
					float sample_count = 0.0;
					vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(clouds_resolve_data.current_cloud_tex), 0));

					for (int y = -1; y <= 1; y++) {
						for (int x = -1; x <= 1; x++) {
							vec4 sample_color = get_current_cloud(in_uv + vec2(x, y) * texel_size);
							m1 += sample_color.rgb;
							m2 += sample_color.rgb * sample_color.rgb;
							sample_count += 1.0;
						}
					}

					m1 /= max(sample_count, 1.0);
					m2 /= max(sample_count, 1.0);
					vec3 sigma = sqrt(max(vec3(0.0), m2 - m1 * m1));
					vec3 clamped_history_rgb = clamp(history.rgb, m1 - sigma * 1.25, m1 + sigma * 1.25);
					float clamp_diff = length(history.rgb - clamped_history_rgb);
					float distance_agreement = 1.0 - smoothstep(0.05, 0.25, abs(history_data.x - current_data.x));
					float transmittance_agreement = 1.0 - smoothstep(0.03, 0.18, abs(history.a - current.a));
					float blend = 0.65 * distance_agreement * transmittance_agreement;
					if (current_data.x > 9e5 || depth == 1.0) {
						blend *= 0.5;
					}
					blend *= 1.0 - clamp(clamp_diff * 2.0, 0.0, 1.0);
					blend = clamp(blend, 0.0, 0.65);

					set_color(vec4(mix(current.rgb, clamped_history_rgb, blend), mix(current.a, history.a, blend)));
					set_data(mix(current_data, history_data, blend));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "clouds_composite",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "clouds_composite_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{"source_tex", "int"},
						{"cloud_tex", "int"},
						{"cloud_data_tex", "int"},
						{"depth_tex", "int"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						block.source_tex = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1))
						block.cloud_tex = self:GetTextureIndex(render3d.pipelines.clouds_resolve:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1))
						block.cloud_data_tex = self:GetTextureIndex(render3d.pipelines.clouds_resolve:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(2))
						block.depth_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
						return block
					end,
				},
			},
			shader = screen_reconstruct.GetWorldPosFromUVGLSL("clouds_composite_data") .. [[
				void main() {
					if (clouds_composite_data.source_tex == -1 || clouds_composite_data.cloud_tex == -1) {
						set_color(vec4(0.0, 0.0, 0.0, 1.0));
						return;
					}

					vec4 scene = texture(TEXTURE(clouds_composite_data.source_tex), in_uv);
					vec4 clouds = texture(TEXTURE(clouds_composite_data.cloud_tex), in_uv);
					float cloud_distance = texture(TEXTURE(clouds_composite_data.cloud_data_tex), in_uv).r;
					float depth = texture(TEXTURE(clouds_composite_data.depth_tex), in_uv).r;
					bool apply_clouds = depth == 1.0;

					if (!apply_clouds) {
						vec3 world_pos = get_world_pos(in_uv, depth);
						float view_distance = length(world_pos - clouds_composite_data.camera_position.xyz) * 0.001;
						apply_clouds = cloud_distance < view_distance;
					}

					vec3 color = scene.rgb;
					if (apply_clouds) {
						color = scene.rgb * clouds.a + clouds.rgb;
					}

					set_color(vec4(color, scene.a));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
