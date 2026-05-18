local Vec3 = import("goluwa/structs/vec3.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local ibl = import("goluwa/render3d/ibl.lua")

local WAVE_TEX_SIZE = 512
local WAVE_TEX_WORLD_HALF = 1024.0
local WAVE_NEAR_WORLD_HALF = 64.0

local function get_primary_sun_direction()
	local lights = render3d.GetLights()
	local sun_dir = Vec3(0, 1, 0)

	if lights[1] then
		sun_dir = lights[1].Owner.transform:GetRotation():GetBackward()
	end

	return sun_dir
end

return {
	{
		name = "ocean_waves_near",
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"wave_data", "rgba"}},
		},
		FramebufferSize = {x = WAVE_TEX_SIZE, y = WAVE_TEX_SIZE},
		fragment = {
			uniform_buffers = {
				{
					name = "wave_precompute",
					binding_index = 3,
					block = {
						render3d.common_block,
						{
							"blue_noise_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
							end,
						},
						{
							"wave_origin",
							"vec2",
							function(self, block, key)
								local snap = WAVE_NEAR_WORLD_HALF * 2 / WAVE_TEX_SIZE
								local cam = render3d.camera:GetPosition()
								block[key][0] = math.floor(cam.x / snap) * snap
								block[key][1] = math.floor(cam.z / snap) * snap
							end,
						},
					},
				},
			},
			shader = [[
			const int ITER_WAVE_BAKE = 6;
			const float SEA_HEIGHT = 0.6;
			const float SEA_CHOPPY = 4.0;
			const float SEA_FREQ = 0.16;
			const float SEA_WAVE_AMOUNT = 1.0;
			const mat2 OCTAVE_M = mat2(1.6, 1.2, -1.2, 1.6);
			const float NOISE_SCALE = 1.0;
			const float WAVE_TEX_WORLD_HALF = 64.0;

			ivec2 wrap_noise_coord(ivec2 coord, ivec2 size) {
				return ivec2(
					(coord.x % size.x + size.x) % size.x,
					(coord.y % size.y + size.y) % size.y
				);
			}

			float sample_noise_texel(ivec2 coord, ivec2 size) {
				return texelFetch(TEXTURE(wave_precompute.blue_noise_tex), wrap_noise_coord(coord, size), 0).r;
			}

			float noise(vec2 p) {
				if (wave_precompute.blue_noise_tex == -1) return 0.0;
				ivec2 noise_size = textureSize(TEXTURE(wave_precompute.blue_noise_tex), 0);
				vec2 uv = p * NOISE_SCALE;
				ivec2 i = ivec2(floor(uv));
				vec2 f = fract(uv);
				f = f * f * (3.0 - 2.0 * f);
				return -1.0 + 2.0 * mix(
					mix(sample_noise_texel(i + ivec2(0, 0), noise_size), sample_noise_texel(i + ivec2(1, 0), noise_size), f.x),
					mix(sample_noise_texel(i + ivec2(0, 1), noise_size), sample_noise_texel(i + ivec2(1, 1), noise_size), f.x),
					f.y
				);
			}

			float sea_octave(vec2 uv, float choppy) {
				uv += noise(uv);
				vec2 wv = 1.0 - abs(sin(uv));
				vec2 swv = abs(cos(uv));
				wv = mix(wv, swv, wv);
				return pow(1.0 - pow(wv.x * wv.y, 0.65), choppy);
			}

			float compute_wave_h(vec2 world_xz) {
				float freq = SEA_FREQ;
				float amp = SEA_HEIGHT;
				float choppy = SEA_CHOPPY;
				vec2 uv = world_xz;
				uv.x *= 0.75;
				float h = 0.0;
				float sea_time = 1.0 + wave_precompute.time * 0.8;

				for (int i = 0; i < ITER_WAVE_BAKE; i++) {
					float d = sea_octave((uv + sea_time) * freq, choppy);
					d += sea_octave((uv - sea_time) * freq, choppy);
					h += d * amp;
					uv = OCTAVE_M * uv;
					freq *= 1.9;
					amp *= 0.22;
					choppy = mix(choppy, 1.0, 0.2);
				}

				return h * SEA_WAVE_AMOUNT;
			}

			void main() {
				vec2 world_xz = wave_precompute.wave_origin + (in_uv * 2.0 - 1.0) * WAVE_TEX_WORLD_HALF;
				float h = compute_wave_h(world_xz);
				const float GRAD_EPS = 0.25;
				float dhdx = (compute_wave_h(world_xz + vec2(GRAD_EPS, 0.0)) - h) / GRAD_EPS;
				float dhdz = (compute_wave_h(world_xz + vec2(0.0, GRAD_EPS)) - h) / GRAD_EPS;
				set_wave_data(vec4(h, dhdx, dhdz, 0.0));
			}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "ocean_waves",
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"wave_data", "rgba"}},
		},
		FramebufferSize = {x = WAVE_TEX_SIZE, y = WAVE_TEX_SIZE},
		fragment = {
			uniform_buffers = {
				{
					name = "wave_precompute",
					binding_index = 3,
					block = {
						render3d.common_block,
						{
							"blue_noise_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
							end,
						},
						{
							"wave_origin",
							"vec2",
							function(self, block, key)
								local snap = WAVE_TEX_WORLD_HALF * 2 / WAVE_TEX_SIZE
								local cam = render3d.camera:GetPosition()
								block[key][0] = math.floor(cam.x / snap) * snap
								block[key][1] = math.floor(cam.z / snap) * snap
							end,
						},
					},
				},
			},
			shader = [[
			const int ITER_WAVE_BAKE = 6;
			const float SEA_HEIGHT = 0.6;
			const float SEA_CHOPPY = 4.0;
			const float SEA_FREQ = 0.16;
			const float SEA_WAVE_AMOUNT = 1.0;
			const mat2 OCTAVE_M = mat2(1.6, 1.2, -1.2, 1.6);
			const float NOISE_SCALE = 1.0;
			const float WAVE_TEX_WORLD_HALF = 1024.0;

			ivec2 wrap_noise_coord(ivec2 coord, ivec2 size) {
				return ivec2(
					(coord.x % size.x + size.x) % size.x,
					(coord.y % size.y + size.y) % size.y
				);
			}

			float sample_noise_texel(ivec2 coord, ivec2 size) {
				return texelFetch(TEXTURE(wave_precompute.blue_noise_tex), wrap_noise_coord(coord, size), 0).r;
			}

			float noise(vec2 p) {
				if (wave_precompute.blue_noise_tex == -1) return 0.0;
				ivec2 noise_size = textureSize(TEXTURE(wave_precompute.blue_noise_tex), 0);
				vec2 uv = p * NOISE_SCALE;
				ivec2 i = ivec2(floor(uv));
				vec2 f = fract(uv);
				f = f * f * (3.0 - 2.0 * f);
				return -1.0 + 2.0 * mix(
					mix(sample_noise_texel(i + ivec2(0, 0), noise_size), sample_noise_texel(i + ivec2(1, 0), noise_size), f.x),
					mix(sample_noise_texel(i + ivec2(0, 1), noise_size), sample_noise_texel(i + ivec2(1, 1), noise_size), f.x),
					f.y
				);
			}

			float sea_octave(vec2 uv, float choppy) {
				uv += noise(uv);
				vec2 wv = 1.0 - abs(sin(uv));
				vec2 swv = abs(cos(uv));
				wv = mix(wv, swv, wv);
				return pow(1.0 - pow(wv.x * wv.y, 0.65), choppy);
			}

			float compute_wave_h(vec2 world_xz) {
				float freq = SEA_FREQ;
				float amp = SEA_HEIGHT;
				float choppy = SEA_CHOPPY;
				vec2 uv = world_xz;
				uv.x *= 0.75;
				float h = 0.0;
				float sea_time = 1.0 + wave_precompute.time * 0.8;

				for (int i = 0; i < ITER_WAVE_BAKE; i++) {
					float d = sea_octave((uv + sea_time) * freq, choppy);
					d += sea_octave((uv - sea_time) * freq, choppy);
					h += d * amp;
					uv = OCTAVE_M * uv;
					freq *= 1.9;
					amp *= 0.22;
					choppy = mix(choppy, 1.0, 0.2);
				}

				return h * SEA_WAVE_AMOUNT;
			}

			void main() {
				vec2 world_xz = wave_precompute.wave_origin + (in_uv * 2.0 - 1.0) * WAVE_TEX_WORLD_HALF;
				float h = compute_wave_h(world_xz);
				const float GRAD_EPS = 1.0;
				float dhdx = (compute_wave_h(world_xz + vec2(GRAD_EPS, 0.0)) - h) / GRAD_EPS;
				float dhdz = (compute_wave_h(world_xz + vec2(0.0, GRAD_EPS)) - h) / GRAD_EPS;
				set_wave_data(vec4(h, dhdx, dhdz, 0.0));
			}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "ocean",
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r32_sfloat", {"ocean_distance", "r"}},
		},
		framebuffer_count = 2,
		fragment = {
			uniform_buffers = {
				{
					name = "ocean_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						render3d.common_block,
						{
							"scene_tex",
							"int",
							function(self, block, key)
								if
									not render3d.pipelines.lighting or
									not render3d.pipelines.lighting.framebuffers
								then
									block[key] = -1
									return
								end

								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
							end,
						},
						{
							"depth_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
							end,
						},
						{
							"env_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.GetEnvironmentTexture())
							end,
						},
						{
							"ssr_tex",
							"int",
							function(self, block, key)
								if
									not render3d.pipelines.ssr_resolve or
									not render3d.pipelines.ssr_resolve.framebuffers
								then
									block[key] = -1
									return
								end

								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.ssr_resolve:GetFramebuffer(current_idx):GetAttachment(1))
							end,
						},
						{
							"atmosphere_transmittance_texture_index",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
							end,
						},
						{
							"sun_direction",
							"vec3",
							function(self, block, key)
								get_primary_sun_direction():CopyToFloatPointer(block[key])
							end,
						},
						{
							"ocean_enabled",
							"int",
							function(self, block, key)
								block[key] = render3d.IsOceanEnabled() and 1 or 0
							end,
						},
						{
							"ocean_level",
							"float",
							function(self, block, key)
								block[key] = render3d.GetOceanLevel()
							end,
						},
						{
							"wave_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.ocean_waves then
									block[key] = -1
									return
								end
								block[key] = self:GetTextureIndex(render3d.pipelines.ocean_waves:GetFramebuffer():GetAttachment(1))
							end,
						},
						{
							"wave_origin",
							"vec2",
							function(self, block, key)
								local snap = WAVE_TEX_WORLD_HALF * 2 / WAVE_TEX_SIZE
								local cam = render3d.camera:GetPosition()
								block[key][0] = math.floor(cam.x / snap) * snap
								block[key][1] = math.floor(cam.z / snap) * snap
							end,
						},
						{
							"wave_near_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.ocean_waves_near then
									block[key] = -1
									return
								end
								block[key] = self:GetTextureIndex(render3d.pipelines.ocean_waves_near:GetFramebuffer():GetAttachment(1))
							end,
						},
						{
							"wave_near_origin",
							"vec2",
							function(self, block, key)
								local snap = WAVE_NEAR_WORLD_HALF * 2 / WAVE_TEX_SIZE
								local cam = render3d.camera:GetPosition()
								block[key][0] = math.floor(cam.x / snap) * snap
								block[key][1] = math.floor(cam.z / snap) * snap
							end,
						},
					},
				},
			},
			shader = [[
			vec3 get_scene_color(vec2 uv) {
				if (ocean_data.scene_tex == -1) return vec3(0.0);
				return texture(TEXTURE(ocean_data.scene_tex), uv).rgb;
			}

			vec3 get_environment_color(vec3 dir, float lod) {
				if (ocean_data.env_tex == -1) return vec3(0.0);
				float max_mip = float(textureQueryLevels(CUBEMAP(ocean_data.env_tex)) - 1);
				return textureLod(CUBEMAP(ocean_data.env_tex), dir, clamp(lod, 0.0, max_mip)).rgb;
			}

			const float SEA_PI = 3.14159265359;
			const float SEA_HEIGHT = 0.6;
			const float SEA_WAVE_AMOUNT = 1.0;
			const float SEA_OPTICAL_DEPTH = 4096.0;
			const float WAVE_TEX_WORLD_HALF = 1024.0;
			const float WAVE_NEAR_WORLD_HALF = 64.0;

			float get_scene_depth(vec2 uv) {
				if (ocean_data.depth_tex == -1) return 1.0;
				return texture(TEXTURE(ocean_data.depth_tex), uv).r;
			}

			vec3 get_world_pos(vec2 uv, float depth) {
				vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
				vec4 view_pos = ocean_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				return (ocean_data.inv_view * view_pos).xyz;
			}

			vec3 get_view_ray(vec2 uv) {
				vec4 near_clip_pos = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
				vec4 far_clip_pos = vec4(uv * 2.0 - 1.0, 1.0, 1.0);
				vec4 near_view_pos = ocean_data.inv_projection * near_clip_pos;
				vec4 far_view_pos = ocean_data.inv_projection * far_clip_pos;
				near_view_pos /= near_view_pos.w;
				far_view_pos /= far_view_pos.w;
				vec3 view_dir = far_view_pos.xyz - near_view_pos.xyz;
				return normalize(mat3(ocean_data.inv_view) * view_dir);
			}

			float intersect_ocean_plane(vec3 ray_origin, vec3 ray_dir, float plane_y) {
				float denom = ray_dir.y;
				if (abs(denom) < 1e-5) return -1.0;

				float t = (plane_y - ray_origin.y) / denom;
				return t > 0.0 ? t : -1.0;
			}

			vec4 get_wave_data(vec2 world_xz) {
				vec4 far_data = vec4(0.0);
				if (ocean_data.wave_tex != -1) {
					vec2 far_uv = (world_xz - ocean_data.wave_origin) * (0.5 / WAVE_TEX_WORLD_HALF) + 0.5;
					if (all(greaterThanEqual(far_uv, vec2(0.0))) && all(lessThanEqual(far_uv, vec2(1.0)))) {
						float far_dist = length(world_xz - ocean_data.wave_origin);
						float edge_fade = 1.0 - smoothstep(WAVE_TEX_WORLD_HALF * 0.9, WAVE_TEX_WORLD_HALF, far_dist);
						far_data = texture(TEXTURE(ocean_data.wave_tex), far_uv) * edge_fade;
					}
				}
				if (ocean_data.wave_near_tex == -1) return far_data;
				vec2 near_uv = (world_xz - ocean_data.wave_near_origin) * (0.5 / WAVE_NEAR_WORLD_HALF) + 0.5;
				if (any(lessThan(near_uv, vec2(0.0))) || any(greaterThan(near_uv, vec2(1.0)))) return far_data;
				float near_dist = length(world_xz - ocean_data.wave_near_origin);
				float near_fade = pow(1.0 - smoothstep(WAVE_NEAR_WORLD_HALF - 32.0, WAVE_NEAR_WORLD_HALF, near_dist), 0.25);
				return mix(far_data, texture(TEXTURE(ocean_data.wave_near_tex), near_uv), near_fade);
			}

			float height_map_tracing(vec3 ray_dir, float plane_t, vec3 camera_origin, out vec3 hit_pos) {
				if (ocean_data.wave_tex == -1) {
					hit_pos = ray_dir * plane_t;
					return plane_t;
				}

				float search_radius = clamp(12.0 + abs(ray_dir.y) * 48.0, 8.0, 64.0);
				float tm = max(plane_t - search_radius, 0.0);
				float tx = plane_t + search_radius;

				vec3 pm = ray_dir * tm;
				float hm = (pm.y + camera_origin.y) - (ocean_data.ocean_level + get_wave_data(pm.xz + camera_origin.xz).r);
				vec3 px = ray_dir * tx;
				float hx = (px.y + camera_origin.y) - (ocean_data.ocean_level + get_wave_data(px.xz + camera_origin.xz).r);

				if (hm < 0.0) {
					tm = 0.0;
					hm = camera_origin.y - (ocean_data.ocean_level + get_wave_data(camera_origin.xz).r);
				}

				if (hm * hx > 0.0) return -1.0;

				for (int i = 0; i < 12; i++) {
					float tmid = 0.5 * (tm + tx);
					vec3 pmid = ray_dir * tmid;
					float hmid = (pmid.y + camera_origin.y) - (ocean_data.ocean_level + get_wave_data(pmid.xz + camera_origin.xz).r);
					if (hmid < 0.0) {
						tx = tmid;
						hx = hmid;
					} else {
						tm = tmid;
						hm = hmid;
					}
				}

				float tfinal = 0.5 * (tm + tx);
				hit_pos = ray_dir * tfinal;
				return tfinal;
			}

			vec3 get_normal_water(vec3 local_p, vec3 dist, vec3 camera_origin) {
				if (ocean_data.wave_tex == -1) return vec3(0.0, 1.0, 0.0);
				vec4 wd = get_wave_data(local_p.xz + camera_origin.xz);
				return normalize(vec3(-wd.g, 1.0, -wd.b));
			}

			float henyey_greenstein(float mu, float g) {
				float gg = g * g;
				return (1.0 - gg) / (pow(1.0 + gg - 2.0 * g * mu, 1.5) * 4.0 * SEA_PI);
			}

			]] .. ibl.GetBRDFGLSLCode() .. [[

			]] .. ibl.GetEnvironmentGLSLCode() .. [[

			]] .. ibl.GetReflectionGLSLCode() .. [[

			]] .. atmosphere.GetAerialPerspectiveGLSLCode() .. [[

			vec3 get_sky_color(vec3 dir) {
				return clamp(get_environment_color(dir, 0.0), vec3(0.0), vec3(65504.0));
			}

			float get_ocean_reflection_roughness(vec3 normal) {
				float slope = sqrt(max(1.0 - clamp(normal.y, 0.0, 1.0), 0.0));
				return clamp(slope * 0.35 + (1.0 - SEA_WAVE_AMOUNT) * 0.01, 0.0, 0.18);
			}

			vec3 get_reflection_color(vec3 reflection_dir, vec3 normal, vec2 ssr_uv, float ssr_weight) {
				vec3 reflected = get_sky_color(reflection_dir);

				if (ocean_data.env_tex != -1) {
					float roughness = get_ocean_reflection_roughness(normal);
					reflected = sample_environment_specular(ocean_data.env_tex, reflection_dir, normal, roughness);
				}

				vec4 ssr = get_filtered_ssr_reflection(ocean_data.ssr_tex, ssr_uv);
				reflected = combine_reflections(reflected, ssr, ssr_weight);

				return reflected;
			}

			vec3 get_environment_irradiance(vec3 normal) {
				return sample_environment_irradiance(ocean_data.env_tex, normal);
			}

			vec3 get_sea_color(
				vec3 p,
				vec3 normal,
				vec3 sun_direction,
				vec3 ray_dir,
				vec3 dist,
				float mu,
				vec3 reflection_color,
				vec3 refracted_scene,
				float thickness
			) {
				vec3 view_dir = normalize(-ray_dir);
				float sun_visibility = smoothstep(-0.02, 0.08, sun_direction.y);
				float no_v = clamp(abs(dot(normal, view_dir)) + 1e-5, 0.0, 1.0);
				float fresnel = F_SchlickScalar(0.02, no_v);
				float depth_factor = 1.0 - exp(-thickness * 0.12);
				vec3 ambient_light = get_environment_irradiance(normal);
				vec3 shallow_absorption_coeff = vec3(0.14, 0.08, 0.04);
				vec3 deep_absorption_coeff = vec3(0.32, 0.12, 0.03);
				vec3 absorption_coeff = mix(shallow_absorption_coeff, deep_absorption_coeff, clamp(depth_factor, 0.0, 1.0));
				vec3 transmitted_color = refracted_scene * exp(-thickness * absorption_coeff);
				vec3 body_scatter_tint = vec3(0.02, 0.08, 0.18);
				vec3 body_scatter = (1.0 - exp(-thickness * vec3(0.18, 0.09, 0.03))) * body_scatter_tint;
					vec3 base_color = transmitted_color + ambient_light * body_scatter;
				vec3 color = mix(base_color, reflection_color, fresnel);
				float no_l = max(dot(normal, sun_direction), 0.0);
				float direct_sun = no_l * sun_visibility;
				float subsurface_amount = 8.0 * henyey_greenstein(mu, 0.5) * direct_sun;
				vec3 water_scatter = 0.45 * vec3(0.18, 0.42, 0.7);
				color += subsurface_amount * water_scatter * max(0.0, 1.0 + p.y - (ocean_data.ocean_level + 0.6 * SEA_HEIGHT));
				vec3 half_dir = normalize(view_dir + sun_direction);
				float no_h = max(dot(normal, half_dir), 0.0);
				color += vec3(1.0) * (0.18 * direct_sun) * (fresnel * D_GGX(0.05, no_h) / SEA_PI);
				float foam = smoothstep(0.18, 0.55, p.y - ocean_data.ocean_level) * smoothstep(0.65, 0.15, normal.y);
				float shore_foam = smoothstep(2.0, 0.0, thickness) * max(0.0, normal.y);
				vec3 foam_light = ambient_light + vec3(1.2) * direct_sun;
					color += vec3(0.95, 0.98, 1.0) * (foam * 0.12 + shore_foam * 0.06) * foam_light;
				return color;
			}

			void main() {
				vec3 scene_color = get_scene_color(in_uv);

                if (ocean_data.ocean_enabled == 0 || ocean_data.scene_tex == -1) {
					set_color(vec4(scene_color, -1.0));
					set_ocean_distance(-1.0);
					return;
				}

				float scene_depth = get_scene_depth(in_uv);
				vec3 camera_origin = ocean_data.camera_position.xyz;
				vec3 ray_origin = vec3(0.0);
				vec3 ray_dir = get_view_ray(in_uv);
				float plane_t = intersect_ocean_plane(ray_origin, ray_dir, ocean_data.ocean_level - camera_origin.y);

				if (plane_t <= 0.0) {
					set_color(vec4(scene_color, -1.0));
					set_ocean_distance(-1.0);
					return;
				}

				vec3 ocean_local_pos = vec3(0.0);
				float ocean_t = height_map_tracing(ray_dir, plane_t, camera_origin, ocean_local_pos);

				if (ocean_t <= 0.0) {
					set_color(vec4(scene_color, -1.0));
					set_ocean_distance(-1.0);
					return;
				}

				vec3 scene_local_pos = vec3(0.0);
				float scene_t = 1e30;

				if (scene_depth < 1.0) {
					scene_local_pos = get_world_pos(in_uv, scene_depth) - camera_origin;
					scene_t = dot(scene_local_pos, ray_dir);

					if (scene_t > 0.0 && scene_t <= ocean_t + 1e-3) {
						set_color(vec4(scene_color, -1.0));
						set_ocean_distance(-1.0);
						return;
					}
				}

				vec3 dist = ocean_local_pos;
				vec3 normal = get_normal_water(ocean_local_pos, dist, camera_origin);
				if (dot(normal, -ray_dir) < 0.0) normal = -normal;
				vec3 reflection_dir = reflect(ray_dir, normal);
				float thickness = SEA_OPTICAL_DEPTH;
				vec3 refracted_scene = get_sky_color(refract(ray_dir, normal, 1.0 / 1.333));
				vec2 reflection_uv = in_uv;

				if (scene_depth < 1.0) {
					thickness = max(length(scene_local_pos - ocean_local_pos), 0.0);
					vec2 refracted_uv = clamp(in_uv + normal.xz * min(thickness * 0.0009, 0.03), vec2(0.001), vec2(0.999));
					reflection_uv = clamp(in_uv + normal.xz * min(thickness * 0.0007, 0.02), vec2(0.001), vec2(0.999));
					refracted_scene = get_scene_color(refracted_uv);
				}

				vec3 ocean_world_pos = ocean_local_pos + camera_origin;

				vec3 view_dir = normalize(-ray_dir);
				float reflection_weight = mix(0.35, 1.0, pow(1.0 - max(dot(normal, view_dir), 0.0), 2.0));
				vec3 reflection_color = get_reflection_color(reflection_dir, normal, reflection_uv, reflection_weight);

				vec3 sun_direction = normalize(ocean_data.sun_direction);
				float mu = dot(sun_direction, ray_dir);
				vec3 color = get_sea_color(
					ocean_world_pos,
					normal,
					sun_direction,
					ray_dir,
					dist,
					mu,
					reflection_color,
					refracted_scene,
					thickness
				);
				color = apply_aerial_perspective(
					color,
					ocean_world_pos,
					sun_direction,
					ocean_data.camera_position.xyz,
					ocean_data.atmosphere_transmittance_texture_index
				);


				set_color(vec4(color, 1.0));
				set_ocean_distance(ocean_t);
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "ocean_resolve",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		fragment = {
			uniform_buffers = {
				{
					name = "ocean_resolve_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{
							"current_ocean_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.ocean or not render3d.pipelines.ocean.framebuffers then
									block[key] = -1
									return
								end

								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(1))
							end,
						},
						{
							"history_ocean_tex",
							"int",
							function(self, block, key)
								if
									not render3d.pipelines.ocean_resolve or
									not render3d.pipelines.ocean_resolve.framebuffers
								then
									block[key] = -1
									return
								end

								local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.ocean_resolve:GetFramebuffer(prev_idx):GetAttachment(1))
							end,
						},
						{
							"current_ocean_distance_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.ocean or not render3d.pipelines.ocean.framebuffers then
									block[key] = -1
									return
								end

								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(2))
							end,
						},
						{
							"prev_view",
							"mat4",
							function(self, block, key)
								local mat = render3d.prev_view_matrix

								if mat then
									mat:CopyToFloatPointer(block[key])
								else
									render3d.camera:BuildViewMatrix():CopyToFloatPointer(block[key])
								end
							end,
						},
						{
							"prev_projection",
							"mat4",
							function(self, block, key)
								local mat = render3d.prev_projection_matrix

								if mat then
									mat:CopyToFloatPointer(block[key])
								else
									render3d.camera:BuildProjectionMatrix():CopyToFloatPointer(block[key])
								end
							end,
						},
					},
				},
			},
			shader = [[
			vec4 get_current_ocean(vec2 uv) {
				if (ocean_resolve_data.current_ocean_tex == -1) return vec4(0.0, 0.0, 0.0, -1.0);
				return texture(TEXTURE(ocean_resolve_data.current_ocean_tex), uv);
			}

			float get_current_ocean_distance(vec2 uv) {
				if (ocean_resolve_data.current_ocean_distance_tex == -1) return -1.0;
				return texture(TEXTURE(ocean_resolve_data.current_ocean_distance_tex), uv).r;
			}

			vec4 get_history_ocean(vec2 uv) {
				if (ocean_resolve_data.history_ocean_tex == -1) return vec4(0.0, 0.0, 0.0, -1.0);
				return texture(TEXTURE(ocean_resolve_data.history_ocean_tex), uv);
			}

			vec3 get_view_ray(vec2 uv) {
				vec4 near_clip_pos = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
				vec4 far_clip_pos = vec4(uv * 2.0 - 1.0, 1.0, 1.0);
				vec4 near_view_pos = ocean_resolve_data.inv_projection * near_clip_pos;
				vec4 far_view_pos = ocean_resolve_data.inv_projection * far_clip_pos;
				near_view_pos /= near_view_pos.w;
				far_view_pos /= far_view_pos.w;
				vec3 view_dir = far_view_pos.xyz - near_view_pos.xyz;
				return normalize(mat3(ocean_resolve_data.inv_view) * view_dir);
			}

			void main() {
				vec4 current = get_current_ocean(in_uv);
				float current_distance = get_current_ocean_distance(in_uv);

				if (current.a < 0.0 || current_distance < 0.0 || ocean_resolve_data.history_ocean_tex == -1) {
					set_color(current);
					return;
				}

				vec3 world_pos = ocean_resolve_data.camera_position.xyz + get_view_ray(in_uv) * current_distance;
				vec4 prev_view_pos = ocean_resolve_data.prev_view * vec4(world_pos, 1.0);
				vec4 prev_clip = ocean_resolve_data.prev_projection * prev_view_pos;
				vec2 prev_uv = (prev_clip.xy / prev_clip.w) * 0.5 + 0.5;

				if (prev_uv.x < 0.0 || prev_uv.x > 1.0 || prev_uv.y < 0.0 || prev_uv.y > 1.0) {
					set_color(current);
					return;
				}

				vec4 history = get_history_ocean(prev_uv);

				if (history.a < 0.0) {
					set_color(current);
					return;
				}

				vec3 m1 = vec3(0.0);
				vec3 m2 = vec3(0.0);
				float sample_count = 0.0;
				vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(ocean_resolve_data.current_ocean_tex), 0));

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						vec4 sample_color = get_current_ocean(in_uv + vec2(x, y) * texel_size);
						if (sample_color.a < 0.0) continue;
						m1 += sample_color.rgb;
						m2 += sample_color.rgb * sample_color.rgb;
						sample_count += 1.0;
					}
				}

				if (sample_count < 4.0) {
					set_color(current);
					return;
				}

				m1 /= sample_count;
				m2 /= sample_count;

				vec3 sigma = sqrt(max(vec3(0.0), m2 - m1 * m1));
				float gamma = 1.25;
				vec3 clamped_rgb = clamp(history.rgb, m1 - sigma * gamma, m1 + sigma * gamma);
				vec4 clamped_history = vec4(clamped_rgb, history.a);
				float clamp_diff = length(history.rgb - clamped_rgb);
				float depth_diff = 0.0;
				float blend = 0.9;
				blend *= 1.0 - clamp(clamp_diff * 2.0, 0.0, 1.0);
				blend = clamp(blend, 0.0, 0.9);

				set_color(vec4(mix(current.rgb, clamped_history.rgb, blend), current.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
