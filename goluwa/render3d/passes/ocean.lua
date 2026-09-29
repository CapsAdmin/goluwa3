--[[
	Water: the ocean and the water volumes (see goluwa/render3d/water.lua).

	ocean_waves_*: the ocean's Gerstner waves baked around the camera into
	three cascades of height, slope and fold, each holding the waves long
	enough for its texel size.

	ocean: per pixel, finds the nearest water surface along the view ray (the
	ocean's height field or a volume's box) and shades it as a dielectric
	interface over an absorbing, scattering medium, drawn over the lit opaque
	scene.

	ocean_resolve: temporal accumulation of the water, reprojected by the
	distance to its surface.
]]
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local screen_refraction = import("goluwa/render3d/screen_refraction.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local water = import("goluwa/render3d/water.lua")
local render = import("goluwa/render/render.lua")
local scene_reflection = import("goluwa/render3d/scene_reflection.lua")
local RAY_QUERY = scene_reflection.RAY_QUERY
local REFLECTION_BINDINGS = {scene = 5, triangles = 6, materials = 7, light_grid = 9}
local WAVE_TEX_SIZE = 512
-- world half size of each wave cascade, nearest first
local WAVE_CASCADES = {
	{name = "ocean_waves_near", world_half = 64},
	{name = "ocean_waves_mid", world_half = 256},
	{name = "ocean_waves", world_half = 1024},
}
local NEAR_TEXEL_SIZE = WAVE_CASCADES[1].world_half * 2 / WAVE_TEX_SIZE

local function get_cascade_texel_size(cascade)
	return cascade.world_half * 2 / WAVE_TEX_SIZE
end

-- snapped to whole texels so the waves don't swim as the camera moves
local function write_cascade_origin(ptr, cascade)
	local snap = get_cascade_texel_size(cascade)
	local cam = render3d.GetCamera():GetPosition()
	ptr[0] = math.floor(cam.x / snap) * snap
	ptr[1] = math.floor(cam.z / snap) * snap
end

local passes = {}

for _, cascade in ipairs(WAVE_CASCADES) do
	list.insert(
		passes,
		{
			name = cascade.name,
			ColorFormat = {
				{"r16g16b16a16_sfloat", {"wave_data", "rgba"}},
			},
			FramebufferSize = {x = WAVE_TEX_SIZE, y = WAVE_TEX_SIZE},
			fragment = {
				uniform_buffers = {
					{
						name = "wave_block",
						binding_index = 3,
						block = {
							render3d.common_block,
							{"wave_origin", "vec2"},
							water.wave_block,
						},
						write = function(self, block)
							render3d.WriteCommonBlock(self, block)
							local waves = water.GetOceanWaves(NEAR_TEXEL_SIZE)
							water.WriteWaveBlock(block, waves, water.GetResolvedWaveCount(waves, get_cascade_texel_size(cascade)))
							write_cascade_origin(block.wave_origin, cascade)
							return block
						end,
					},
				},
				shader = water.GERSTNER_GLSL .. [[
				const float WAVE_TEX_WORLD_HALF = ]] .. cascade.world_half .. [[;

				// height above the mean, the height's slope, and how far the
				// surface folds (1 - jacobian), which is where waves break
				void main() {
					vec2 world_xz = wave_block.wave_origin + (in_uv * 2.0 - 1.0) * WAVE_TEX_WORLD_HALF;
					float choppiness = wave_block.wave_choppiness;
					vec2 p = gerstner_undisplace(world_xz, wave_block.time, choppiness);
					float height;
					vec3 normal;
					float jacobian;
					gerstner_surface(p, wave_block.time, choppiness, height, normal, jacobian);
					set_wave_data(vec4(height, -normal.x / normal.y, -normal.z / normal.y, 1.0 - jacobian));
				}
				]],
			},
			CullMode = "none",
			DepthTest = false,
			DepthWrite = false,
		}
	)
end

local write_volumes

do
	-- past the limit, the volumes nearest the camera are drawn
	local nearest = {}
	local distances = setmetatable({}, {__mode = "k"})

	local function by_distance(a, b)
		return distances[a] < distances[b]
	end

	local function get_drawn_volumes()
		local volumes = water.GetVolumes()

		if #volumes <= water.MAX_VOLUMES then return volumes end

		local cam = render3d.GetCamera():GetPosition()
		list.clear(nearest)

		for i, volume in ipairs(volumes) do
			local pos = volume.Owner.transform:GetWorldPosition()
			local size = volume:GetSize()
			-- to the box's bounding circle, so a big lake counts from its shore
			distances[volume] = math.max(
				math.sqrt((pos.x - cam.x) ^ 2 + (pos.y - cam.y) ^ 2 + (pos.z - cam.z) ^ 2) - math.sqrt(size.x * size.x + size.z * size.z) / 2,
				0
			)
			nearest[i] = volume
		end

		table.sort(nearest, by_distance)
		return nearest
	end

	function write_volumes(block)
		local count = 0

		for _, volume in ipairs(get_drawn_volumes()) do
			if count >= water.MAX_VOLUMES then break end

			local transform = volume.Owner.transform
			local i = count
			local size = volume:GetSize()
			local absorption = volume:GetAbsorption()
			local scattering = volume:GetParticleScattering()
			local flow = volume:GetFlow()
			transform:GetWorldMatrixInverse():CopyToFloatPointer(block.volume_to_local[i])
			block.volume_shape[i][0] = size.x / 2
			block.volume_shape[i][1] = size.y
			block.volume_shape[i][2] = size.z / 2
			block.volume_shape[i][3] = transform:GetWorldPosition().y
			block.volume_absorption[i][0] = absorption.x
			block.volume_absorption[i][1] = absorption.y
			block.volume_absorption[i][2] = absorption.z
			block.volume_absorption[i][3] = volume:GetIOR()
			block.volume_scattering[i][0] = scattering.x
			block.volume_scattering[i][1] = scattering.y
			block.volume_scattering[i][2] = scattering.z
			block.volume_scattering[i][3] = volume:GetRoughness()
			block.volume_waves[i][0] = volume:GetWaveHeight()
			block.volume_waves[i][1] = math.max(volume:GetWaveLength(), 0.01)
			block.volume_waves[i][2] = math.rad(volume:GetWindDirection())
			block.volume_waves[i][3] = volume:GetFoam()
			block.volume_flow[i][0] = flow.x
			block.volume_flow[i][1] = flow.y
			block.volume_flow[i][2] = volume:GetCaustics()
			block.volume_flow[i][3] = 0
			count = count + 1
		end

		block.volume_count = count
	end
end

local function write_ocean(self, block)
	local params = water.GetOcean()
	local waves = water.GetOceanWaves(NEAR_TEXEL_SIZE)
	block.ocean_enabled = render3d.IsOceanEnabled() and 1 or 0
	block.ocean_level = render3d.GetOceanLevel()
	block.ocean_absorption[0] = params.Absorption.x
	block.ocean_absorption[1] = params.Absorption.y
	block.ocean_absorption[2] = params.Absorption.z
	block.ocean_absorption[3] = params.IOR
	block.ocean_scattering[0] = params.ParticleScattering.x
	block.ocean_scattering[1] = params.ParticleScattering.y
	block.ocean_scattering[2] = params.ParticleScattering.z
	block.ocean_scattering[3] = params.Foam
	-- about the highest crest of the sea state, 3.5 standard deviations of height
	block.ocean_wave_info[0] = waves.height_std * 3.5 + 0.05
	block.ocean_wave_info[1] = params.Caustics
	block.ocean_wave_info[2] = waves.total_slope_variance
	block.ocean_wave_info[3] = 0

	for i, cascade in ipairs(WAVE_CASCADES) do
		local pipeline = render3d.pipelines[cascade.name]
		block.wave_tex[i - 1] = pipeline and
			pipeline.framebuffers and
			self:GetTextureIndex(pipeline:GetFramebuffer():GetAttachment(1)) or
			-1
		write_cascade_origin(block.wave_origin[i - 1], cascade)
		block.wave_origin[i - 1][2] = cascade.world_half
		block.wave_origin[i - 1][3] = water.GetResolvedSlopeVariance(waves, get_cascade_texel_size(cascade))
	end

	block.detail_info[0] = math.cos(waves.wind_angle)
	block.detail_info[1] = math.sin(waves.wind_angle)
	block.detail_info[2] = waves.detail_wavelength
	block.detail_info[3] = waves.detail_slope_variance / water.DETAIL_OCTAVES
end

list.insert(
	passes,
	{
		name = "ocean",
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			-- r: how far the water or what is seen through it is, for reprojection. g: where the air
			-- the fog fills ends, 0 with the camera in the water, -1 where there is no water
			{"r32g32_sfloat", {"ocean_distance", "rg"}},
		},
		framebuffer_count = 2,
		dont_create_framebuffers = true,
		-- the traced reflections' bindings change every frame, so each frame in flight has its own set
		DescriptorSetCount = RAY_QUERY and render.GetSwapchainImageCount() or nil,
		on_pre_draw = RAY_QUERY and
			function(self, cmd)
				scene_reflection.Bind(self, cmd, render.GetCurrentFrame(), REFLECTION_BINDINGS)
			end or
			nil,
		fragment = {
			descriptor_sets = RAY_QUERY and
				scene_reflection.GetDescriptorSets(REFLECTION_BINDINGS, "fragment") or
				nil,
			custom_declarations = RAY_QUERY and scene_reflection.GetDeclarationGLSL(REFLECTION_BINDINGS) or nil,
			uniform_buffers = {
				{
					name = "ocean_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						render3d.common_block,
						gbuffer_layout.block,
						{"scene_tex", "int"},
						{"env_tex", "int"},
						{"env_irradiance_tex", "int"},
						{"blue_noise_tex", "int"},
						{"frame", "int"},
						{"sun_direction", "vec3"},
						{"primary_sun_illuminance", "float"},
						{"primary_sun_color", "vec3"},
						{"ocean_enabled", "int"},
						{"ocean_level", "float"},
						{"ocean_absorption", "vec4"},
						{"ocean_scattering", "vec4"},
						{"ocean_wave_info", "vec4"},
						{"wave_tex", "int", #WAVE_CASCADES},
						-- xy origin, z world half size, w slope variance it holds
						{"wave_origin", "vec4", #WAVE_CASCADES},
						-- wind direction, longest ripple, slope variance per octave
						{"detail_info", "vec4"},
						{"volume_to_local", "mat4", water.MAX_VOLUMES},
						-- half width, depth, half length, surface height
						{"volume_shape", "vec4", water.MAX_VOLUMES},
						-- rgb, ior
						{"volume_absorption", "vec4", water.MAX_VOLUMES},
						-- rgb, roughness
						{"volume_scattering", "vec4", water.MAX_VOLUMES},
						-- wave height, wave length, wind angle, foam
						{"volume_waves", "vec4", water.MAX_VOLUMES},
						-- flow xz, caustics
						{"volume_flow", "vec4", water.MAX_VOLUMES},
						{"volume_count", "int"},
						{"shadows", directional_shadows.BuildFogShadowBlockLayout()},
						post_source.pre_exposure_block,
						RAY_QUERY and scene_reflection.block or nil,
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						render3d.WriteCommonBlock(self, block)
						gbuffer_layout.WriteBlock(self, block)
						post_source.WritePreExposureBlock(self, block)
						local current_idx = system.GetFrameNumber() % 2 + 1

						if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
							block.scene_tex = -1
						else
							block.scene_tex = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
						end

						block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
						block.env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
						block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
						block.frame = system.GetFrameNumber() % 4096
						local lights = render3d.GetLights()
						directional_shadows.GetPrimarySunDirection(lights):CopyToFloatPointer(block.sun_direction)
						block.primary_sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights)
						directional_shadows.GetPrimarySunColor(lights):CopyToFloatPointer(block.primary_sun_color)
						directional_shadows.WriteFogShadowBlock(self, block.shadows, lights)
						write_ocean(self, block)
						write_volumes(block)

						if RAY_QUERY then scene_reflection.WriteBlock(self, block) end

						return block
					end,
				},
				RAY_QUERY and scene_reflection.GetDDGIUniformBuffer(8) or nil,
			},
			shader = [[
			]] .. post_source.GetPreExposureGLSL("ocean_data") .. [[

			// the lit scene is pre-exposed, the water's shading is absolute
			vec3 get_scene_color(vec2 uv) {
				if (ocean_data.scene_tex == -1) return vec3(0.0);
				return texture(TEXTURE(ocean_data.scene_tex), uv).rgb / get_pre_exposure();
			}

			void set_scene_color(vec3 color, float alpha) {
				set_color(vec4(min(color * get_pre_exposure(), vec3(65504.0)), alpha));
			}

			const float WATER_PI = 3.14159265359;
			const vec3 WATER_MOLECULAR_SCATTERING = vec3(]] .. water.MOLECULAR_SCATTERING.x .. ", " .. water.MOLECULAR_SCATTERING.y .. ", " .. water.MOLECULAR_SCATTERING.z .. [[);
			const float WATER_PARTICLE_G = ]] .. water.PARTICLE_PHASE_G .. [[;
			// the share of what the particles scatter that goes back
			const float WATER_PARTICLE_BACKSCATTER = ]] .. string.format(
					"%.5f",
					(
							1 - water.PARTICLE_PHASE_G
						) / (
							2 * water.PARTICLE_PHASE_G
						) * (
							(
								1 + water.PARTICLE_PHASE_G
							) / math.sqrt(1 + water.PARTICLE_PHASE_G ^ 2) - 1
						)
				) .. [[;
			const float WATER_GRAVITY = ]] .. water.GRAVITY .. [[;
			const int WAVE_CASCADES = ]] .. #WAVE_CASCADES .. [[;
			const int RIPPLE_OCTAVES = ]] .. water.DETAIL_OCTAVES .. [[;
			const float WAVE_TEXELS_PER_WAVELENGTH = ]] .. water.WAVE_TEXELS_PER_WAVELENGTH .. [[;
			const float SUN_ANGULAR_RADIUS = ]] .. atmosphere.SUN_ANGULAR_RADIUS .. [[;
			// how far the medium is followed when nothing is behind it
			const float WATER_OPEN_DEPTH = 2000.0;
			const float WATER_SSR_DISTANCE = 400.0;

			]] .. gbuffer_layout.GetDecodeGLSL("ocean_data") .. [[
			]] .. screen_reconstruct.GetWorldPosFromUVGLSL("ocean_data") .. [[
			]] .. screen_reconstruct.GetViewRayFromUVGLSL("ocean_data") .. [[
			]] .. screen_refraction.GetGLSL("ocean_data") .. [[
			// what the medium shadow lookup expects from the atmosphere code
			float get_fog_sun_horizon_visibility(vec3 sun_dir) {
				return smoothstep(-0.08, 0.02, sun_dir.y);
			}

			]] .. directional_shadows.GetMediumDirectionalShadowGLSL("ocean_data", "get_water_sun_visibility") .. [[
			]] .. ibl.GetBRDFGLSLCode() .. [[
			]] .. ibl.GetEnvironmentGLSLCode() .. (
					RAY_QUERY and
					render3d.GetEmissiveGLSL() .. scene_reflection.GetGLSL("ocean_data")
					or
					""
				) .. [[

			float get_blue_noise() {
				if (ocean_data.blue_noise_tex == -1) return 0.5;
				ivec2 size = textureSize(TEXTURE(ocean_data.blue_noise_tex), 0);
				float n = texelFetch(TEXTURE(ocean_data.blue_noise_tex), ivec2(gl_FragCoord.xy) % size, 0).r;
				return fract(n + float(ocean_data.frame) * 0.61803398875);
			}

			vec2 get_blue_noise2() {
				if (ocean_data.blue_noise_tex == -1) return vec2(0.5);
				ivec2 size = textureSize(TEXTURE(ocean_data.blue_noise_tex), 0);
				vec2 n = texelFetch(TEXTURE(ocean_data.blue_noise_tex), ivec2(gl_FragCoord.xy) % size, 0).rg;
				return fract(n + float(ocean_data.frame) * vec2(0.7548776662, 0.5698402910));
			}

			float water_hash(vec2 p) {
				vec3 p3 = fract(vec3(p.xyx) * 0.1031);
				p3 += dot(p3, p3.yzx + 33.33);
				return fract((p3.x + p3.y) * p3.z);
			}

			float water_value_noise(vec2 p) {
				vec2 i = floor(p);
				vec2 f = fract(p);
				vec2 u = f * f * (3.0 - 2.0 * f);
				return mix(
					mix(water_hash(i), water_hash(i + vec2(1.0, 0.0)), u.x),
					mix(water_hash(i + vec2(0.0, 1.0)), water_hash(i + vec2(1.0, 1.0)), u.x),
					u.y
				);
			}

			// foam is clumps of bubbles that drift and pop
			float foam_pattern(vec2 p, float time) {
				float n = water_value_noise(p * 0.9 + vec2(time * 0.07, -time * 0.05)) * 0.5;
				n += water_value_noise(p * 2.3 - vec2(time * 0.11, time * 0.08)) * 0.3;
				n += water_value_noise(p * 6.1 + vec2(time * 0.2, 0.0)) * 0.2;
				return n;
			}

			// how many meters one pixel covers on a surface t away that the
			// view ray meets at cos_incidence. the stretch along the view is
			// only partly counted, all of it would blur everything at grazing
			float get_pixel_footprint(float t, float cos_incidence) {
				float pixel_angle = 2.0 / (ocean_data.projection[1][1] * ocean_data.render_size.y);
				return t * pixel_angle / sqrt(max(abs(cos_incidence), 0.03));
			}

			// fades waves shorter than the pixel. the faded ones' slopes
			// become roughness instead of aliasing
			float get_wave_resolve(float wavelength, float footprint) {
				float x = clamp(wavelength / max(footprint, 1e-6) * 0.5 - 1.0, 0.0, 1.0);
				return x * x * (3.0 - 2.0 * x);
			}

			// exact fresnel reflectance of unpolarized light, eta = n_from / n_to
			float fresnel_dielectric(float cos_i, float eta) {
				cos_i = clamp(cos_i, 0.0, 1.0);
				float sin_t2 = eta * eta * (1.0 - cos_i * cos_i);
				if (sin_t2 >= 1.0) return 1.0;
				float cos_t = sqrt(1.0 - sin_t2);
				float rs = (eta * cos_i - cos_t) / (eta * cos_i + cos_t);
				float rp = (cos_i - eta * cos_t) / (cos_i + eta * cos_t);
				return 0.5 * (rs * rs + rp * rp);
			}

			float henyey_greenstein(float mu, float g) {
				float gg = g * g;
				return (1.0 - gg) / (4.0 * WATER_PI * pow(max(1.0 + gg - 2.0 * g * mu, 1e-4), 1.5));
			}

			// the water molecules' phase function, Rayleigh's with water's depolarization (Morel 1974)
			float water_molecular_phase(float mu) {
				return (1.0 + 0.835 * mu * mu) / (4.0 * WATER_PI * (1.0 + 0.835 / 3.0));
			}


			// ---------------------------------------------------------------
			// ocean waves
			// ---------------------------------------------------------------

			vec4 sample_wave_cascade(int cascade, vec2 world_xz, out float coverage) {
				coverage = 0.0;
				int tex = ocean_data.wave_tex[cascade];
				if (tex == -1) return vec4(0.0);
				vec4 origin = ocean_data.wave_origin[cascade];
				vec2 uv = (world_xz - origin.xy) * (0.5 / origin.z) + 0.5;
				vec2 edge = abs(uv - 0.5) * 2.0;
				coverage = 1.0 - smoothstep(0.75, 0.97, max(edge.x, edge.y));
				if (coverage <= 0.0) return vec4(0.0);
				return textureLod(TEXTURE(tex), uv, 0.0);
			}

			// the finest cascades the pixel resolves, blended over the coarser
			// ones. resolved_variance is the slope variance the result holds
			vec4 get_wave_data(vec2 world_xz, float footprint, out float resolved_variance) {
				vec4 data = vec4(0.0);
				resolved_variance = 0.0;

				for (int i = WAVE_CASCADES - 1; i >= 0; i--) {
					float coverage;
					vec4 cascade = sample_wave_cascade(i, world_xz, coverage);
					float texel = ocean_data.wave_origin[i].z * 2.0 / ]] .. WAVE_TEX_SIZE .. [[.0;
					// the cascade's shortest waves still resolve
					float weight = coverage * get_wave_resolve(texel * WAVE_TEXELS_PER_WAVELENGTH, footprint);
					data = mix(data, cascade, weight);
					resolved_variance = mix(resolved_variance, ocean_data.wave_origin[i].w, weight);
				}

				return data;
			}

			float get_water_surface_height(vec2 world_xz) {
				float variance;
				return ocean_data.ocean_level + get_wave_data(world_xz, 0.0, variance).r;
			}

			vec2 water_hash2(vec2 p) {
				vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
				p3 += dot(p3, p3.yzx + 33.33);
				return fract((p3.xx + p3.yz) * p3.zy) * 2.0 - 1.0;
			}

			// the gradient of quintic gradient noise. value noise's is
			// bilinear across each cell and its lattice shows as straight
			// edges, which caustics turn into triangles
			vec2 water_noise_gradient(vec2 p) {
				vec2 i = floor(p);
				vec2 f = p - i;
				vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
				vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
				vec2 ga = water_hash2(i);
				vec2 gb = water_hash2(i + vec2(1.0, 0.0));
				vec2 gc = water_hash2(i + vec2(0.0, 1.0));
				vec2 gd = water_hash2(i + vec2(1.0, 1.0));
				float va = dot(ga, f);
				float vb = dot(gb, f - vec2(1.0, 0.0));
				float vc = dot(gc, f - vec2(0.0, 1.0));
				float vd = dot(gd, f - vec2(1.0, 1.0));
				float k = va - vb - vc + vd;
				return ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) + du * (u.yx * k + vec2(vb, vc) - va);
			}

			// rms of the noise's gradient along one axis, per unit of p
			const float NOISE_GRADIENT_RMS = 0.5;
			// across the wind the ripples are longer
			const float RIPPLE_CROSSWIND_SCALE = 0.6;

			// octaves of noise ripples stretched across the wind, each half the
			// length and height of the last so all are as steep. they drift
			// with the flow and at their own phase speed, and two crossing
			// layers per octave make them change rather than slide. adds their
			// slope, and returns the slope variance of the octaves the pixel
			// can't resolve
			float add_ripples(vec2 p, float footprint, vec2 wind, vec2 flow, float amplitude, float wavelength, inout vec2 grad) {
				float lost_variance = 0.0;
				float time = ocean_data.time;
				vec2 across = vec2(-wind.y, wind.x);
				p -= flow * time;

				for (int o = 0; o < RIPPLE_OCTAVES; o++) {
					// a noise cell is half a wavelength
					float freq = 2.0 / wavelength;
					float slope = NOISE_GRADIENT_RMS * freq * amplitude;
					float resolve = get_wave_resolve(wavelength, footprint);
					lost_variance += 2.0 * (1.0 + RIPPLE_CROSSWIND_SCALE * RIPPLE_CROSSWIND_SCALE) * slope * slope * (1.0 - resolve);

					if (resolve > 0.0) {
						float speed = sqrt(WATER_GRAVITY * wavelength / 6.28318530718 + 0.074e-3 * 6.28318530718 / wavelength);
						vec2 scale = vec2(freq, freq * RIPPLE_CROSSWIND_SCALE);

						for (int layer = 0; layer < 2; layer++) {
							float angle = (layer == 0 ? 0.35 : -0.35) + float(o) * 0.9;
							vec2 dir = mat2(cos(angle), sin(angle), -sin(angle), cos(angle)) * wind;
							vec2 side = vec2(-dir.y, dir.x);
							vec2 q = vec2(dot(p, dir), dot(p, side)) * scale;
							q.x -= speed * freq * time;
							q += vec2(float(o) * 17.3, float(layer) * 41.7);
							vec2 n = water_noise_gradient(q);
							grad += (dir * (n.x * scale.x) + side * (n.y * scale.y)) * (amplitude * resolve);
						}
					}

					wavelength *= 0.5;
					amplitude *= 0.5;
				}

				return lost_variance;
			}

			// the ocean's ripples shorter than the finest cascade, with the
			// slope variance the spectrum has there
			float add_detail_ripples(vec2 p, float footprint, inout vec2 grad) {
				vec4 info = ocean_data.detail_info;
				float freq = 2.0 / info.z;
				float amplitude = sqrt(info.w / (2.0 * (1.0 + RIPPLE_CROSSWIND_SCALE * RIPPLE_CROSSWIND_SCALE))) / (NOISE_GRADIENT_RMS * freq);
				return add_ripples(p, footprint, info.xy, vec2(0.0), amplitude, info.z, grad);
			}

			float height_map_tracing(vec3 ray_dir, float plane_t, vec3 camera_origin, out vec3 hit_pos) {
				float wave_bound = ocean_data.ocean_wave_info.x;

				if (ocean_data.wave_tex[0] == -1) {
					hit_pos = ray_dir * plane_t;
					return plane_t;
				}

				float camera_height = camera_origin.y - get_water_surface_height(camera_origin.xz);
				float vertical_span = abs(camera_height) + wave_bound * 4.0;
				float search_radius = clamp(vertical_span / max(abs(ray_dir.y), 0.02), 8.0, 256.0);

				if (plane_t <= 0.0 && camera_height >= 0.0) {
					search_radius = min(search_radius, mix(24.0, 64.0, smoothstep(0.0, wave_bound * 1.7, camera_height)));
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

				for (int i = 0; i < 14; i++) {
					float tmid = 0.5 * (tm + tx);
					vec3 pmid = ray_dir * tmid;
					float hmid = (pmid.y + camera_origin.y) - get_water_surface_height(pmid.xz + camera_origin.xz);
					if (hmid * hm > 0.0) {
						tm = tmid;
						hm = hmid;
					} else {
						tx = tmid;
					}
				}

				float tfinal = 0.5 * (tm + tx);
				hit_pos = ray_dir * tfinal;
				return tfinal;
			}

			// ---------------------------------------------------------------
			// water volumes
			// ---------------------------------------------------------------

			// the entry and exit distances of the ray through volume i. the
			// entry is negative when the ray starts inside. top is whether it
			// enters through the surface
			bool intersect_volume(int i, vec3 ray_origin, vec3 ray_dir, out float t_entry, out float t_exit, out bool top) {
				mat4 to_local = ocean_data.volume_to_local[i];
				vec4 shape = ocean_data.volume_shape[i];
				vec3 origin = (to_local * vec4(ray_origin, 1.0)).xyz;
				vec3 dir = (to_local * vec4(ray_dir, 0.0)).xyz;
				dir = mix(dir, vec3(1e-7), lessThan(abs(dir), vec3(1e-7)));
				vec3 inv = 1.0 / dir;
				vec3 ta = (vec3(-shape.x, -shape.y, -shape.z) - origin) * inv;
				vec3 tb = (vec3(shape.x, 0.0, shape.z) - origin) * inv;
				vec3 tmin = min(ta, tb);
				vec3 tmax = max(ta, tb);
				t_entry = max(max(tmin.x, tmin.y), tmin.z);
				t_exit = min(min(tmax.x, tmax.y), tmax.z);
				top = tmin.y >= max(tmin.x, tmin.z) && dir.y < 0.0;
				return t_exit > max(t_entry, 0.0);
			}

			// how far a ray from inside volume i goes before it leaves it
			float get_volume_exit(int i, vec3 ray_origin, vec3 ray_dir) {
				float t_entry;
				float t_exit;
				bool top;
				if (!intersect_volume(i, ray_origin, ray_dir, t_entry, t_exit, top)) return 0.0;
				return t_exit;
			}

			// with a few centimeters to spare, for surfaces that line the box
			bool is_inside_volume(int i, vec3 p) {
				vec4 shape = ocean_data.volume_shape[i];
				vec3 local = (ocean_data.volume_to_local[i] * vec4(p, 1.0)).xyz;
				return all(lessThanEqual(abs(local.xz), shape.xz + 0.05)) && local.y <= 0.0 && local.y >= -shape.y - 0.05;
			}

			// the ripples on volume i, wave height is the significant height
			// of the longest ones
			float get_volume_ripples(int i, vec2 world_xz, float footprint, out vec2 grad) {
				vec4 waves = ocean_data.volume_waves[i];
				grad = vec2(0.0);
				if (waves.x <= 0.0) return 0.0;
				return add_ripples(world_xz, footprint, vec2(cos(waves.z), sin(waves.z)), ocean_data.volume_flow[i].xy, waves.x * 0.25, waves.y, grad);
			}

			// ---------------------------------------------------------------
			// the water body
			// ---------------------------------------------------------------

			struct Water {
				// -1 for the ocean, else the volume index
				int volume;
				vec3 absorption;
				// what's suspended in it, the water's own scattering is WATER_MOLECULAR_SCATTERING
				vec3 particles;
				float ior;
				float surface_y;
				float foam;
				float caustics;
				float roughness;
			};

			Water get_ocean_water() {
				Water w;
				w.volume = -1;
				w.absorption = ocean_data.ocean_absorption.rgb;
				w.particles = ocean_data.ocean_scattering.rgb;
				w.ior = ocean_data.ocean_absorption.w;
				w.surface_y = ocean_data.ocean_level;
				w.foam = ocean_data.ocean_scattering.w;
				w.caustics = ocean_data.ocean_wave_info.y;
				w.roughness = 0.0;
				return w;
			}

			Water get_volume_water(int i) {
				Water w;
				w.volume = i;
				w.absorption = ocean_data.volume_absorption[i].rgb;
				w.particles = ocean_data.volume_scattering[i].rgb;
				w.ior = ocean_data.volume_absorption[i].w;
				w.surface_y = ocean_data.volume_shape[i].w;
				w.foam = ocean_data.volume_waves[i].w;
				w.caustics = ocean_data.volume_flow[i].z;
				w.roughness = ocean_data.volume_scattering[i].w;
				return w;
			}

			vec3 get_extinction(Water w) {
				return w.absorption + WATER_MOLECULAR_SCATTERING + w.particles;
			}

			// per meter and steradian, what the water scatters by the cosine mu between where the light
			// went and where it goes
			vec3 water_scatter(Water w, float mu) {
				return WATER_MOLECULAR_SCATTERING * water_molecular_phase(mu) + w.particles * henyey_greenstein(mu, WATER_PARTICLE_G);
			}

			vec3 get_sun_illuminance() {
				float above_horizon = smoothstep(-0.02, 0.04, ocean_data.sun_direction.y);
				return ocean_data.primary_sun_color * (ocean_data.primary_sun_illuminance * above_horizon);
			}

			// direction the sunlight travels in once it's refracted into the
			// water, and how much of it gets through the flat surface
			vec3 get_underwater_sun_dir(Water w, out float transmission) {
				vec3 sun = normalize(ocean_data.sun_direction);
				float cos_i = max(sun.y, 0.0);
				transmission = 1.0 - fresnel_dielectric(cos_i, 1.0 / w.ior);
				vec3 refracted = refract(-sun, vec3(0.0, 1.0, 0.0), 1.0 / w.ior);
				return dot(refracted, refracted) > 0.0 ? normalize(refracted) : vec3(0.0, -1.0, 0.0);
			}

			vec3 get_sky_irradiance() {
				return sample_environment_irradiance(ocean_data.env_irradiance_tex, vec3(0.0, 1.0, 0.0));
			}

			// light arriving at depth z along a path, integrated over a straight
			// path of length len that starts depth_start below the surface and
			// goes down by rate per meter. mu is the cosine of the light in the
			// water. both exponentials are at most 1, so looking up from the
			// deep doesn't overflow. near x = 0, where the path climbs as fast as
			// the light fades with depth, their difference cancels to noise (a
			// ring at that elevation), so it's a series there. the depth isn't
			// clamped at the end: under a crest the path ends above the mean level
			vec3 integrate_attenuated(vec3 sigma, float depth_start, float rate, float len, float mu) {
				vec3 x = sigma * ((1.0 + rate / mu) * len);
				vec3 first = exp(-sigma * (depth_start / mu));
				vec3 last = exp(-sigma * (depth_start / mu) - x);
				vec3 series = first * (1.0 - x * (0.5 - x / 6.0));
				return len * mix((first - last) / x, series, lessThan(abs(x), vec3(1e-3)));
			}

			// what the water between origin and origin + dir * len adds by
			// scattering sun and sky light towards the viewer, and how much of
			// what's behind it gets through
			vec3 get_water_inscatter(Water w, vec3 origin, vec3 dir, float len, float jitter, out vec3 transmittance) {
				vec3 sigma = get_extinction(w);
				transmittance = exp(-sigma * len);
				float depth_start = max(w.surface_y - origin.y, 0.0);
				float rate = -dir.y;
				float sun_transmission;
				vec3 sun_dir = get_underwater_sun_dir(w, sun_transmission);
				float sun_mu = max(-sun_dir.y, 0.05);
				vec3 sun_light = get_sun_illuminance() * sun_transmission;
				float visibility = 0.0;

				// shadows over the first stretch of the path, which is where
				// the scattered light comes from. taa smooths the steps into
				// light shafts
				if (dot(sun_light, sun_light) > 0.0) {
					float shadow_len = min(len, 60.0);

					for (int i = 0; i < 4; i++) {
						float f = (float(i) + jitter) / 4.0;
						vec3 p = origin + dir * (shadow_len * f * f);
						// the light reaches p through the surface above it
						vec3 surface = p - sun_dir * ((p.y - w.surface_y) / sun_dir.y);
						visibility += get_water_sun_visibility(surface, ocean_data.sun_direction);
					}

					visibility *= 0.25;
				}

				// the light that reaches the viewer leaves along -dir
				vec3 sun_scatter = sun_light * visibility * water_scatter(w, dot(-dir, sun_dir)) * integrate_attenuated(sigma, depth_start, rate, len, sun_mu);
				// sky light comes down from all over the window above, as if at 40 degrees. the particles
				// send their backscattered share of it up to a viewer looking down, the rest on down to one
				// looking up; the molecules half each way
				float particle_share = mix(WATER_PARTICLE_BACKSCATTER, 1.0 - WATER_PARTICLE_BACKSCATTER, 0.5 + 0.5 * dir.y) / (2.0 * WATER_PI);
				vec3 sky_phase = WATER_MOLECULAR_SCATTERING / (4.0 * WATER_PI) + w.particles * particle_share;
				vec3 sky_scatter = get_sky_irradiance() * WATER_PI * sky_phase * integrate_attenuated(sigma, depth_start, rate, len, 0.75);
				return sun_scatter + sky_scatter;
			}

			// the lit scene under the surface was lit as if the water weren't
			// there. what the sun gives it is estimated from its albedo and
			// normal, dimmed by the water above and focused into caustics, and
			// the rest is dimmed like sky light
			vec3 relight_submerged(Water w, vec2 uv, vec3 scene_color, vec3 world_pos, float caustic) {
				float depth = w.surface_y - world_pos.y;
				if (depth <= 0.0) return scene_color;
				vec3 sigma = get_extinction(w);
				float sun_transmission;
				vec3 sun_dir = get_underwater_sun_dir(w, sun_transmission);
				vec3 normal = gbuffer_normal(uv);
				vec3 albedo = gbuffer_albedo(uv) * (1.0 - gbuffer_metallic(uv));
				float no_l = max(dot(normal, normalize(ocean_data.sun_direction)), 0.0);
				float shadow = get_water_sun_visibility(world_pos + normal * 0.1, ocean_data.sun_direction);
				vec3 direct = min(albedo / WATER_PI * get_sun_illuminance() * (no_l * shadow), scene_color);
				vec3 rest = scene_color - direct;
				vec3 sun_path = exp(-sigma * (depth / max(-sun_dir.y, 0.05)));
				vec3 sky_path = exp(-sigma * (depth / 0.75));
				return direct * sun_path * (sun_transmission * caustic) + rest * sky_path;
			}

			// the slope of the surface at xz, the ripples filtered for footprint
			vec2 get_surface_slope(Water w, vec2 xz, float footprint) {
				vec2 grad;

				if (w.volume >= 0) {
					get_volume_ripples(w.volume, xz, footprint, grad);
					return grad;
				}

				float variance;
				grad = get_wave_data(xz, footprint, variance).gb;
				add_detail_ripples(xz, footprint, grad);
				return grad;
			}

			// sunlight through a sloped surface lands offset by the slope times
			// depth * (1 - 1 / ior). where the offsets converge the light is
			// focused into caustics, by one over the jacobian determinant of
			// where it lands. the pattern is smoothed a little with depth,
			// deeper down the light arrives from a wider spread of ripples
			float get_caustic(Water w, vec3 world_pos, float footprint) {
				if (w.caustics <= 0.0) return 1.0;
				float sun_transmission;
				vec3 sun_dir = get_underwater_sun_dir(w, sun_transmission);
				float depth = max(w.surface_y - world_pos.y, 0.0);
				if (depth <= 0.0) return 1.0;
				// where the light that reaches world_pos came through the surface
				vec2 xz = world_pos.xz - sun_dir.xz * (depth / max(-sun_dir.y, 0.05));
				float filter_size = max(footprint, depth * 0.012);
				float e = filter_size;
				vec2 gx = get_surface_slope(w, xz + vec2(e, 0.0), filter_size) - get_surface_slope(w, xz - vec2(e, 0.0), filter_size);
				vec2 gz = get_surface_slope(w, xz + vec2(0.0, e), filter_size) - get_surface_slope(w, xz - vec2(0.0, e), filter_size);
				float s = depth * (1.0 - 1.0 / w.ior) / (2.0 * e);
				float jacobian = (1.0 + s * gx.x) * (1.0 + s * gz.y) - s * gx.y * s * gz.x;
				float intensity = 1.0 / max(abs(jacobian), 0.2);
				// the sun's disc blurs them deeper down, and so does distance
				float blur = clamp(smoothstep(4.0, 30.0, depth) + smoothstep(0.3, 2.0, footprint), 0.0, 1.0);
				return mix(1.0, mix(intensity, 1.0, blur), clamp(w.caustics, 0.0, 1.0));
			}

			// ---------------------------------------------------------------
			// reflections
			// ---------------------------------------------------------------

			float scene_depth_at(vec2 uv) {
				return textureLod(TEXTURE(ocean_data.depth_tex), uv, 0.0).r;
			}

			// marches the reflected ray through the depth buffer. the lit scene
			// where it meets something is what the water reflects there
			// hit_uv is where on screen, hit_t how far along dir, weight how far from the screen's edge
			bool trace_water_reflection(vec3 origin, vec3 dir, float jitter, out vec2 hit_uv, out float hit_t, out float weight) {
				float previous = 0.0;
				hit_uv = vec2(0.0);
				hit_t = 0.0;
				weight = 0.0;

				for (int i = 1; i <= 24; i++) {
					float f = (float(i) - jitter) / 24.0;
					float t = WATER_SSR_DISTANCE * f * f;
					vec3 p = screen_refraction_project(origin + dir * t);

					if (!screen_refraction_on_screen(p.xy)) return false;

					float depth = scene_depth_at(p.xy);

					if (depth < 1.0 && p.z >= depth) {
						float near = previous;
						float far = t;

						for (int j = 0; j < 6; j++) {
							float middle = (near + far) * 0.5;
							vec3 pm = screen_refraction_project(origin + dir * middle);

							if (pm.z >= scene_depth_at(pm.xy)) {
								far = middle;
							} else {
								near = middle;
							}
						}

						vec3 hit = screen_refraction_project(origin + dir * far);
						vec3 ray_pos = origin + dir * far;
						vec3 scene_pos = get_world_pos(hit.xy, scene_depth_at(hit.xy));

						// it went behind something instead of into it
						if (length(scene_pos - ray_pos) > max(0.4, far * 0.04)) return false;

						vec2 edge = min(hit.xy, 1.0 - hit.xy);
						hit_uv = hit.xy;
						hit_t = far;
						weight = smoothstep(0.0, 0.06, min(edge.x, edge.y));
						return true;
					}

					previous = t;
				}

				return false;
			}

			// where a traced reflection may reach, far enough for a coast across the water
			const float WATER_REFLECTION_TRACE_DISTANCE = 20000.0;

			vec3 get_reflection(vec3 surface_pos, vec3 view_dir, vec3 reflection_dir, vec3 normal, float alpha, float jitter) {
				float perceptual = sqrt(alpha);
				vec3 reflected = sample_environment_specular(ocean_data.env_tex, reflection_dir, normal, perceptual);
				float ssr_fade = reflection_dir.y > -0.2 ? 1.0 - smoothstep(0.1, 0.35, perceptual) : 0.0;
				vec3 origin = surface_pos + normal * 0.02;
				vec3 ssr_color = vec3(0.0);
				float ssr_weight = 0.0;
				vec2 ssr_uv;
				float ssr_t;

				if (ssr_fade > 0.0 && trace_water_reflection(origin, reflection_dir, jitter, ssr_uv, ssr_t, ssr_weight)) {
					ssr_color = get_scene_color(ssr_uv);
					ssr_weight *= ssr_fade;
				}

				#ifdef SCENE_REFLECTION
				// what the screen doesn't hold is traced, at any roughness: a ray per pixel through the
				// waves' unresolved slopes, which ocean_resolve averages into the blurred reflection
				if (ssr_weight < 0.999 && scene_reflection_ready()) {
					vec3 dir = reflection_dir;

					if (perceptual > 0.1) {
						vec3 up = abs(normal.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
						vec3 T = normalize(cross(up, normal));
						vec3 B = cross(normal, T);
						vec3 V_local = vec3(dot(view_dir, T), dot(view_dir, B), dot(view_dir, normal));
						vec3 H_local = ImportanceSampleGGXVNDF(V_local, alpha, get_blue_noise2());
						dir = reflect(-view_dir, normalize(T * H_local.x + B * H_local.y + normal * H_local.z));
						// like the mirror direction, reflections dip under the horizon on the backs of waves
						if (dir.y < 0.0) dir = normalize(vec3(dir.x, -dir.y * 0.3, dir.z));
					}

					float traced_t;
					vec3 traced = trace_scene_reflection(origin, dir, normal, perceptual, WATER_REFLECTION_TRACE_DISTANCE, traced_t);
					return mix(traced, ssr_color, ssr_weight);
				}
				#endif

				return mix(reflected, ssr_color, ssr_weight);
			}

			// ---------------------------------------------------------------
			// shading
			// ---------------------------------------------------------------

			// the scene seen through the surface, and how far that is through the
			// water. only the ripples' bending is followed: the pixel straight
			// behind is shifted by how far the rippled refraction strays from a
			// flat surface's by the time it reaches the scene. the flat
			// refraction itself (the floor looking raised) can't be done in
			// screen space: where it would land off screen or behind something
			// in front of the water there is nothing to show, and falling back
			// there tore the image apart
			vec3 get_refracted_scene(Water w, vec3 surface_pos, vec3 ray_dir, vec3 normal, float scene_distance, out float path_len, out vec3 floor_pos, out vec2 floor_uv, out bool has_floor) {
				path_len = WATER_OPEN_DEPTH;
				has_floor = false;
				floor_uv = in_uv;
				floor_pos = surface_pos;
				vec3 flat_dir = normalize(refract(ray_dir, vec3(0.0, 1.0, 0.0), 1.0 / w.ior));
				vec3 bent_dir = refract(ray_dir, normal, 1.0 / w.ior);
				if (dot(bent_dir, bent_dir) <= 0.0) bent_dir = flat_dir;
				float volume_exit = w.volume >= 0 ? get_volume_exit(w.volume, surface_pos + flat_dir * 0.001, flat_dir) : WATER_OPEN_DEPTH;

				if (scene_distance >= 1e29) {
					path_len = volume_exit;
					return w.volume >= 0 ? get_scene_color(in_uv) : vec3(0.0);
				}

				vec3 straight = surface_pos + ray_dir * scene_distance;
				vec3 bent = screen_refraction_project(straight + (normalize(bent_dir) - flat_dir) * scene_distance);

				if (bent.z > -1.0) {
					vec2 uv = clamp(bent.xy, vec2(0.001), vec2(0.999));

					// something in front of the water is where the shift lands
					if (scene_depth_at(uv) >= screen_refraction_project(surface_pos).z) floor_uv = uv;
				}

				float depth = scene_depth_at(floor_uv);

				if (depth >= 1.0) {
					path_len = volume_exit;
					return w.volume >= 0 ? get_scene_color(floor_uv) : vec3(0.0);
				}

				floor_pos = get_world_pos(floor_uv, depth);
				// the scene straight behind may be further than where the
				// refracted ray leaves the volume, so it's the point that counts
				has_floor = w.volume < 0 || is_inside_volume(w.volume, floor_pos);
				path_len = has_floor ? length(floor_pos - surface_pos) : volume_exit;
				return get_scene_color(floor_uv);
			}

			vec3 shade_surface_from_above(Water w, vec3 surface_pos, vec3 normal, float alpha, float fold, vec3 ray_dir, float t, float scene_distance, float jitter) {
				vec3 view_dir = -ray_dir;
				float no_v = max(dot(normal, view_dir), 1e-4);
				float fresnel = fresnel_dielectric(no_v, 1.0 / w.ior);
				vec3 reflection_dir = reflect(ray_dir, normal);
				// reflections dip under the horizon on the backs of waves
				if (reflection_dir.y < 0.0) reflection_dir = normalize(vec3(reflection_dir.x, -reflection_dir.y * 0.3, reflection_dir.z));
				vec3 reflection = get_reflection(surface_pos, view_dir, reflection_dir, normal, alpha, jitter);

				// refraction into the water body
				float path_len;
				vec3 floor_pos;
				vec2 floor_uv;
				bool has_floor;
				vec3 behind = get_refracted_scene(w, surface_pos, ray_dir, normal, scene_distance, path_len, floor_pos, floor_uv, has_floor);
				// the water between the surface and what's behind it
				vec3 refracted_dir = has_floor ? normalize(floor_pos - surface_pos) : normalize(refract(ray_dir, vec3(0.0, 1.0, 0.0), 1.0 / w.ior));
				refracted_dir.y = min(refracted_dir.y, -0.02);
				refracted_dir = normalize(refracted_dir);
				float footprint = get_pixel_footprint(t, ray_dir.y);

				if (has_floor) behind = relight_submerged(w, floor_uv, behind, floor_pos, get_caustic(w, floor_pos, footprint));

				vec3 transmittance;
				vec3 inscatter = get_water_inscatter(w, surface_pos, refracted_dir, path_len, jitter, transmittance);
				vec3 transmitted = behind * transmittance + inscatter;

				// sun glint off the waves, rough with the waves too small to see
				vec3 sun = normalize(ocean_data.sun_direction);
				float shadow = get_water_sun_visibility(surface_pos, sun);
				vec3 sun_light = get_sun_illuminance() * shadow;
				float no_l = max(dot(normal, sun), 0.0);
				vec3 half_dir = normalize(view_dir + sun);
				float no_h = max(dot(normal, half_dir), 0.0);
				float glint_alpha = sqrt(alpha * alpha + SUN_ANGULAR_RADIUS * SUN_ANGULAR_RADIUS);
				float specular = D_GGXAlpha(glint_alpha, no_h) * V_SmithGGXCorrelated(glint_alpha, no_v, no_l) * fresnel_dielectric(max(dot(view_dir, half_dir), 0.0), 1.0 / w.ior);
				vec3 color = mix(transmitted, reflection, fresnel) + sun_light * (specular * no_l);

				// light through the thin tops of waves between the viewer and the sun
				if (w.volume < 0) {
					float sun_transmission;
					vec3 sun_dir = get_underwater_sun_dir(w, sun_transmission);
					float crest = clamp((surface_pos.y - w.surface_y) / max(ocean_data.ocean_wave_info.x, 0.05), 0.0, 1.0);
					vec3 sigma = get_extinction(w);
					float thickness = 1.5;
					color += (1.0 - fresnel) * sun_light * sun_transmission * water_scatter(w, dot(-refracted_dir, sun_dir)) * thickness * exp(-sigma * thickness) * crest * crest * 4.0;
				}

				// foam: whitecaps where the waves fold, and along shores and
				// around things in the water
				// the depth of the water under the surface. what's seen through it is only that at steep views,
				// at grazing ones it lies far off toward the shore, so a floor further away counts as deeper
				float shore_range = 0.25 * w.foam;
				float shore_depth = has_floor ? max(w.surface_y - floor_pos.y, length(floor_pos.xz - surface_pos.xz) * 0.5) : 1e3;
				#ifdef SCENE_REFLECTION
				if (scene_reflection_ready() && shore_range > 0.0) shore_depth = scene_hit_distance(surface_pos, vec3(0.0, -1.0, 0.0), shore_range);
				#endif
				float pattern = foam_pattern(surface_pos.xz, ocean_data.time);
				float whitecap = smoothstep(0.2, 0.75, fold);
				float shore = smoothstep(shore_range, 0.0, shore_depth);
				// the more foam, the more of the bubble pattern shows
				float coverage = clamp((whitecap + shore) * w.foam, 0.0, 1.0);
				float foam = smoothstep(1.0 - coverage, 1.15 - coverage, pattern) * 0.95;

				if (foam > 0.0) {
					vec3 foam_light = sun_light * (max(dot(vec3(0.0, 1.0, 0.0), sun), 0.0) / WATER_PI) + get_sky_irradiance();
					color = mix(color, vec3(0.9) * foam_light, foam);
				}

				return color;
			}

			// the surface seen from under the water: what's above comes through
			// snell's window, outside it the water reflects its own depths
			// the light at a submerged point of the scene, relative to above the water: the sun's path
			// down through the water to it, for a traced hit that was lit as if there were none
			vec3 get_submerged_light(Water w, vec3 world_pos) {
				float sun_transmission;
				vec3 sun_dir = get_underwater_sun_dir(w, sun_transmission);
				return sun_transmission * exp(-get_extinction(w) * (max(w.surface_y - world_pos.y, 0.0) / max(-sun_dir.y, 0.05)));
			}

			// what the surface reflects back down into the water: the underwater scene along the
			// mirrored ray, seen through the water like the view straight into it. off the screen it's
			// traced; what's hit there was lit without the water, so it is dimmed by its depth
			vec3 get_underwater_reflection(Water w, vec3 surface_pos, vec3 dir, float jitter) {
				vec3 origin = surface_pos + dir * 0.02;
				// a volume's walls are usually right on its sides, so what's hit a little past where the
				// ray leaves it still counts
				float len = w.volume >= 0 ? get_volume_exit(w.volume, origin, dir) + 0.25 : WATER_OPEN_DEPTH;
				vec3 behind = vec3(0.0);
				vec2 hit_uv;
				float hit_t;
				float weight;

				if (trace_water_reflection(origin, dir, jitter, hit_uv, hit_t, weight) && hit_t < len) {
					vec3 scene_pos = get_world_pos(hit_uv, scene_depth_at(hit_uv));
					float footprint = get_pixel_footprint(length(scene_pos - ocean_data.camera_position.xyz), 1.0);
					behind = relight_submerged(w, hit_uv, get_scene_color(hit_uv), scene_pos, get_caustic(w, scene_pos, footprint));
					len = hit_t;
				} else {
					weight = 0.0;
				}

				#ifdef SCENE_REFLECTION
				if (weight < 0.999 && scene_reflection_ready()) {
					float traced_t;
					vec3 traced = trace_scene_reflection(origin, dir, -dir, 0.0, len, traced_t);

					if (traced_t < len) {
						behind = mix(traced * get_submerged_light(w, origin + dir * traced_t), behind, weight);
						if (weight <= 0.0) len = traced_t;
					}
				}
				#endif

				vec3 transmittance;
				vec3 inscatter = get_water_inscatter(w, origin, dir, len, jitter, transmittance);
				return behind * transmittance + inscatter;
			}

			vec3 shade_surface_from_below(Water w, vec3 surface_pos, vec3 normal_up, vec3 ray_dir, float jitter) {
				vec3 normal = -normal_up;
				vec3 view_dir = -ray_dir;
				float fresnel = fresnel_dielectric(dot(normal, view_dir), w.ior);
				vec3 above = vec3(0.0);

				if (fresnel < 1.0) {
					vec3 refracted_dir = normalize(refract(ray_dir, normal, w.ior));
					above = sample_environment_specular(ocean_data.env_tex, refracted_dir, normal_up, 0.05);
					bool traced = false;

					// from below, what's above the water is mostly hidden on screen, behind the parts
					// of things under it (the top of something floating), so it's traced where it can be
					#ifdef SCENE_REFLECTION
					if (scene_reflection_ready()) {
						float traced_t;
						above = trace_scene_reflection(surface_pos + normal_up * 0.02, refracted_dir, normal_up, 0.05, WATER_REFLECTION_TRACE_DISTANCE, traced_t);
						traced = true;
					}
					#endif

					vec2 uv;
					float hit;

					// only what the ray really met: where it stopped without meeting anything the screen
					// holds something else
					if (!traced && screen_refraction_trace(surface_pos, surface_pos, refracted_dir, 200.0, jitter, uv, hit) && hit < 200.0) {
						if (scene_depth_at(uv) < 1.0) above = get_scene_color(uv);
					}

					vec3 sun = normalize(ocean_data.sun_direction);
					float cos_sun = dot(refracted_dir, sun);
					above += get_sun_illuminance() * get_water_sun_visibility(surface_pos, sun) * smoothstep(0.9995, 0.99995, cos_sun) * 2000.0;
				}

				vec3 depths = get_underwater_reflection(w, surface_pos, reflect(ray_dir, normal), jitter);
				return mix(above, depths, fresnel);
			}

			// looking from inside the water along ray_dir: through surface_t of
			// water to the surface (or -1 when the ray doesn't reach it) or
			// to whatever is behind
			vec3 shade_underwater(Water w, vec3 camera, vec3 ray_dir, float surface_t, vec3 surface_normal, float exit_t, float scene_t, vec3 scene_color, vec3 scene_pos, float jitter, out float distance) {
				float len;
				vec3 behind;

				if (surface_t > 0.0 && surface_t < scene_t) {
					len = surface_t;
					behind = shade_surface_from_below(w, camera + ray_dir * surface_t, surface_normal, ray_dir, jitter);
					distance = surface_t;
				} else if (scene_t < exit_t) {
					len = scene_t;
					float footprint = get_pixel_footprint(scene_t, 1.0);
					float caustic = get_caustic(w, scene_pos, footprint);
					behind = relight_submerged(w, in_uv, scene_color, scene_pos, caustic);
					distance = scene_t;
				} else {
					// out of the side or the bottom of a volume, or into the
					// open ocean
					len = exit_t;
					behind = w.volume >= 0 ? scene_color : vec3(0.0);
					distance = w.volume >= 0 ? -1.0 : -1.0;
				}

				vec3 transmittance;
				vec3 inscatter = get_water_inscatter(w, camera, ray_dir, len, jitter, transmittance);
				return behind * transmittance + inscatter;
			}

			void write_passthrough(vec3 scene_color) {
				set_scene_color(scene_color, -1.0);
				set_ocean_distance(vec2(-1.0));
			}

			void main() {
				vec3 scene_color = get_scene_color(in_uv);

				if (ocean_data.scene_tex == -1 || (ocean_data.ocean_enabled == 0 && ocean_data.volume_count == 0)) {
					write_passthrough(scene_color);
					return;
				}

				float scene_depth = gbuffer_depth(in_uv);
				vec3 camera_origin = ocean_data.camera_position.xyz;
				vec3 ray_dir = get_view_ray(in_uv);
				vec3 scene_pos = camera_origin + ray_dir * 1e30;
				float scene_t = 1e30;
				float jitter = get_blue_noise();

				if (scene_depth < 1.0) {
					scene_pos = get_world_pos(in_uv, scene_depth);
					scene_t = dot(scene_pos - camera_origin, ray_dir);
				}

				// the nearest volume along the ray
				int volume = -1;
				float volume_entry = 1e30;
				float volume_exit = 0.0;
				bool volume_top = false;

				for (int i = 0; i < ocean_data.volume_count; i++) {
					float t_entry;
					float t_exit;
					bool top;

					if (intersect_volume(i, camera_origin, ray_dir, t_entry, t_exit, top)) {
						t_entry = max(t_entry, 0.0);

						if (t_entry < volume_entry && t_entry < scene_t) {
							volume = i;
							volume_entry = t_entry;
							volume_exit = t_exit;
							volume_top = top;
						}
					}
				}

				// the ocean along the ray
				bool camera_under_ocean = false;
				float ocean_t = -1.0;
				vec3 ocean_local_pos = vec3(0.0);

				if (ocean_data.ocean_enabled != 0) {
					float wave_bound = ocean_data.ocean_wave_info.x;
					float camera_surface_delta = camera_origin.y - get_water_surface_height(camera_origin.xz);
					camera_under_ocean = camera_surface_delta < 0.0;
					float trace_plane_y = ocean_data.ocean_level + (camera_under_ocean ? -wave_bound : wave_bound);
					float denom = abs(ray_dir.y) < 1e-5 ? 1e-5 : ray_dir.y;
					float plane_t = (trace_plane_y - camera_origin.y) / denom;
					float trace_anchor_t = plane_t > 0.0 ? plane_t : -1.0;

					if (trace_anchor_t <= 0.0 && abs(camera_surface_delta) <= wave_bound * 1.7) {
						trace_anchor_t = 0.0;
					}

					// under the water the surface is above: marched from the camera when it is between the
					// troughs and the crests, where the plane of the troughs is behind it
					if (camera_under_ocean && trace_anchor_t < 0.0) trace_anchor_t = ray_dir.y > 0.0 ? 0.0 : -1.0;

					if (trace_anchor_t >= 0.0) {
						ocean_t = height_map_tracing(ray_dir, trace_anchor_t, camera_origin, ocean_local_pos);
					}
				}

				bool ocean_first = camera_under_ocean || (ocean_t > 0.0 && ocean_t < scene_t);
				float ocean_entry = camera_under_ocean ? 0.0 : ocean_t;

				// a volume in front of the ocean, or the camera in one
				if (volume >= 0 && (!ocean_first || volume_entry < ocean_entry || (volume_entry == 0.0 && !camera_under_ocean))) {
					Water w = get_volume_water(volume);
					vec3 color;
					float distance;

					if (volume_entry <= 0.0) {
						// in the volume: the surface above is where the ray
						// leaves through the top
						float surface_t = ray_dir.y > 1e-4 ? (w.surface_y - camera_origin.y) / ray_dir.y : -1.0;
						if (surface_t > volume_exit + 1e-3) surface_t = -1.0;
						vec3 normal_up = vec3(0.0, 1.0, 0.0);

						if (surface_t > 0.0) {
							vec3 p = camera_origin + ray_dir * surface_t;
							vec2 grad;
							get_volume_ripples(volume, p.xz, get_pixel_footprint(surface_t, ray_dir.y), grad);
							normal_up = normalize(vec3(-grad.x, 1.0, -grad.y));
						}

						color = shade_underwater(w, camera_origin, ray_dir, surface_t, normal_up, volume_exit, scene_t, scene_color, scene_pos, jitter, distance);
						set_scene_color(color, 1.0);
						set_ocean_distance(vec2(distance, 0.0));
						return;
					}

					vec3 surface_pos = camera_origin + ray_dir * volume_entry;

					if (!volume_top) {
						// into the side of the volume, like through the glass of a tank
						float len = min(scene_t, volume_exit) - volume_entry;
						vec3 behind = scene_color;

						if (scene_t < volume_exit) {
							float footprint = get_pixel_footprint(scene_t, 1.0);
							float caustic = get_caustic(w, scene_pos, footprint);
							behind = relight_submerged(w, in_uv, scene_color, scene_pos, caustic);
						}

						vec3 transmittance;
						vec3 inscatter = get_water_inscatter(w, surface_pos, ray_dir, len, jitter, transmittance);
						set_scene_color(behind * transmittance + inscatter, 1.0);
						set_ocean_distance(vec2(volume_entry));
						return;
					}

					float footprint = get_pixel_footprint(volume_entry, ray_dir.y);
					vec2 grad;
					float lost_variance = get_volume_ripples(volume, surface_pos.xz, footprint, grad);
					vec3 normal = normalize(vec3(-grad.x, 1.0, -grad.y));
					float alpha = sqrt(w.roughness * w.roughness + lost_variance);
					color = shade_surface_from_above(w, surface_pos, normal, alpha, 0.0, ray_dir, volume_entry, scene_t < 1e29 ? max(scene_t - volume_entry, 0.0) : 1e30, jitter);
					set_scene_color(color, 1.0);
					set_ocean_distance(vec2(volume_entry));
					return;
				}

				if (!ocean_first) {
					write_passthrough(scene_color);
					return;
				}

				Water w = get_ocean_water();

				if (camera_under_ocean) {
					vec3 normal_up = vec3(0.0, 1.0, 0.0);
					float surface_t = ocean_t > 0.0 ? ocean_t : -1.0;

					if (surface_t > 0.0) {
						vec3 p = camera_origin + ocean_local_pos;
						float footprint = get_pixel_footprint(surface_t, ray_dir.y);
						float variance;
						vec4 wd = get_wave_data(p.xz, footprint, variance);
						vec2 grad = wd.gb;
						add_detail_ripples(p.xz, footprint, grad);
						normal_up = normalize(vec3(-grad.x, 1.0, -grad.y));
					}

					float distance;
					vec3 color = shade_underwater(w, camera_origin, ray_dir, surface_t, normal_up, WATER_OPEN_DEPTH, scene_t, scene_color, scene_pos, jitter, distance);
					set_scene_color(color, 1.0);
					set_ocean_distance(vec2(distance, 0.0));
					return;
				}

				vec3 surface_pos = camera_origin + ocean_local_pos;
				float footprint = get_pixel_footprint(ocean_t, ray_dir.y);
				float resolved_variance;
				vec4 wd = get_wave_data(surface_pos.xz, footprint, resolved_variance);
				vec2 grad = wd.gb;
				float detail_lost = add_detail_ripples(surface_pos.xz, footprint, grad);
				float detail_total = ocean_data.detail_info.w * float(RIPPLE_OCTAVES);

				// the slopes of the sea no wave here shows make up the roughness,
				// so the whole matches cox and munk's for the wind
				float unresolved = max(ocean_data.ocean_wave_info.z - resolved_variance - (detail_total - detail_lost), 0.0) ;
				float alpha = sqrt(max(unresolved, 4e-4));
				vec3 normal = normalize(vec3(-grad.x, 1.0, -grad.y));
				vec3 color = shade_surface_from_above(w, surface_pos, normal, alpha, wd.a, ray_dir, ocean_t, scene_t < 1e29 ? max(scene_t - ocean_t, 0.0) : 1e30, jitter);
				set_scene_color(color, 1.0);
				set_ocean_distance(vec2(ocean_t));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	}
)
list.insert(
	passes,
	{
		name = "ocean_resolve",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		dont_create_framebuffers = true,
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
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						post_source.WritePreExposureBlock(self, block)

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

						local prev_view = render3d.GetPreviousViewMatrix()
						local prev_projection = render3d.GetPreviousProjectionMatrix()

						if prev_view then
							prev_view:CopyToFloatPointer(block.prev_view)
						else
							render3d.GetCamera():BuildViewMatrix():CopyToFloatPointer(block.prev_view)
						end

						if prev_projection then
							prev_projection:CopyToFloatPointer(block.prev_projection)
						else
							render3d.GetCamera():BuildProjectionMatrix():CopyToFloatPointer(block.prev_projection)
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

			]] .. post_source.GetPreExposureGLSL("ocean_resolve_data") .. [[

			// last frame's ocean was pre-exposed for last frame
			vec4 get_history_ocean(vec2 uv) {
				if (ocean_resolve_data.history_ocean_tex == -1) return vec4(0.0, 0.0, 0.0, -1.0);
				vec4 history = texture(TEXTURE(ocean_resolve_data.history_ocean_tex), uv);
				return vec4(history.rgb * (get_pre_exposure() / get_previous_pre_exposure()), history.a);
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
				float clamp_diff = length(history.rgb - clamped_rgb) / max(max(m1.r, max(m1.g, m1.b)), 1e-4);
				float blend = 0.9 * (1.0 - clamp(clamp_diff * 2.0, 0.0, 1.0));

				set_color(vec4(mix(current.rgb, clamped_rgb, blend), current.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	}
)
return passes
