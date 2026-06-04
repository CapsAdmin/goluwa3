local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local WAVE_TEX_SIZE = 512
local WAVE_TEX_WORLD_HALF = 1024.0
local WAVE_NEAR_WORLD_HALF = 64.0
local WAVE_NEAR_REPEAT_WORLD_HALF = 64.0
local get_primary_sun_direction = directional_shadows.GetPrimarySunDirection
local get_primary_sun_intensity = directional_shadows.GetPrimarySunIntensity
local get_primary_sun_color = directional_shadows.GetPrimarySunColor

local function write_wave_precompute(self, block, wave_world_half)
	render3d.WriteCommonBlock(self, block)
	block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
	local snap = wave_world_half * 2 / WAVE_TEX_SIZE
	local cam = render3d.camera:GetPosition()
	block.wave_origin[0] = math.floor(cam.x / snap) * snap
	block.wave_origin[1] = math.floor(cam.z / snap) * snap
	return block
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
						{"blue_noise_tex", "int"},
						{"wave_origin", "vec2"},
					},
					write = function(self, block)
						return write_wave_precompute(self, block, WAVE_NEAR_WORLD_HALF)
					end,
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
			const float WAVE_TEX_WORLD_HALF = ]] .. WAVE_NEAR_WORLD_HALF .. [[;

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
						{"blue_noise_tex", "int"},
						{"wave_origin", "vec2"},
					},
					write = function(self, block)
						return write_wave_precompute(self, block, WAVE_TEX_WORLD_HALF)
					end,
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
						{"scene_tex", "int"},
						{"depth_tex", "int"},
						{"normal_tex", "int"},
						{"mra_tex", "int"},
						{"env_tex", "int"},
						{"ssr_tex", "int"},
						{"atmosphere_transmittance_texture_index", "int"},
						{"sun_direction", "vec3"},
						{"primary_sun_intensity", "float"},
						{"primary_sun_color", "vec3"},
						{"ocean_enabled", "int"},
						{"ocean_level", "float"},
						{"wave_tex", "int"},
						{"wave_origin", "vec2"},
						{"wave_near_tex", "int"},
						{"wave_near_origin", "vec2"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						render3d.WriteCommonBlock(self, block)

						if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
							block.scene_tex = -1
						else
							local current_idx = system.GetFrameNumber() % 2 + 1
							block.scene_tex = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
						end

						block.depth_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
						block.normal_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(2))
						block.mra_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(3))
						block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())

						if not render3d.pipelines.ssr or not render3d.pipelines.ssr.framebuffers then
							block.ssr_tex = -1
						else
							local current_idx = system.GetFrameNumber() % 2 + 1
							block.ssr_tex = self:GetTextureIndex(render3d.pipelines.ssr:GetFramebuffer(current_idx):GetAttachment(1))
						end

						block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
						get_primary_sun_direction():CopyToFloatPointer(block.sun_direction)
						block.primary_sun_intensity = get_primary_sun_intensity()
						get_primary_sun_color():CopyToFloatPointer(block.primary_sun_color)
						block.ocean_enabled = render3d.IsOceanEnabled() and 1 or 0
						block.ocean_level = render3d.GetOceanLevel()

						if not render3d.pipelines.ocean_waves then
							block.wave_tex = -1
						else
							block.wave_tex = self:GetTextureIndex(render3d.pipelines.ocean_waves:GetFramebuffer():GetAttachment(1))
						end

						local far_snap = WAVE_TEX_WORLD_HALF * 2 / WAVE_TEX_SIZE
						local near_snap = WAVE_NEAR_WORLD_HALF * 2 / WAVE_TEX_SIZE
						local cam = render3d.camera:GetPosition()
						block.wave_origin[0] = math.floor(cam.x / far_snap) * far_snap
						block.wave_origin[1] = math.floor(cam.z / far_snap) * far_snap

						if not render3d.pipelines.ocean_waves_near then
							block.wave_near_tex = -1
						else
							block.wave_near_tex = self:GetTextureIndex(render3d.pipelines.ocean_waves_near:GetFramebuffer():GetAttachment(1))
						end

						block.wave_near_origin[0] = math.floor(cam.x / near_snap) * near_snap
						block.wave_near_origin[1] = math.floor(cam.z / near_snap) * near_snap
						return block
					end,
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
			const float WAVE_NEAR_WORLD_HALF = ]] .. WAVE_NEAR_WORLD_HALF .. [[;
			const float WAVE_NEAR_REPEAT_WORLD_HALF = ]] .. WAVE_NEAR_REPEAT_WORLD_HALF .. [[;

			float get_scene_depth(vec2 uv) {
				if (ocean_data.depth_tex == -1) return 1.0;
				return texture(TEXTURE(ocean_data.depth_tex), uv).r;
			}


			]] .. screen_reconstruct.GetWorldPosFromUVGLSL("ocean_data") .. [[
			]] .. screen_reconstruct.GetViewRayFromUVGLSL("ocean_data") .. [[

			vec2 project_world_to_uv(vec3 world_pos) {
				vec4 clip_pos = ocean_data.projection * ocean_data.view * vec4(world_pos, 1.0);
				if (clip_pos.w <= 1e-5) return vec2(-1.0);
				vec2 uv = (clip_pos.xy / clip_pos.w) * 0.5 + 0.5;
				return uv;
			}

			float intersect_ocean_plane(vec3 ray_origin, vec3 ray_dir, float plane_y) {
				float denom = ray_dir.y;
				if (abs(denom) < 1e-5) return -1.0;

				float t = (plane_y - ray_origin.y) / denom;
				return t > 0.0 ? t : -1.0;
			}

			vec4 sample_wave_texture(int texture_index, vec2 uv) {
				vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(texture_index), 0));
				vec2 clamped_uv = clamp(uv, texel_size * 0.5, vec2(1.0) - texel_size * 0.5);
				return texture(TEXTURE(texture_index), clamped_uv);
			}

			vec4 sample_wave_texture_repeat(int texture_index, vec2 uv) {
				vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(texture_index), 0));
				vec2 wrapped_uv = fract(uv);
				wrapped_uv = wrapped_uv * (vec2(1.0) - texel_size) + texel_size * 0.5;
				return texture(TEXTURE(texture_index), wrapped_uv);
			}

			vec4 get_wave_data(vec2 world_xz) {
				vec4 far_data = vec4(0.0);
				if (ocean_data.wave_tex != -1) {
					vec2 far_uv = (world_xz - ocean_data.wave_origin) * (0.5 / WAVE_TEX_WORLD_HALF) + 0.5;
					if (all(greaterThanEqual(far_uv, vec2(0.0))) && all(lessThanEqual(far_uv, vec2(1.0)))) {
						float far_dist = length(world_xz - ocean_data.wave_origin);
						float edge_fade = 1.0 - smoothstep(WAVE_TEX_WORLD_HALF * 0.35, WAVE_TEX_WORLD_HALF, far_dist);
						far_data = sample_wave_texture(ocean_data.wave_tex, far_uv) * edge_fade;
					}
				}
				if (ocean_data.wave_near_tex == -1) return far_data;
				vec2 near_delta = world_xz - ocean_data.wave_near_origin;
				float near_dist = length(near_delta);
				if (near_dist > WAVE_NEAR_REPEAT_WORLD_HALF) return far_data;
				vec2 near_uv = near_delta * (0.5 / WAVE_NEAR_WORLD_HALF) + 0.5;
				float near_fade = 1.0 - smoothstep(WAVE_NEAR_REPEAT_WORLD_HALF * 0.1, WAVE_NEAR_REPEAT_WORLD_HALF, near_dist);
				return mix(far_data, sample_wave_texture_repeat(ocean_data.wave_near_tex, near_uv), near_fade);
			}

			float get_water_surface_height(vec2 world_xz) {
				return ocean_data.ocean_level + get_wave_data(world_xz).r;
			}

			float height_map_tracing(vec3 ray_dir, float plane_t, vec3 camera_origin, out vec3 hit_pos) {
				if (ocean_data.wave_tex == -1) {
					hit_pos = ray_dir * plane_t;
					return plane_t;
				}

				float camera_height = camera_origin.y - get_water_surface_height(camera_origin.xz);
				float vertical_span = abs(camera_height) + SEA_HEIGHT * 6.0;
				float search_radius = clamp(vertical_span / max(abs(ray_dir.y), 0.02), 8.0, 192.0);

				if (plane_t <= 0.0 && camera_height >= 0.0) {
					search_radius = min(search_radius, mix(24.0, 64.0, smoothstep(0.0, SEA_HEIGHT * 2.5, camera_height)));
				}

				float tm = max(plane_t - search_radius, 0.0);
				float tx = plane_t + search_radius;
				float start_t = tm;
				float start_h = 0.0;

				if (camera_height >= 0.0) {
					start_t = 0.0;
					start_h = camera_height;
				} else {
					vec3 pstart = ray_dir * start_t;
					start_h = (pstart.y + camera_origin.y) - get_water_surface_height(pstart.xz + camera_origin.xz);
				}

				float prev_t = start_t;
				float prev_h = start_h;
				vec3 pend = ray_dir * tx;
				float end_h = (pend.y + camera_origin.y) - get_water_surface_height(pend.xz + camera_origin.xz);
				int trace_samples = int(mix(32.0, 96.0, 1.0 - smoothstep(0.08, 0.35, abs(ray_dir.y))));
				float trace_bias = mix(1.15, 2.75, 1.0 - smoothstep(0.08, 0.35, abs(ray_dir.y)));
				bool found_bracket = false;

				for (int i = 1; i <= 96; i++) {
					if (i > trace_samples) break;
					float sample_frac = pow(float(i) / float(trace_samples), trace_bias);
					float sample_t = mix(start_t, tx, sample_frac);
					vec3 psample = ray_dir * sample_t;
					float sample_h = (psample.y + camera_origin.y) - get_water_surface_height(psample.xz + camera_origin.xz);

					if (sample_h * prev_h <= 0.00) {
						tm = prev_t;
						tx = sample_t;
						found_bracket = true;
						break;
					}

					prev_t = sample_t;
					prev_h = sample_h;
				}

				if (!found_bracket) {
					if (start_h * end_h > 0.0) return -1.0;
					tm = start_t;
				}

				vec3 pm = ray_dir * tm;
				float hm = (pm.y + camera_origin.y) - get_water_surface_height(pm.xz + camera_origin.xz);
				vec3 px = ray_dir * tx;
				float hx = (px.y + camera_origin.y) - get_water_surface_height(px.xz + camera_origin.xz);

				for (int i = 0; i < 4; i++) {
					float local_tm = tm;
					float local_hm = hm;
					bool refined = false;

					for (int j = 1; j <= 4; j++) {
						float local_t = mix(tm, tx, float(j) / 4.0);
						vec3 plocal = ray_dir * local_t;
						float local_h = (plocal.y + camera_origin.y) - get_water_surface_height(plocal.xz + camera_origin.xz);

						if (local_h * local_hm <= 0.0) {
							tm = local_tm;
							hm = local_hm;
							tx = local_t;
							hx = local_h;
							refined = true;
							break;
						}

						local_tm = local_t;
						local_hm = local_h;
					}

					if (!refined) break;
				}

				for (int i = 0; i < 12; i++) {
					float tmid = 0.5 * (tm + tx);
					vec3 pmid = ray_dir * tmid;
					float hmid = (pmid.y + camera_origin.y) - get_water_surface_height(pmid.xz + camera_origin.xz);
					if (hmid * hm > 0.0) {
						tm = tmid;
						hm = hmid;
					} else {
						tx = tmid;
						hx = hmid;
					}
				}

				float tfinal = 0.5 * (tm + tx);
				hit_pos = ray_dir * tfinal;
				return tfinal;
			}

			vec3 get_normal_water(vec3 local_p, vec3 dist, vec3 camera_origin) {
				if (ocean_data.wave_tex == -1) return vec3(0.0, 1.0, 0.0);
				vec4 wd = get_wave_data(local_p.xz + camera_origin.xz);
				float view_distance = length(dist);
				float slope_fade = 1.0 - smoothstep(160.0, 1200.0, view_distance);
				return normalize(vec3(-wd.g * slope_fade, 1.0, -wd.b * slope_fade));
			}

			float henyey_greenstein(float mu, float g) {
				float gg = g * g;
				return (1.0 - gg) / (pow(1.0 + gg - 2.0 * g * mu, 1.5) * 4.0 * SEA_PI);
			}

			#define ATMOSPHERE_SUN_INTENSITY ocean_data.primary_sun_intensity

			]] .. ibl.GetBRDFGLSLCode() .. [[

			]] .. ibl.GetEnvironmentGLSLCode() .. [[

			]] .. ibl.GetReflectionGLSLCode("ocean_data") .. [[

			]] .. atmosphere.GetSurfaceAerialPerspectiveGLSLCode("get_environment_color(dir, 0.0)") .. [[

			float get_ocean_reflection_roughness(vec3 normal) {
				float slope = sqrt(max(1.0 - clamp(normal.y, 0.0, 1.0), 0.0));
				return clamp(slope * 0.35 + (1.0 - SEA_WAVE_AMOUNT) * 0.01, 0.0, 0.18);
			}

			vec3 get_reflection_color(vec3 reflection_dir, vec3 normal, vec2 ssr_uv, float ssr_weight) {
				vec3 reflected = get_atmosphere_background_color(reflection_dir);
				float roughness = get_ocean_reflection_roughness(normal);

				if (ocean_data.env_tex != -1) {
					reflected = sample_environment_specular(ocean_data.env_tex, reflection_dir, normal, roughness);
				}

				vec4 ssr = get_filtered_ssr_reflection(ssr_uv);
				reflected = combine_reflections(reflected, ssr, ssr_weight * get_ssr_blend_weight(roughness));

				return reflected;
			}

			vec3 get_environment_irradiance(vec3 normal) {
				return sample_environment_irradiance(ocean_data.env_tex, normal);
			}

			vec3 apply_water_volume(vec3 source_color, vec3 ambient_light, float thickness) {
				float depth_factor = 1.0 - exp(-thickness * 0.12);
				vec3 shallow_absorption_coeff = vec3(0.14, 0.08, 0.04);
				vec3 deep_absorption_coeff = vec3(0.32, 0.12, 0.03);
				vec3 absorption_coeff = mix(shallow_absorption_coeff, deep_absorption_coeff, clamp(depth_factor, 0.0, 1.0));
				vec3 transmitted_color = source_color * exp(-thickness * absorption_coeff);
				vec3 body_scatter_tint = vec3(0.02, 0.08, 0.18);
				vec3 body_scatter = (1.0 - exp(-thickness * vec3(0.18, 0.09, 0.03))) * body_scatter_tint;
				return transmitted_color + ambient_light * body_scatter;
			}

			float get_underwater_fresnel(vec3 normal, vec3 view_dir) {
				float eta_i = 1.333;
				float eta_t = 1.0;
				float cos_i = clamp(dot(normal, view_dir), 0.0, 1.0);
				float eta = eta_i / eta_t;
				float sin_t2 = eta * eta * max(0.0, 1.0 - cos_i * cos_i);

				if (sin_t2 >= 1.0) return 1.0;

				float cos_t = sqrt(max(0.0, 1.0 - sin_t2));
				float rs_num = eta_i * cos_i - eta_t * cos_t;
				float rs_den = eta_i * cos_i + eta_t * cos_t;
				float rp_num = eta_t * cos_i - eta_i * cos_t;
				float rp_den = eta_t * cos_i + eta_i * cos_t;
				float rs = rs_num / max(rs_den, 1e-5);
				float rp = rp_num / max(rp_den, 1e-5);
				return clamp(0.5 * (rs * rs + rp * rp), 0.0, 1.0);
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
				vec3 ambient_light = get_environment_irradiance(normal);
				vec3 base_color = apply_water_volume(refracted_scene, ambient_light, thickness);
				vec3 color = mix(base_color, reflection_color, fresnel);
				float no_l = max(dot(normal, sun_direction), 0.0);
				vec3 sun_radiance = ocean_data.primary_sun_color * (no_l * sun_visibility * ocean_data.primary_sun_intensity);
				float sun_energy = max(max(sun_radiance.r, sun_radiance.g), sun_radiance.b);
				float subsurface_amount = 1.0 * henyey_greenstein(mu, 0.5) * sun_energy;
				vec3 water_scatter = 0.45 * vec3(0.18, 0.42, 0.7);
				color += subsurface_amount * water_scatter * ocean_data.primary_sun_color * max(0.0, 1.0 + p.y - (ocean_data.ocean_level + 0.6 * SEA_HEIGHT));
				vec3 half_dir = normalize(view_dir + sun_direction);
				float no_h = max(dot(normal, half_dir), 0.0);
				color += sun_radiance * (0.18 * fresnel * D_GGXAlpha(0.05, no_h) / SEA_PI);
				float foam = smoothstep(0.18, 0.55, p.y - ocean_data.ocean_level) * smoothstep(0.65, 0.15, normal.y);
				float shore_foam = smoothstep(2.0, 0.0, thickness) * max(0.0, normal.y);
				vec3 foam_light = ambient_light * sun_radiance;
				color += vec3(0.95, 0.98, 1.0) * (foam * 0.12 + shore_foam * 0.06) * foam_light;
				return color;
			}

			vec3 get_underwater_surface_color(
				vec3 normal,
				vec3 ray_dir,
				vec3 reflection_color,
				vec3 refracted_scene,
				float thickness,
				float fresnel
			) {
				vec3 ambient_light = get_environment_irradiance(vec3(0.0, 1.0, 0.0));
				vec3 reflected_color = apply_water_volume(
					reflection_color,
					ambient_light,
					min(thickness * 0.2, 12.0)
				);
				vec3 interface_color = mix(refracted_scene, reflected_color, fresnel);
				return apply_water_volume(interface_color, ambient_light, thickness);
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
				float trace_plane_y = ocean_data.ocean_level + SEA_HEIGHT * 1.5;
				float plane_t = intersect_ocean_plane(ray_origin, ray_dir, trace_plane_y - camera_origin.y);
				float camera_surface_delta = camera_origin.y - get_water_surface_height(camera_origin.xz);
				bool camera_underwater = camera_surface_delta < 0.0;
				float trace_anchor_t = plane_t;
				vec3 scene_local_pos = vec3(0.0);
				float scene_t = 1e30;

				if (!camera_underwater && trace_anchor_t <= 0.0 && camera_surface_delta <= SEA_HEIGHT * 2.5) {
					trace_anchor_t = 0.0;
				}

				if (camera_underwater && trace_anchor_t <= 0.0 && camera_surface_delta >= -SEA_HEIGHT * 2.5) {
					trace_anchor_t = 0.0;
				}

				if (scene_depth < 1.0) {
					scene_local_pos = get_world_pos(in_uv, scene_depth) - camera_origin;
					scene_t = dot(scene_local_pos, ray_dir);
				}

				if (camera_underwater) {
					vec3 ocean_local_pos = vec3(0.0);
					float ocean_t = trace_anchor_t >= 0.0 ? height_map_tracing(ray_dir, trace_anchor_t, camera_origin, ocean_local_pos) : -1.0;
					bool scene_before_surface = scene_depth < 1.0 && scene_t > 0.0 && scene_t <= ocean_t + 1e-3;

					if (ocean_t > 0.0 && !scene_before_surface) {
						vec3 normal = get_normal_water(ocean_local_pos, ocean_local_pos, camera_origin);

						if (dot(normal, -ray_dir) < 0.0) normal = -normal;

						vec3 reflection_dir = reflect(ray_dir, normal);
						vec2 reflection_uv = in_uv;
						vec3 view_dir = normalize(-ray_dir);
						float fresnel = get_underwater_fresnel(normal, view_dir);
						float reflection_weight = fresnel;
						vec3 reflection_color = get_reflection_color(reflection_dir, normal, reflection_uv, reflection_weight);
						vec3 refracted_dir = refract(ray_dir, normal, 1.333);
						vec3 refracted_scene = length(refracted_dir) > 1e-5 ? get_atmosphere_background_color(refracted_dir) : reflection_color;

						if (length(refracted_dir) > 1e-5 && scene_depth < 1.0 && scene_t > ocean_t + 1e-3) {
							float air_distance = max(length(scene_local_pos - ocean_local_pos), 0.0);
							vec3 refracted_target_world = camera_origin + ocean_local_pos + refracted_dir * air_distance;
							vec2 refracted_uv = project_world_to_uv(refracted_target_world);

							if (
								all(greaterThanEqual(refracted_uv, vec2(0.001))) &&
								all(lessThanEqual(refracted_uv, vec2(0.999)))
							) {
								refracted_scene = get_scene_color(refracted_uv);
							}
						}

						vec3 color = get_underwater_surface_color(normal, ray_dir, reflection_color, refracted_scene, ocean_t, fresnel);
						set_color(vec4(color, 1.0));
						set_ocean_distance(ocean_t);
						return;
					}

					float thickness = SEA_OPTICAL_DEPTH;
					vec3 source_color = get_atmosphere_background_color(ray_dir);
					float resolve_distance = -1.0;

					if (scene_depth < 1.0 && scene_t > 0.0) {
						thickness = min(scene_t, SEA_OPTICAL_DEPTH);
						source_color = scene_color;
						resolve_distance = scene_t;
					}

					vec3 color = apply_water_volume(source_color, get_environment_irradiance(vec3(0.0, 1.0, 0.0)), thickness);
					set_color(vec4(color, 1.0));
					set_ocean_distance(resolve_distance);
					return;
				}

				if (trace_anchor_t < 0.0) {
					set_color(vec4(scene_color, -1.0));
					set_ocean_distance(-1.0);
					return;
				}

				vec3 ocean_local_pos = vec3(0.0);
				float ocean_t = height_map_tracing(ray_dir, trace_anchor_t, camera_origin, ocean_local_pos);
				
				if (ocean_t <= 0.0) {
					set_color(vec4(scene_color, -1.0));
					set_ocean_distance(-1.0);
					return;
				}

				if (scene_depth < 1.0 && scene_t > 0.0 && scene_t <= ocean_t + 1e-3) {
					set_color(vec4(scene_color, -1.0));
					set_ocean_distance(-1.0);
					return;
				}

				vec3 dist = ocean_local_pos;
				vec3 normal = get_normal_water(ocean_local_pos, dist, camera_origin);
	
				if (dot(normal, -ray_dir) < 0.0) normal = -normal;
				vec3 reflection_dir = reflect(ray_dir, normal);
				float thickness = SEA_OPTICAL_DEPTH;
				vec3 refracted_scene = get_atmosphere_background_color(refract(ray_dir, normal, 1.0 / 1.333));
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
				color = apply_surface_aerial_perspective(
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
						{"current_ocean_tex", "int"},
						{"history_ocean_tex", "int"},
						{"current_ocean_distance_tex", "int"},
						{"prev_view", "mat4"},
						{"prev_projection", "mat4"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)

						if not render3d.pipelines.ocean or not render3d.pipelines.ocean.framebuffers then
							block.current_ocean_tex = -1
							block.current_ocean_distance_tex = -1
						else
							local current_idx = system.GetFrameNumber() % 2 + 1
							local framebuffer = render3d.pipelines.ocean:GetFramebuffer(current_idx)
							block.current_ocean_tex = self:GetTextureIndex(framebuffer:GetAttachment(1))
							block.current_ocean_distance_tex = self:GetTextureIndex(framebuffer:GetAttachment(2))
						end

						if
							not render3d.pipelines.ocean_resolve or
							not render3d.pipelines.ocean_resolve.framebuffers
						then
							block.history_ocean_tex = -1
						else
							local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
							block.history_ocean_tex = self:GetTextureIndex(render3d.pipelines.ocean_resolve:GetFramebuffer(prev_idx):GetAttachment(1))
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


			]] .. screen_reconstruct.GetViewRayFromUVGLSL("ocean_resolve_data") .. [[

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
