local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local eye_psf = import("goluwa/render3d/eye_psf.lua")
local eye_glare = import("goluwa/render3d/eye_glare.lua")
local lens = import("goluwa/render3d/lens.lua")
local Texture = import("goluwa/render/texture.lua")
local ffi = require("ffi")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local TILE_SCALE = 1 / 32
local SOURCES = 16
local SELECT_THREADS = 256
local SOURCE_BINS = 64
local SOURCE_MIN_LOG2 = 4
local SOURCE_BIN_STOPS = 0.75
local STAR_SPREAD_ENTRIES = 256
local STAR_SPREAD_MIN_DEGREES = 0.05
local STAR_SPREAD_MAX_DEGREES = 30
local TRACE_ROWS = lens.TRACE_SOURCES * lens.MAX_GHOSTS * 3
local TRACE_QUADS = (lens.TRACE_GRID - 1) * (lens.TRACE_GRID - 1)
local MIN_CELL_PIXELS = 0.25
local MAX_INSTANCES = SOURCES * lens.MAX_GHOSTS
local INSTANCE_TEXELS = 4
local VISIBLE_IRRADIANCE = 1e-4
local PRIMITIVES_PER_ROW = 512
local PRIMITIVE_ROWS = 64
local PSF_THREADS = 256
local BLOOM_LEVELS = 10
local BLOOM_MIN_PIXELS = 1.5
local lens_flare = {}
lens_flare.SOURCES = SOURCES
lens_flare.STAR_SPREAD_ENTRIES = STAR_SPREAD_ENTRIES
lens_flare.STAR_SPREAD_MIN_DEGREES = STAR_SPREAD_MIN_DEGREES
lens_flare.STAR_SPREAD_MAX_DEGREES = STAR_SPREAD_MAX_DEGREES

function lens_flare.GetEffectiveFocalLength(built)
	local size = render.GetRenderImageSize()
	return lens.GetFrameHalfHeight(built, size.x, size.y) / math.tan(render3d.GetCamera():GetFOV() / 2)
end

function lens_flare.WriteLensBlock(self, block, built)
	lens.WriteBlock(block, built, self:GetTextureIndex(lens_flare.GetTextures(built).aperture))
	block.lens_effective_focal = lens_flare.GetEffectiveFocalLength(built)
	return block
end

function lens_flare.GetLens()
	if exposure_model.IsEye() then return nil end

	return lens.GetBuilt()
end

local function make_texture(width, height, format, data, wrap_s)
	return Texture.New{
		width = width,
		height = height,
		format = format,
		buffer = data,
		image = {usage = {"storage", "sampled", "transfer_src", "transfer_dst"}},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = wrap_s or "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
end

do
	local optics_textures = setmetatable({}, {__mode = "k"})
	local aperture = {}

	function lens_flare.GetTextures(built)
		local optics = getmetatable(built).__index
		local found = optics_textures[optics]

		if not found then
			found = {
				ghosts = make_texture(lens.GHOST_TEXELS, lens.MAX_GHOSTS, "r32g32b32a32_sfloat", optics.ghost_data),
				surfaces = make_texture(3, optics.table_height, "r32g32b32a32_sfloat", optics.table_data),
				warp = make_texture(lens.WARP_ENTRIES, 1, "r32g32b32a32_sfloat", optics.warp),
				chief = make_texture(lens.VIGNETTE_FIELDS, 1, "r32_sfloat", optics.vignette_chief),
			}
			optics_textures[optics] = found
		end

		if aperture.built ~= built then
			if aperture.texture then
				aperture.texture:Upload{width = lens.APERTURE_ENTRIES, height = 1, buffer = built.polygon}
			else
				aperture.texture = make_texture(lens.APERTURE_ENTRIES, 1, "r32_sfloat", built.polygon, "repeat")
				aperture.vignette = make_texture(
					lens.VIGNETTE_FIELDS,
					lens.VIGNETTE_APERTURES,
					"r32_sfloat",
					ffi.new("float[?]", lens.VIGNETTE_FIELDS * lens.VIGNETTE_APERTURES)
				)
			end

			aperture.built = built
			aperture.vignette_ready = false
		end

		found.aperture = aperture.texture
		found.vignette = aperture.vignette
		return found
	end

	function lens_flare.IsVignetteReady(built)
		lens_flare.GetTextures(built)
		return aperture.vignette_ready
	end

	function lens_flare.MarkVignetteReady()
		aperture.vignette_ready = true
	end

	local psf = {}

	local function get_targets(kind)
		local targets = psf[kind]

		if targets then return targets end

		targets = {
			modulation = make_texture(
				eye_psf.ANGLES,
				eye_psf.RADII,
				"r32_sfloat",
				ffi.new("float[?]", eye_psf.ANGLES * eye_psf.RADII),
				"repeat"
			),
			spread = make_texture(
				STAR_SPREAD_ENTRIES,
				1,
				"r32g32b32a32_sfloat",
				ffi.new("float[?]", STAR_SPREAD_ENTRIES * 4)
			),
		}
		psf[kind] = targets
		return targets
	end

	function lens_flare.GetStarTextures()
		return get_targets("star")
	end

	local function get_dirt_key()
		local dust, scratches = lens.Get("lens.dust"), lens.Get("lens.scratches")

		if dust <= 0 and scratches <= 0 then return nil end

		return lens.Get("lens.seed") .. "/" .. dust .. "/" .. scratches
	end

	function lens_flare.GetDirtTextures()
		if not get_dirt_key() then return nil end

		return get_targets("dirt")
	end

	function lens_flare.GetPSFTexture(name)
		local found = psf[name]

		if found then return found end

		if name == "field" then
			found = make_texture(eye_psf.GRID, eye_psf.GRID, "r32g32_sfloat")
		elseif name == "row_energy" then
			found = make_texture(eye_psf.GRID, 1, "r32_sfloat")
		elseif name == "raw" then
			found = make_texture(eye_psf.ANGLES, eye_psf.RADII, "r32_sfloat")
		elseif name == "ring_means" then
			found = make_texture(eye_psf.RADII, 1, "r32_sfloat")
		elseif name == "primitives" then
			found = make_texture(
				PRIMITIVES_PER_ROW * 2,
				PRIMITIVE_ROWS,
				"r32g32b32a32_sfloat",
				ffi.new("float[?]", PRIMITIVES_PER_ROW * 2 * PRIMITIVE_ROWS * 4)
			)
		end

		psf[name] = found
		return found
	end

	local job_serial, job

	function lens_flare.GetPSFJob()
		if job_serial == render.frame_serial then return job end

		job_serial = render.frame_serial
		job = nil
		local built = lens_flare.GetLens()

		if not built then return nil end

		local star = get_targets("star")

		if star.key ~= built.aperture_key then
			job = {kind = "star", key = built.aperture_key, built = built, targets = star}
			return job
		end

		local dirt_key = get_dirt_key()
		local dirt = dirt_key and get_targets("dirt")

		if dirt and dirt.key ~= dirt_key then
			local data, count = lens.BuildDirtPrimitives(lens.Get("lens.seed"), lens.Get("lens.dust"), lens.Get("lens.scratches"))
			count = math.min(count, PRIMITIVES_PER_ROW * PRIMITIVE_ROWS)
			local padded = ffi.new("float[?]", PRIMITIVES_PER_ROW * 2 * PRIMITIVE_ROWS * 4)
			ffi.copy(padded, data, count * 8 * 4)
			lens_flare.GetPSFTexture("primitives"):Upload{
				width = PRIMITIVES_PER_ROW * 2,
				height = PRIMITIVE_ROWS,
				buffer = padded,
			}
			job = {kind = "dirt", key = dirt_key, targets = dirt, count = count}
		end

		return job
	end
end

local function is_ghosts_enabled()
	return lens_flare.GetLens() ~= nil and lens.Get("lens.ghosts")
end

local function is_traced_enabled()
	return is_ghosts_enabled() and lens.Get("lens.ray_traced_ghosts")
end

local function is_sources_enabled()
	return lens_flare.GetLens() ~= nil and
		(
			lens.Get("lens.ghosts") or
			lens.Get("lens.starburst")
		)
end

local function get_attachment(name, attachment)
	return function()
		local pipeline = render3d.pipelines[name]
		return pipeline and
			pipeline.framebuffers and
			pipeline:GetFramebuffer():GetAttachment(attachment) or
			nil
	end
end

function lens_flare.GetGhostTexture()
	if not is_ghosts_enabled() then return nil end

	return get_attachment("lens_ghosts", 1)()
end

function lens_flare.GetTracedGhostTexture()
	if not is_traced_enabled() then return nil end

	return get_attachment("lens_ghost_raster", 1)()
end

function lens_flare.GetSourceTextures()
	if not is_sources_enabled() then return nil end

	return get_attachment("lens_sources", 1)(), get_attachment("lens_sources", 2)()
end

local function get_exposure_texture()
	return post_source.GetExposureTexture()
end

local function get_lens_texture(name)
	return function()
		local built = lens_flare.GetLens()
		return built and lens_flare.GetTextures(built)[name]
	end
end

local function write_lens_block(self, block)
	render3d.WriteCameraBlock(self, block)
	exposure_model.WriteCameraBlock(block)
	lens_flare.WriteLensBlock(self, block, lens_flare.GetLens())
	block.ghost_intensity = lens.Get("lens.ghost_intensity")
	block.traced = is_traced_enabled() and 1 or 0
	return block
end

local lens_data_block = {
	render3d.camera_block,
	exposure_model.camera_block,
	lens.block,
	{"ghost_intensity", "float"},
	{"traced", "int"},
}
local RAY_GLSL = [[
			const vec3 CHANNEL_WAVELENGTH = vec3(]] .. table.concat(eye_glare.CHANNEL_WAVELENGTH, ".0, ") .. [[.0);
			const float DESIGN_WAVELENGTH = ]] .. string.format("%.1f", lens.DESIGN_WAVELENGTH) .. [[;
			const float BAND_HALF_WIDTH = 20.0;
			int surface_count;
			int channel;
			vec4 coating0;
			vec4 coating1;
			vec3 ray_p;
			vec3 ray_d;
			vec3 ray_n;
			float transmission;
			float clearance;
			vec2 stop_q;
			bool stop_seen;
			bool alive;
			float stop_radius;

			vec4 surface_shape(int k) {
				return texelFetch(surface_tex, ivec2(0, k - 1), 0);
			}

			vec2 surface_decenter(int k) {
				return texelFetch(surface_tex, ivec2(2, k - 1), 0).xy;
			}

			float medium_index(int k) {
				return k == 0 ? 1.0 : texelFetch(surface_tex, ivec2(1, k - 1), 0)[channel];
			}

			bool is_coated(int k) {
				return texelFetch(surface_tex, ivec2(1, k - 1), 0).w > 0.5;
			}

			vec2 complex_div(vec2 a, vec2 b) {
				return vec2(a.x * b.x + a.y * b.y, a.y * b.x - a.x * b.y) / dot(b, b);
			}

			float stack_reflectance(float sin_air, float n_glass, float wavelength, bool p_polarized) {
				float cos_air = sqrt(max(1.0 - sin_air * sin_air, 1e-8));
				float eta_air = p_polarized ? 1.0 / cos_air : cos_air;
				vec2 m11 = vec2(1.0, 0.0);
				vec2 m12 = vec2(0.0);
				vec2 m21 = vec2(0.0);
				vec2 m22 = vec2(1.0, 0.0);
				int layers = int(coating1.w + 0.5);

				for (int l = 0; l < layers; l++) {
					vec2 layer = l == 0 ? coating0.xy : (l == 1 ? coating0.zw : coating1.xy);
					float cos_layer = sqrt(max(1.0 - sin_air * sin_air / (layer.x * layer.x), 1e-8));
					float eta = p_polarized ? layer.x / cos_layer : layer.x * cos_layer;
					float phase = 6.2831853 * layer.y * DESIGN_WAVELENGTH / wavelength * cos_layer;
					float c = cos(phase);
					float s = sin(phase);
					vec2 a11 = m11 * c + vec2(-m12.y, m12.x) * (eta * s);
					vec2 a12 = vec2(-m11.y, m11.x) * (s / eta) + m12 * c;
					vec2 a21 = m21 * c + vec2(-m22.y, m22.x) * (eta * s);
					vec2 a22 = vec2(-m21.y, m21.x) * (s / eta) + m22 * c;
					m11 = a11;
					m12 = a12;
					m21 = a21;
					m22 = a22;
				}

				float cos_glass = sqrt(max(1.0 - sin_air * sin_air / (n_glass * n_glass), 1e-8));
				float eta_glass = p_polarized ? n_glass / cos_glass : n_glass * cos_glass;
				vec2 b = m11 + m12 * eta_glass;
				vec2 c = m21 + m22 * eta_glass;
				vec2 r = complex_div(eta_air * b - c, eta_air * b + c);
				return dot(r, r);
			}

			float interface_reflectance(int k, float n1, float n2, float cos_i) {
				float sin_i = sqrt(max(1.0 - cos_i * cos_i, 0.0));

				if (is_coated(k)) {
					float sin_air = n1 * sin_i;

					if (sin_air >= 1.0) return 1.0;

					float n_glass = max(n1, n2);
					float wavelength = CHANNEL_WAVELENGTH[channel];
					return 0.25 * (
						stack_reflectance(sin_air, n_glass, wavelength - BAND_HALF_WIDTH, false) +
						stack_reflectance(sin_air, n_glass, wavelength - BAND_HALF_WIDTH, true) +
						stack_reflectance(sin_air, n_glass, wavelength + BAND_HALF_WIDTH, false) +
						stack_reflectance(sin_air, n_glass, wavelength + BAND_HALF_WIDTH, true)
					);
				}

				float sin_t = n1 / n2 * sin_i;

				if (sin_t >= 1.0) return 1.0;

				float cos_t = sqrt(1.0 - sin_t * sin_t);
				float rs = (n1 * cos_i - n2 * cos_t) / (n1 * cos_i + n2 * cos_t);
				float rp = (n1 * cos_t - n2 * cos_i) / (n1 * cos_t + n2 * cos_i);
				return 0.5 * (rs * rs + rp * rp);
			}

			void hit_surface(int k) {
				vec4 shape = surface_shape(k);
				vec2 decenter = surface_decenter(k);

				if (shape.x == 0.0) {
					ray_p += (shape.y - ray_p.z) / ray_d.z * ray_d;
					ray_n = vec3(0.0, 0.0, ray_d.z > 0.0 ? -1.0 : 1.0);
				} else {
					vec3 center = vec3(decenter, shape.y + shape.x);
					vec3 oc = ray_p - center;
					float b = dot(oc, ray_d);
					float disc = b * b - (dot(oc, oc) - shape.x * shape.x);

					if (disc < 0.0) {
						alive = false;
						return;
					}

					float t = -b - sqrt(disc);

					if ((ray_p.z + t * ray_d.z - center.z) * shape.x >= 0.0) t = -b + sqrt(disc);

					ray_p += t * ray_d;
					ray_n = (ray_p - center) / shape.x;

					if (dot(ray_n, ray_d) > 0.0) ray_n = -ray_n;
				}

				float r = length(ray_p.xy - decenter);

				if (shape.w > 1.5) return;

				if (shape.w > 0.5) {
					if (!stop_seen) {
						stop_seen = true;
						stop_q = -ray_p.xy / stop_radius;
					} else {
						clearance = min(clearance, (stop_radius - r) / stop_radius);
					}
				} else {
					clearance = min(clearance, (shape.z - r) / shape.z);
				}
			}

			void refract_at(int k, float n1, float n2) {
				hit_surface(k);

				if (!alive || surface_shape(k).w > 1.5 || n1 == n2) return;

				float cos_i = -dot(ray_n, ray_d);
				transmission *= 1.0 - interface_reflectance(k, n1, n2, cos_i);
				float eta = n1 / n2;
				float k2 = 1.0 - eta * eta * (1.0 - cos_i * cos_i);

				if (k2 < 0.0) {
					alive = false;
					return;
				}

				ray_d = normalize(eta * ray_d + (eta * cos_i - sqrt(k2)) * ray_n);
			}

			void reflect_at(int k, float n1, float n2) {
				hit_surface(k);

				if (!alive) return;

				transmission *= surface_shape(k).w > 1.5 ? texelFetch(surface_tex, ivec2(1, k - 1), 0)[channel] : interface_reflectance(k, n1, n2, -dot(ray_n, ray_d));
				ray_d = reflect(ray_d, ray_n);
			}

]]

local function write_target_size(block)
	local target = get_attachment("lens_ghosts", 1)()
	block.target_size[0] = target:GetWidth()
	block.target_size[1] = target:GetHeight()
end

local raster_block = {
	name = "raster_data",
	binding_index = 2,
	block = {
		lens_data_block,
		{"target_size", "vec2"},
		{"position_tex", "int"},
		{"stop_tex", "int"},
		{"energy_tex", "int"},
		{"source_position_tex", "int"},
		{"ghost_tex", "int"},
		{"exposure_tex", "int"},
	},
	write = function(self, block)
		write_lens_block(self, block)
		write_target_size(block)
		block.position_tex = self:GetTextureIndex(get_attachment("lens_ghost_trace", 1)())
		block.stop_tex = self:GetTextureIndex(get_attachment("lens_ghost_trace", 2)())
		block.energy_tex = self:GetTextureIndex(get_attachment("lens_sources", 2)())
		block.source_position_tex = self:GetTextureIndex(get_attachment("lens_sources", 1)())
		block.ghost_tex = self:GetTextureIndex(lens_flare.GetTextures(lens_flare.GetLens()).ghosts)
		block.exposure_tex = self:GetTextureIndex(get_exposure_texture())
		return block
	end,
}
local trace_glsl = [[
	const int GRID = ]] .. lens.TRACE_GRID .. [[;
	const int MAX_GHOSTS = ]] .. lens.MAX_GHOSTS .. [[;
	const int TRACE_SOURCES = ]] .. lens.TRACE_SOURCES .. [[;
	const float TRACE_EXTENT = ]] .. string.format("%.3f", lens.TRACE_EXTENT) .. [[;
	const float TRACE_MIN_RADIUS = ]] .. string.format("%.3f", lens.TRACE_MIN_RADIUS) .. [[;
	const vec2 JITTER_SIGN = vec2(-1.0, -1.0);

	bool ghost_is_traced(int source, float scale, float stop_pixels, int traced, float diffraction_order) {
		return traced != 0 && diffraction_order < 0.5 && source < TRACE_SOURCES && abs(scale) * stop_pixels >= TRACE_MIN_RADIUS;
	}
]]

function lens_flare.GetBloomWeightsTexture()
	if not lens_flare.GetLens() then return nil end

	return get_attachment("lens_bloom_weights", 1)()
end

local function psf_texture(name)
	return function()
		return lens_flare.GetPSFTexture(name)
	end
end

local function psf_target(name)
	return function()
		return lens_flare.GetPSFJob().targets[name]
	end
end

local function psf_pass(config)
	local groups = config.groups
	local finish = config.finish
	config.groups = nil
	config.finish = nil
	config.timing_group = "lens psf"
	config.ComputePass = true
	config.ColorFormat = {{"r32_sfloat", {config.name, "r"}}}
	config.framebuffer_count = 1
	config.FramebufferSize = {x = 1, y = 1}
	config.LocalSize = config.LocalSize or {x = PSF_THREADS, y = 1, z = 1}
	config.is_enabled = config.is_enabled or function()
		return lens_flare.GetPSFJob() ~= nil
	end
	config.block = config.block or {{"unused", "int"}}
	config.write = config.write or function(self, block)
		return block
	end
	config.on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		local x, y = groups()
		self.pipeline:Dispatch(cmd, x, y, 1, desc, self.dynamic_offsets)

		if finish then finish() end
	end
	return config
end

local PSF_GLSL = [[
	const int N = ]] .. eye_psf.GRID .. [[;
	const uint LOG_N = ]] .. math.floor(math.log(eye_psf.GRID) / math.log(2) + 0.5) .. [[u;
	const int THREADS = ]] .. PSF_THREADS .. [[;
	const int ANGLES = ]] .. eye_psf.ANGLES .. [[;
	const int RADII = ]] .. eye_psf.RADII .. [[;
	const float LOG_MIN = ]] .. string.format("%.9f", math.log(eye_psf.MIN_DEGREES)) .. [[;
	const float RING_STEP = ]] .. string.format(
		"%.9f",
		(math.log(eye_psf.GetMaxDegrees()) - math.log(eye_psf.MIN_DEGREES)) / eye_psf.RADII
	) .. [[;
	const float DEGREES_PER_TEXEL = ]] .. string.format("%.12f", eye_psf.GetDegreesPerTexel()) .. [[;
]]

local function fft_pass(name, columns)
	return psf_pass{
		name = name,
		groups = function()
			return eye_psf.GRID, 1
		end,
		storage_images = {
			{binding_index = 0, get_texture = psf_texture("field"), dst_stage = "compute"},
			{
				binding_index = 1,
				get_texture = psf_texture("row_energy"),
				dst_stage = "compute",
			},
		},
		shader = [[
			layout(set = 0, binding = 0, rg32f) uniform image2D field;
			layout(set = 0, binding = 1, r32f) uniform image2D row_energy;
			const bool COLUMNS = ]] .. tostring(columns) .. [[;
			shared vec2 data[]] .. eye_psf.GRID .. [[];
		]] .. PSF_GLSL .. [[
			void main() {
				int line = int(gl_WorkGroupID.x);
				int t = int(gl_LocalInvocationID.x);

				for (int e = t; e < N; e += THREADS) {
					ivec2 p = COLUMNS ? ivec2(line, e) : ivec2(e, line);
					vec2 v = imageLoad(field, p).xy;

					if (!COLUMNS && ((p.x + p.y) & 1) != 0) v = -v;

					data[int(bitfieldReverse(uint(e)) >> (32u - LOG_N))] = v;
				}

				barrier();

				if (!COLUMNS && t == 0) {
					float sum = 0.0;

					for (int e = 0; e < N; e++) sum += dot(data[e], data[e]);

					imageStore(row_energy, ivec2(line, 0), vec4(sum));
				}

				barrier();

				for (uint s = 0u; s < LOG_N; s++) {
					int half_size = 1 << s;

					for (int k = t; k < N / 2; k += THREADS) {
						int j = k & (half_size - 1);
						int i0 = ((k >> s) << (s + 1u)) + j;
						int i1 = i0 + half_size;
						float angle = -3.14159265358979 * float(j) / float(half_size);
						vec2 w = vec2(cos(angle), sin(angle));
						vec2 a = data[i0];
						vec2 b = data[i1];
						vec2 wb = vec2(w.x * b.x - w.y * b.y, w.x * b.y + w.y * b.x);
						data[i0] = a + wb;
						data[i1] = a - wb;
					}

					barrier();
				}

				for (int e = t; e < N; e += THREADS) {
					imageStore(field, COLUMNS ? ivec2(line, e) : ivec2(e, line), vec4(data[e], 0.0, 0.0));
				}
			}
		]],
	}
end

lens_flare.psf_passes = {
	psf_pass{
		name = "lens_vignette",
		LocalSize = {x = 8, y = 8, z = 1},
		is_enabled = function()
			local built = lens_flare.GetLens()
			return built ~= nil and not lens_flare.IsVignetteReady(built)
		end,
		groups = function()
			return math.ceil(lens.VIGNETTE_FIELDS / 8),
			math.ceil(lens.VIGNETTE_APERTURES / 8)
		end,
		finish = lens_flare.MarkVignetteReady,
		storage_images = {
			{
				binding_index = 0,
				get_texture = function()
					return lens_flare.GetTextures(lens_flare.GetLens()).vignette
				end,
				dst_stage = "compute",
			},
		},
		sampled_images = {
			{binding_index = 2, get_texture = get_lens_texture("surfaces")},
			{binding_index = 3, get_texture = get_lens_texture("chief")},
		},
		uniform_buffers = {
			{
				name = "vignette_data",
				binding_index = 1,
				block = {lens.block},
				write = function(self, block)
					return lens_flare.WriteLensBlock(self, block, lens_flare.GetLens())
				end,
			},
		},
		shader = [[
			layout(set = 0, binding = 0, r32f) uniform writeonly image2D out_vignette;
			layout(set = 0, binding = 2) uniform sampler2D surface_tex;
			layout(set = 0, binding = 3) uniform sampler2D chief_tex;
			const ivec2 SIZE = ivec2(]] .. lens.VIGNETTE_FIELDS .. [[, ]] .. lens.VIGNETTE_APERTURES .. [[);
			const int GRID = 24;
			const float EXTENT = 1.6;
		]] .. lens.GetGLSL("vignette_data") .. RAY_GLSL .. [[
			float slope;

			void start_ray(vec2 entrance) {
				ray_p = vec3(entrance - vec2(slope, 0.0), -1.0);
				ray_d = normalize(vec3(slope, 0.0, 1.0));
				transmission = 1.0;
				clearance = 1.0;
				stop_q = vec2(0.0);
				stop_seen = false;
				alive = true;
			}

			bool stop_point(vec2 entrance, out vec2 point) {
				start_ray(entrance);

				for (int k = 1; k <= surface_count && alive && !stop_seen; k++) refract_at(k, medium_index(k - 1), medium_index(k));

				point = -stop_q * stop_radius;
				return alive && stop_seen;
			}

			void main() {
				ivec2 pos = ivec2(gl_GlobalInvocationID.xy);

				if (pos.x >= SIZE.x || pos.y >= SIZE.y) return;

				float n = vignette_data.lens_aperture_min * pow(LENS_APERTURE_MAX / vignette_data.lens_aperture_min, float(pos.y) / float(SIZE.y - 1));
				float curvature = lens_curvature_at(n);
				stop_radius = lens_stop_radius(n);
				channel = 1;
				surface_count = textureSize(surface_tex, 0).y - 1;
				coating0 = texelFetch(surface_tex, ivec2(0, surface_count), 0);
				coating1 = texelFetch(surface_tex, ivec2(1, surface_count), 0);
				slope = float(pos.x) / float(SIZE.x - 1) * vignette_data.lens_corner_tan;
				vec2 chief = vec2(texelFetch(chief_tex, ivec2(pos.x, 0), 0).r, 0.0);
				float step_size = 0.01 * stop_radius / abs(vignette_data.lens_main_a1);
				vec2 center, along_x, along_y;
				vec2 jacobian = vec2(vignette_data.lens_main_a1);
				vec2 stop_center = vec2(0.0);

				if (stop_point(chief, center) && stop_point(chief + vec2(step_size, 0.0), along_x) && stop_point(chief + vec2(0.0, step_size), along_y)) {
					jacobian = vec2(along_x.x - center.x, along_y.y - center.y) / step_size;
					stop_center = center;
				}
				float inside = 0.0;
				float passed = 0.0;

				for (int gy = 0; gy < GRID; gy++) {
					for (int gx = 0; gx < GRID; gx++) {
						vec2 a = ((vec2(gx, gy) + 0.5) / float(GRID) * 2.0 - 1.0) * EXTENT;

						if (lens_shape_distance(a, curvature) > 0.0) continue;

						inside += 1.0;
						start_ray(chief + (a * stop_radius - stop_center) / jacobian);

						for (int k = 1; k <= surface_count && alive; k++) refract_at(k, medium_index(k - 1), medium_index(k));

						if (alive && stop_seen && clearance >= 0.0 && lens_shape_distance(-stop_q, curvature) <= 0.0) passed += 1.0;
					}
				}

				imageStore(out_vignette, pos, vec4(passed / max(inside, 1.0)));
			}
		]],
	},
	psf_pass{
		name = "lens_psf_field",
		LocalSize = {x = 8, y = 8, z = 1},
		groups = function()
			return eye_psf.GRID / 8, eye_psf.GRID / 8
		end,
		storage_images = {{binding_index = 0, get_texture = psf_texture("field"), dst_stage = "compute"}},
		block = {
			{"aperture", "int"},
			{"aperture_tex", "int"},
			{"curvature", "float"},
			{"scale", "float"},
			{"radius", "float"},
		},
		write = function(self, block)
			local job = lens_flare.GetPSFJob()
			block.aperture = job.kind == "star" and 1 or 0

			if job.kind == "star" then
				local built = job.built
				block.aperture_tex = self:GetTextureIndex(lens_flare.GetTextures(built).aperture)
				block.curvature = built.curvature
				block.scale = math.sqrt(math.pi / lens.GetShapeArea(built, built.curvature))
				block.radius = eye_psf.PUPIL_DIAMETER / 2 / eye_psf.SAMPLE_SPACING
			end

			return block
		end,
		shader = [[
			layout(set = 0, binding = 0, rg32f) uniform writeonly image2D field;
		]] .. PSF_GLSL .. [[
			void main() {
				ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
				float value = 1.0;

				if (compute.aperture != 0) {
					value = 0.0;

					for (int sy = 0; sy < 2; sy++) {
						for (int sx = 0; sx < 2; sx++) {
							vec2 q = (vec2(pos) + vec2(sx, sy) * 0.5 - 0.25 - float(N / 2)) / compute.radius;

							if (dot(q, q) > 2.6) continue;

							float polygon = texture(TEXTURE(compute.aperture_tex), vec2(atan(q.y, q.x) / 6.2831853, 0.5)).r;

							if (length(q) <= compute.scale * mix(polygon, 1.0, compute.curvature)) value += 0.25;
						}
					}
				}

				imageStore(field, pos, vec4(value, 0.0, 0.0, 0.0));
			}
		]],
	},
	psf_pass{
		name = "lens_psf_dirt",
		is_enabled = function()
			local job = lens_flare.GetPSFJob()
			return job ~= nil and job.kind == "dirt" and job.count > 0
		end,
		groups = function()
			return lens_flare.GetPSFJob().count, 1
		end,
		storage_images = {{binding_index = 0, get_texture = psf_texture("field"), dst_stage = "compute"}},
		sampled_images = {{binding_index = 1, get_texture = psf_texture("primitives")}},
		shader = [[
			layout(set = 0, binding = 0, rg32f) uniform image2D field;
			layout(set = 0, binding = 1) uniform sampler2D primitives;
			const int PER_ROW = ]] .. PRIMITIVES_PER_ROW .. [[;
		]] .. PSF_GLSL .. [[
			void main() {
				int index = int(gl_WorkGroupID.x);
				ivec2 base = ivec2((index % PER_ROW) * 2, index / PER_ROW);
				vec4 a = texelFetch(primitives, base, 0);
				vec4 b = texelFetch(primitives, base + ivec2(1, 0), 0);
				bool line = a.x > 0.5;
				vec2 start = a.yz;
				vec2 end_point = line ? start + b.xy * a.w : start;
				float reach = line ? b.z : a.w;
				ivec2 low = ivec2(floor(min(start, end_point) - reach - 1.0));
				ivec2 high = ivec2(ceil(max(start, end_point) + reach + 1.0));
				int width = high.x - low.x + 1;
				int count = width * (high.y - low.y + 1);

				for (int i = int(gl_LocalInvocationID.x); i < count; i += THREADS) {
					ivec2 texel = low + ivec2(i % width, i / width);
					vec2 d = vec2(texel) - start;
					float along = dot(d, b.xy);
					bool inside = line ? abs(d.x * b.y - d.y * b.x) < 0.5 * b.z && along >= 0.0 && along <= a.w : dot(d, d) <= a.w * a.w;

					if (!inside) continue;

					ivec2 wrapped = (texel + ivec2(4 * N)) % N;
					float current = imageLoad(field, wrapped).r;
					imageStore(field, wrapped, vec4(line ? current * b.w : 0.0, 0.0, 0.0, 0.0));
				}
			}
		]],
	},
	fft_pass("lens_psf_rows", false),
	fft_pass("lens_psf_columns", true),
	psf_pass{
		name = "lens_psf_polar",
		LocalSize = {x = 8, y = 8, z = 1},
		groups = function()
			return eye_psf.ANGLES / 8, math.ceil(eye_psf.RADII / 8)
		end,
		storage_images = {
			{binding_index = 0, get_texture = psf_texture("raw"), dst_stage = "compute"},
			{binding_index = 1, get_texture = psf_texture("field"), dst_stage = "compute"},
		},
		shader = [[
			layout(set = 0, binding = 0, r32f) uniform writeonly image2D raw;
			layout(set = 0, binding = 1, rg32f) uniform readonly image2D field;
		]] .. PSF_GLSL .. [[
			float power_at(int x, int y) {
				vec2 v = imageLoad(field, ivec2(x, y)).xy;
				return dot(v, v);
			}

			void main() {
				ivec2 pos = ivec2(gl_GlobalInvocationID.xy);

				if (pos.y >= RADII) return;

				float value = 0.0;

				for (int radial = 0; radial < 4; radial++) {
					float texels = exp(LOG_MIN + (float(pos.y) + (float(radial) + 0.5) / 4.0) * RING_STEP) / DEGREES_PER_TEXEL;

					for (int sub = 0; sub < 4; sub++) {
						float angle = (float(pos.x) + (float(sub) + 0.5) / 4.0) / float(ANGLES) * 6.2831853;
						vec2 f = vec2(N / 2) + vec2(cos(angle), sin(angle)) * texels;
						ivec2 c = ivec2(floor(f));
						vec2 t = f - vec2(c);
						value += mix(
							mix(power_at(c.x, c.y), power_at(c.x + 1, c.y), t.x),
							mix(power_at(c.x, c.y + 1), power_at(c.x + 1, c.y + 1), t.x),
							t.y
						);
					}
				}

				imageStore(raw, pos, vec4(value));
			}
		]],
	},
	psf_pass{
		name = "lens_psf_rings",
		groups = function()
			return eye_psf.RADII, 1
		end,
		storage_images = {
			{
				binding_index = 0,
				get_texture = psf_target("modulation"),
				dst_stage = "compute",
			},
			{binding_index = 1, get_texture = psf_texture("raw"), dst_stage = "compute"},
			{
				binding_index = 2,
				get_texture = psf_texture("ring_means"),
				dst_stage = "compute",
			},
		},
		shader = [[
			layout(set = 0, binding = 0, r32f) uniform writeonly image2D modulation;
			layout(set = 0, binding = 1, r32f) uniform readonly image2D raw;
			layout(set = 0, binding = 2, r32f) uniform writeonly image2D ring_means;
			const float PREFILTER_DEGREES = ]] .. string.format("%.6f", lens.STAR_PREFILTER_DEGREES) .. [[;
			shared float prefix[]] .. (
				eye_psf.ANGLES + 1
			) .. [[];
		]] .. PSF_GLSL .. [[
			float window_sum(int start, int count, float total) {
				int s = start + ANGLES;
				int e = s + count;
				return float(e / ANGLES) * total + prefix[e % ANGLES] - float(s / ANGLES) * total - prefix[s % ANGLES];
			}

			void main() {
				int ring = int(gl_WorkGroupID.x);
				int t = int(gl_LocalInvocationID.x);

				if (t == 0) {
					prefix[0] = 0.0;

					for (int i = 0; i < ANGLES; i++) prefix[i + 1] = prefix[i] + imageLoad(raw, ivec2(i, ring)).r;
				}

				barrier();

				float total = prefix[ANGLES];
				float mean = total / float(ANGLES);
				float degrees = exp(LOG_MIN + (float(ring) + 0.5) * RING_STEP);
				int width = clamp(int(floor(PREFILTER_DEGREES * float(ANGLES) / (6.2831853 * degrees) + 0.5)), 1, ANGLES);

				for (int angle = t; angle < ANGLES; angle += THREADS) {
					float value = window_sum(angle - width / 2, width, total) / float(width);
					imageStore(modulation, ivec2(angle, ring), vec4(mean > 0.0 ? value / mean : 1.0));
				}

				if (t == 0) imageStore(ring_means, ivec2(ring, 0), vec4(mean / 16.0));
			}
		]],
	},
	psf_pass{
		name = "lens_psf_spread",
		groups = function()
			return 1, 1
		end,
		finish = function()
			local job = lens_flare.GetPSFJob()
			job.targets.key = job.key
		end,
		storage_images = {
			{binding_index = 0, get_texture = psf_target("spread"), dst_stage = "compute"},
			{
				binding_index = 1,
				get_texture = psf_texture("ring_means"),
				dst_stage = "compute",
			},
			{
				binding_index = 2,
				get_texture = psf_texture("row_energy"),
				dst_stage = "compute",
			},
		},
		shader = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D spread;
			layout(set = 0, binding = 1, r32f) uniform readonly image2D ring_means;
			layout(set = 0, binding = 2, r32f) uniform readonly image2D row_energy;
			const int ENTRIES = ]] .. STAR_SPREAD_ENTRIES .. [[;
			const float SPREAD_LOG_MIN = ]] .. string.format("%.9f", math.log(STAR_SPREAD_MIN_DEGREES)) .. [[;
			const float SPREAD_LOG_RANGE = ]] .. string.format("%.9f", math.log(STAR_SPREAD_MAX_DEGREES) - math.log(STAR_SPREAD_MIN_DEGREES)) .. [[;
			const float ANCHOR = ]] .. string.format("%.6f", lens.GetStarAnchorDegrees()) .. [[;
			const float TEXEL_RADIANS = ]] .. string.format("%.12e", math.rad(eye_psf.GetDegreesPerTexel())) .. [[;
			const vec3 CHANNEL_RATIO = vec3(]] .. string.format(
				"%.6f, %.6f, %.6f",
				eye_glare.CHANNEL_WAVELENGTH[1] / eye_glare.REFERENCE_WAVELENGTH,
				eye_glare.CHANNEL_WAVELENGTH[2] / eye_glare.REFERENCE_WAVELENGTH,
				eye_glare.CHANNEL_WAVELENGTH[3] / eye_glare.REFERENCE_WAVELENGTH
			) .. [[);
			shared float total;
		]] .. PSF_GLSL .. [[
			float ring_mean(float degrees) {
				float ring = (log(degrees) - LOG_MIN) / RING_STEP - 0.5;

				if (ring <= 0.0) return imageLoad(ring_means, ivec2(0, 0)).r;

				int low = min(int(floor(ring)), RADII - 2);
				return mix(imageLoad(ring_means, ivec2(low, 0)).r, imageLoad(ring_means, ivec2(low + 1, 0)).r, ring - float(low));
			}

			void main() {
				int i = int(gl_LocalInvocationID.x);

				if (i == 0) {
					float sum = 0.0;

					for (int r = 0; r < N; r++) sum += imageLoad(row_energy, ivec2(r, 0)).r;

					total = sum * float(N) * float(N);
				}

				barrier();

				if (i >= ENTRIES) return;

				float degrees = exp(SPREAD_LOG_MIN + (float(i) + 0.5) / float(ENTRIES) * SPREAD_LOG_RANGE);
				vec3 value;

				for (int c = 0; c < 3; c++) {
					float ratio = CHANNEL_RATIO[c];
					float scaled = degrees / ratio;
					float mean = scaled <= ANCHOR ? ring_mean(scaled) : ring_mean(ANCHOR) * pow(ANCHOR / scaled, 3.0);
					value[c] = mean / (total * TEXEL_RADIANS * TEXEL_RADIANS) / (ratio * ratio);
				}

				imageStore(spread, ivec2(i, 0), vec4(value, 0.0));
			}
		]],
	},
}
lens_flare.bloom_passes = {
	{
		name = "lens_bloom_weights",
		timing_group = "bloom",
		is_enabled = function()
			return lens_flare.GetLens() ~= nil
		end,
		ComputePass = true,
		ColorFormat = {{"r32g32b32a32_sfloat", {"lens_bloom_weights", "rgba"}}},
		framebuffer_count = 1,
		FramebufferSize = {x = BLOOM_LEVELS + 1, y = 1},
		LocalSize = {x = 1, y = 1, z = 1},
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		sampled_images = {
			{binding_index = 1, get_texture = get_exposure_texture},
			{
				binding_index = 2,
				get_texture = function()
					return lens_flare.GetStarTextures().spread
				end,
			},
			{
				binding_index = 3,
				get_texture = function()
					local dirt = lens_flare.GetDirtTextures()
					return dirt and dirt.spread
				end,
			},
		},
		uniform_buffers = {
			{
				name = "bloom_lens",
				binding_index = 4,
				block = {
					exposure_model.camera_block,
					lens.block,
					{"window_size", "vec2"},
					{"has_dirt", "int"},
					{"smear", "float"},
				},
				write = function(self, block)
					exposure_model.WriteCameraBlock(block)
					lens_flare.WriteLensBlock(self, block, lens_flare.GetLens())
					local size = render.GetRenderImageSize()
					block.window_size[0] = size.x
					block.window_size[1] = size.y
					block.has_dirt = lens_flare.GetDirtTextures() and 1 or 0
					block.smear = lens.Get("lens.smear")
					return block
				end,
			},
		},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:Dispatch(cmd, 1, 1, 1, desc, self.dynamic_offsets)
		end,
		shader = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_weights;
			layout(set = 0, binding = 1) uniform sampler2D exposure_tex;
			layout(set = 0, binding = 2) uniform sampler2D diffraction_tex;
			layout(set = 0, binding = 3) uniform sampler2D dirt_tex;
			const int LEVELS = ]] .. BLOOM_LEVELS .. [[;
			const int STEPS = 24;
			const float MIN_PIXELS = ]] .. string.format("%.3f", BLOOM_MIN_PIXELS) .. [[;
			const float REFERENCE_MM = ]] .. string.format("%.3f", eye_psf.PUPIL_DIAMETER * 1000) .. [[;
			const float SPREAD_LOG_MIN = ]] .. string.format("%.6f", math.log(STAR_SPREAD_MIN_DEGREES)) .. [[;
			const float SPREAD_LOG_RANGE = ]] .. string.format("%.6f", math.log(STAR_SPREAD_MAX_DEGREES) - math.log(STAR_SPREAD_MIN_DEGREES)) .. [[;
			const vec3 CHANNEL_WAVELENGTH = vec3(]] .. table.concat(eye_glare.CHANNEL_WAVELENGTH, ".0, ") .. [[.0);
			const float SMEAR_CORRELATION = ]] .. string.format("%.9f", lens.SMEAR_CORRELATION) .. [[;
		]] .. exposure_model.GetCameraSettingsGLSL("bloom_lens") .. lens.GetGLSL("bloom_lens") .. [[
			vec3 spread_at(sampler2D tex, float degrees) {
				float t = (log(degrees) - SPREAD_LOG_MIN) / SPREAD_LOG_RANGE;

				if (t >= 1.0) return vec3(0.0);

				return texture(tex, vec2(clamp(t, 0.0, 1.0), 0.5)).rgb;
			}

			void main() {
				float n = lens_aperture(camera_settings(texture(exposure_tex, vec2(0.5)).r).y);
				float reference_scale = bloom_lens.lens_effective_focal / n / REFERENCE_MM;
				float pixels_per_degree = 0.5 * length(bloom_lens.window_size) / bloom_lens.lens_image_radius * bloom_lens.lens_effective_focal * 0.01745329;
				float smear_share = 1.0 - exp(-bloom_lens.smear * bloom_lens.smear);
				vec3 smear_sigma = CHANNEL_WAVELENGTH * 1e-9 / (6.2831853 * SMEAR_CORRELATION) * 1.41421356 * max(bloom_lens.smear, 1.0);
				vec3 energy[LEVELS];
				vec3 total = vec3(0.0);

				for (int i = 0; i < LEVELS; i++) {
					float degrees = exp2(float(i + 1)) / pixels_per_degree;
					float low = log2(max(degrees / 1.41421356, MIN_PIXELS / pixels_per_degree));
					float high = log2(degrees * 1.41421356);
					vec3 sum = vec3(0.0);

					for (int s = 0; s < STEPS && high > low; s++) {
						float d = exp2(low + (float(s) + 0.5) * (high - low) / float(STEPS));
						float r = radians(d);
						vec3 spread = spread_at(diffraction_tex, d * reference_scale) * reference_scale * reference_scale;

						if (bloom_lens.has_dirt != 0) spread += spread_at(dirt_tex, d);

						spread += smear_share * exp(-r * r / (2.0 * smear_sigma * smear_sigma)) / (6.2831853 * smear_sigma * smear_sigma);
						sum += spread * 6.2831853 * r * r * (high - low) / float(STEPS) * 0.69314718;
					}

					energy[i] = sum;
					total += sum;
				}

				imageStore(out_weights, ivec2(0, 0), vec4(total, 1.0));

				for (int i = 0; i < LEVELS; i++) imageStore(out_weights, ivec2(i + 1, 0), vec4(energy[i] / max(total, vec3(1e-12)), 1.0));
			}
		]],
	},
}
lens_flare.passes = {
	{
		name = "lens_tiles",
		timing_group = "bloom",
		is_enabled = is_sources_enabled,
		ComputePass = true,
		ColorFormat = {
			{"r32g32b32a32_sfloat", {"lens_tile_sum", "rgba"}},
			{"r32g32b32a32_sfloat", {"lens_tile_centroid", "rgba"}},
		},
		framebuffer_count = 1,
		scale = TILE_SCALE,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{binding_index = 0, attachment = 1, dst_stage = "compute"},
			{binding_index = 1, attachment = 2, dst_stage = "compute"},
		},
		sampled_images = {
			{
				binding_index = 2,
				get_texture = function()
					return render3d.pipelines.bloom_down1:GetFramebuffer():GetAttachment(1)
				end,
			},
		},
		block = {{"unused", "int"}},
		write = function(self, block)
			return block
		end,
		shader = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_sum;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_centroid;
			layout(set = 0, binding = 2) uniform sampler2D source_tex;
		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_sum);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 source_size = textureSize(source_tex, 0);
				vec2 per_tile = vec2(source_size) / vec2(size);
				vec2 middle = (vec2(pos) + 0.5) * per_tile;
				ivec2 low = max(ivec2(floor(middle - per_tile)), ivec2(0));
				ivec2 high = min(ivec2(ceil(middle + per_tile)), source_size);
				vec3 sum = vec3(0.0);
				float weight = 0.0;
				vec2 first = vec2(0.0);
				float second = 0.0;

				for (int y = low.y; y < high.y; y++) {
					for (int x = low.x; x < high.x; x++) {
						vec2 at = vec2(x, y) + 0.5;
						vec3 color = texelFetch(source_tex, ivec2(x, y), 0).rgb;
						vec2 tent = max(1.0 - abs(at - middle) / per_tile, vec2(0.0));
						float share = tent.x * tent.y;
						float l = luminance(color) * share;
						sum += color * share;
						weight += l;
						first += l * at;
						second += l * dot(at, at);
					}
				}

				vec2 mean = weight > 0.0 ? first / weight : vec2(0.0);
				float spread = weight > 0.0 ? sqrt(max(second / weight - dot(mean, mean), 0.0)) : 0.0;
				imageStore(out_sum, pos, vec4(sum, weight));
				imageStore(out_centroid, pos, vec4(mean / vec2(source_size), weight, spread));
			}
		]],
	},
	{
		name = "lens_sources",
		timing_group = "bloom",
		is_enabled = is_sources_enabled,
		ComputePass = true,
		ColorFormat = {
			{"r32g32b32a32_sfloat", {"lens_source_position", "rgba"}},
			{"r32g32b32a32_sfloat", {"lens_source_energy", "rgba"}},
		},
		framebuffer_count = 1,
		FramebufferSize = {x = SOURCES, y = 1},
		LocalSize = {x = SELECT_THREADS, y = 1, z = 1},
		storage_images = {
			{binding_index = 0, attachment = 1, dst_stage = {"compute", "vertex"}},
			{binding_index = 1, attachment = 2, dst_stage = {"compute", "vertex"}},
		},
		sampled_images = {
			{binding_index = 2, get_texture = get_attachment("lens_tiles", 1)},
			{binding_index = 3, get_texture = get_attachment("lens_tiles", 2)},
			{binding_index = 4, get_texture = get_exposure_texture},
			{
				binding_index = 5,
				get_texture = function()
					return post_source.GetExposureTexture(true)
				end,
			},
		},
		block = {{"unused", "int"}},
		write = function(self, block)
			return block
		end,
		shader = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_position;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_energy;
			layout(set = 0, binding = 2) uniform sampler2D tile_sum_tex;
			layout(set = 0, binding = 3) uniform sampler2D tile_centroid_tex;
			layout(set = 0, binding = 4) uniform sampler2D exposure_tex;
			layout(set = 0, binding = 5) uniform sampler2D prev_exposure_tex;
			const int SOURCES = ]] .. SOURCES .. [[;
			const int THREADS = ]] .. SELECT_THREADS .. [[;
			const int BINS = ]] .. SOURCE_BINS .. [[;
			shared uint histogram[BINS];
			shared int threshold_bin;
			shared uint count;
			shared vec4 found_position[SOURCES];
			shared vec4 found_energy[SOURCES];
		]] .. post_source.GetPreExposureFromExposureGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. [[
			int source_bin(float exposed) {
				if (exposed <= 0.0) return -1;

				return min(int(floor((log2(exposed) - ]] .. string.format("%.1f", SOURCE_MIN_LOG2) .. [[) / ]] .. string.format("%.3f", SOURCE_BIN_STOPS) .. [[)), BINS - 1);
			}

			void main() {
				int id = int(gl_LocalInvocationIndex);
				ivec2 tiles = textureSize(tile_sum_tex, 0);
				int total = tiles.x * tiles.y;
				float exposure = texture(exposure_tex, vec2(0.5)).r / pre_exposure_from_exposure(texture(prev_exposure_tex, vec2(0.5)).r);

				for (int b = id; b < BINS; b += THREADS) histogram[b] = 0u;

				if (id == 0) count = 0u;

				barrier();

				for (int n = id; n < total; n += THREADS) {
					int bin = source_bin(texelFetch(tile_sum_tex, ivec2(n % tiles.x, n / tiles.x), 0).a * exposure);

					if (bin >= 0) atomicAdd(histogram[bin], 1u);
				}

				barrier();

				if (id == 0) {
					uint taken = 0u;
					int threshold = BINS;

					for (int b = BINS - 1; b >= 0; b--) {
						if (taken + histogram[b] > uint(SOURCES)) break;

						taken += histogram[b];
						threshold = b;
					}

					threshold_bin = threshold;
				}

				barrier();

				for (int n = id; n < total; n += THREADS) {
					ivec2 tile = ivec2(n % tiles.x, n / tiles.x);
					vec4 sum = texelFetch(tile_sum_tex, tile, 0);

					if (source_bin(sum.a * exposure) >= threshold_bin) {
						int slot = int(atomicAdd(count, 1u));
						vec4 tile_center = texelFetch(tile_centroid_tex, tile, 0);
						found_position[slot] = vec4(tile_center.xy, tile_center.w, 1.0);
						found_energy[slot] = vec4(sum.rgb, sum.a);
					}
				}

				barrier();

				if (id == 0) {
					int found = int(count);

					for (int a = 1; a < found; a++) {
						vec4 position = found_position[a];
						vec4 energy = found_energy[a];
						int b = a - 1;

						while (b >= 0 && found_energy[b].a < energy.a) {
							found_position[b + 1] = found_position[b];
							found_energy[b + 1] = found_energy[b];
							b--;
						}

						found_position[b + 1] = position;
						found_energy[b + 1] = energy;
					}

					vec2 merge_distance = 1.0 / vec2(tiles);
					int kept = 0;

					for (int a = 0; a < found; a++) {
						int into = -1;

						for (int b = 0; b < kept; b++) {
							if (all(lessThan(abs(found_position[b].xy - found_position[a].xy), merge_distance))) {
								into = b;
								break;
							}
						}

						if (into >= 0) {
							found_energy[into] += found_energy[a];
						} else {
							found_position[kept] = found_position[a];
							found_energy[kept] = found_energy[a];
							kept++;
						}
					}

					count = uint(kept);
				}

				barrier();

				for (int slot = id; slot < SOURCES; slot += THREADS) {
					bool used = slot < int(count);
					imageStore(out_position, ivec2(slot, 0), used ? found_position[slot] : vec4(0.0));
					imageStore(out_energy, ivec2(slot, 0), used ? vec4(found_energy[slot].rgb, 1.0) : vec4(0.0));
				}
			}
		]],
	},
	{
		name = "lens_ghost_instances",
		timing_group = "bloom",
		is_enabled = is_ghosts_enabled,
		ComputePass = true,
		ColorFormat = {{"r32g32b32a32_sfloat", {"lens_instances", "rgba"}}},
		framebuffer_count = 1,
		FramebufferSize = {x = INSTANCE_TEXELS, y = MAX_INSTANCES + 1},
		LocalSize = {x = SELECT_THREADS, y = 1, z = 1},
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		sampled_images = {
			{binding_index = 1, get_texture = get_attachment("lens_sources", 1)},
			{binding_index = 2, get_texture = get_attachment("lens_sources", 2)},
			{binding_index = 3, get_texture = get_lens_texture("ghosts")},
			{binding_index = 4, get_texture = get_exposure_texture},
			{
				binding_index = 5,
				get_texture = function()
					return post_source.GetExposureTexture(true)
				end,
			},
		},
		uniform_buffers = {
			{
				name = "instance_data",
				binding_index = 6,
				block = {lens_data_block, {"target_size", "vec2"}},
				write = function(self, block)
					write_lens_block(self, block)
					write_target_size(block)
					return block
				end,
			},
		},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:Dispatch(cmd, 1, 1, 1, desc, self.dynamic_offsets)
		end,
		shader = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_instances;
			layout(set = 0, binding = 1) uniform sampler2D source_position_tex;
			layout(set = 0, binding = 2) uniform sampler2D source_energy_tex;
			layout(set = 0, binding = 3) uniform sampler2D ghost_tex;
			layout(set = 0, binding = 4) uniform sampler2D exposure_tex;
			layout(set = 0, binding = 5) uniform sampler2D prev_exposure_tex;
			const int SOURCES = ]] .. SOURCES .. [[;
			const int THREADS = ]] .. SELECT_THREADS .. [[;
			const float VISIBLE_IRRADIANCE = ]] .. string.format("%.6f", VISIBLE_IRRADIANCE) .. [[;
			shared uint count;
		]] .. post_source.GetPreExposureFromExposureGLSL() .. exposure_model.GetCameraSettingsGLSL("instance_data") .. lens.GetGLSL("instance_data") .. trace_glsl .. [[
			void main() {
				int id = int(gl_LocalInvocationIndex);

				if (id == 0) count = 0u;

				barrier();

				vec2 size = instance_data.target_size;
				float exposure = texture(exposure_tex, vec2(0.5)).r / pre_exposure_from_exposure(texture(prev_exposure_tex, vec2(0.5)).r);
				float n = camera_settings(texture(exposure_tex, vec2(0.5)).r).y;
				float pixels_per_mm = 0.5 * length(size) / instance_data.lens_image_radius;
				float stop_pixels = lens_stop_radius(n) * pixels_per_mm;

				for (int index = id; index < SOURCES * MAX_GHOSTS; index += THREADS) {
					int s = index / MAX_GHOSTS;
					int g = index % MAX_GHOSTS;

					if (g >= instance_data.lens_ghost_count) continue;

					vec3 energy = texelFetch(source_energy_tex, ivec2(s, 0), 0).rgb;

					if (energy.r + energy.g + energy.b <= 0.0) continue;

					vec3 center = texelFetch(ghost_tex, ivec2(0, g), 0).rgb;
					vec3 scale = texelFetch(ghost_tex, ivec2(1, g), 0).rgb;

					vec4 offsets = texelFetch(ghost_tex, ivec2(6, g), 0) * pixels_per_mm;
					vec4 extra = texelFetch(ghost_tex, ivec2(7, g), 0);

					if (ghost_is_traced(s, scale.g, stop_pixels, instance_data.traced, extra.z)) continue;

					vec4 position = texelFetch(source_position_tex, ivec2(s, 0), 0);
					vec2 source = position.xy * size + JITTER_SIGN * 0.5 * instance_data.jitter - 0.5 * size;
					vec3 blur = max(abs(center) * position.z, vec3(1.0));
					vec3 radius = sqrt(scale * scale * stop_pixels * stop_pixels + 0.25 * blur * blur);
					vec3 irradiance = energy * texelFetch(ghost_tex, ivec2(2, g), 0).rgb * instance_data.ghost_intensity / (3.14159265 * radius * radius);

					if (max(irradiance.r, max(irradiance.g, irradiance.b)) * exposure < VISIBLE_IRRADIANCE) continue;

					int slot = int(atomicAdd(count, 1u)) + 1;
					float reach = max(radius.r, max(radius.g, radius.b)) * 1.75 + max(blur.r, max(blur.g, blur.b)) + 1.0;
					imageStore(out_instances, ivec2(0, slot), vec4(center.r * source + offsets.xy, center.g * source + offsets.zw));
					imageStore(out_instances, ivec2(1, slot), vec4(center.b * source + extra.xy * pixels_per_mm, source / pixels_per_mm));
					imageStore(out_instances, ivec2(2, slot), vec4(sign(scale) * radius, float(g)));
					imageStore(out_instances, ivec2(3, slot), vec4(irradiance, reach));
				}

				barrier();

				if (id == 0) imageStore(out_instances, ivec2(0, 0), vec4(float(count), max(stop_pixels, 1e-3), 0.0, 0.0));

				if (id < 3) imageStore(out_instances, ivec2(id + 1, 0), vec4(0.0));
			}
		]],
	},
	{
		name = "lens_ghosts",
		timing_group = "bloom",
		is_enabled = is_ghosts_enabled,
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"lens_ghosts", "rgba"}}},
		framebuffer_count = 1,
		scale = 0.5,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		sampled_images = {
			{binding_index = 1, get_texture = get_attachment("lens_ghost_instances", 1)},
			{binding_index = 2, get_texture = get_lens_texture("ghosts")},
			{binding_index = 3, get_texture = get_exposure_texture},
		},
		uniform_buffers = {
			{
				name = "ghost_data",
				binding_index = 4,
				block = lens_data_block,
				write = write_lens_block,
			},
		},
		shader = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_ghosts;
			layout(set = 0, binding = 1) uniform sampler2D instance_tex;
			layout(set = 0, binding = 2) uniform sampler2D ghost_tex;
			layout(set = 0, binding = 3) uniform sampler2D exposure_tex;
		]] .. compute_helpers.GetScreenHelpersGLSL() .. exposure_model.GetCameraSettingsGLSL("ghost_data") .. lens.GetGLSL("ghost_data") .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_ghosts);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				float n = camera_settings(texture(exposure_tex, vec2(0.5)).r).y;
				float stop_radius = lens_stop_radius(n);
				float curvature = lens_curvature_at(n);
				vec4 header = texelFetch(instance_tex, ivec2(0, 0), 0);
				int count = int(header.x + 0.5);
				float stop_pixels = header.y;
				vec2 from_center = vec2(pos) + 0.5 - 0.5 * vec2(size);
				vec3 sum = vec3(0.0);

				for (int i = 1; i <= count; i++) {
					vec4 centers = texelFetch(instance_tex, ivec2(0, i), 0);
					vec4 brightness = texelFetch(instance_tex, ivec2(3, i), 0);

					if (length(from_center - centers.zw) > brightness.w) continue;

					vec4 rest = texelFetch(instance_tex, ivec2(1, i), 0);
					vec4 radius = texelFetch(instance_tex, ivec2(2, i), 0);
					int g = int(radius.w + 0.5);
					vec4 disks0 = texelFetch(ghost_tex, ivec2(3, g), 0);
					vec4 disks1 = texelFetch(ghost_tex, ivec2(4, g), 0);
					vec2 field_mm = rest.zw;
					vec2 ghost_centers[3] = vec2[3](centers.xy, centers.zw, rest.xy);

					for (int c = 0; c < 3; c++) {
						float r = abs(radius[c]);
						float softness = max(r - abs(texelFetch(ghost_tex, ivec2(1, g), 0)[c]) * stop_pixels, 0.0) * 2.0 + 1.0;
						vec2 q = (from_center - ghost_centers[c]) / radius[c];
						float d = lens_shape_distance(q, curvature);
						d = max(d, lens_disk_distance(q, field_mm, disks0.xy, stop_radius));
						d = max(d, lens_disk_distance(q, field_mm, disks0.zw, stop_radius));
						d = max(d, lens_disk_distance(q, field_mm, disks1.xy, stop_radius));
						d = max(d, lens_disk_distance(q, field_mm, disks1.zw, stop_radius));
						sum[c] += clamp(0.5 - d * r / softness, 0.0, 1.0) * brightness[c];
					}
				}

				imageStore(out_ghosts, pos, vec4(sum, 1.0));
			}
		]],
	},
	{
		name = "lens_ghost_trace",
		timing_group = "bloom",
		is_enabled = is_traced_enabled,
		ComputePass = true,
		ColorFormat = {
			{"r32g32b32a32_sfloat", {"lens_trace_position", "rgba"}},
			{"r32g32b32a32_sfloat", {"lens_trace_stop", "rgba"}},
		},
		framebuffer_count = 1,
		FramebufferSize = {x = lens.TRACE_GRID * lens.TRACE_GRID, y = TRACE_ROWS},
		LocalSize = {x = 64, y = 1, z = 1},
		storage_images = {
			{binding_index = 0, attachment = 1, dst_stage = "vertex_shader"},
			{binding_index = 1, attachment = 2, dst_stage = "vertex_shader"},
		},
		sampled_images = {
			{binding_index = 2, get_texture = get_attachment("lens_sources", 1)},
			{binding_index = 3, get_texture = get_attachment("lens_sources", 2)},
			{binding_index = 4, get_texture = get_lens_texture("ghosts")},
			{binding_index = 5, get_texture = get_lens_texture("surfaces")},
			{binding_index = 6, get_texture = get_exposure_texture},
			{binding_index = 8, get_texture = get_lens_texture("warp")},
		},
		uniform_buffers = {
			{
				name = "trace_data",
				binding_index = 7,
				block = {lens_data_block, {"target_size", "vec2"}},
				write = function(self, block)
					write_lens_block(self, block)
					write_target_size(block)
					return block
				end,
			},
		},
		shader = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_position;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_stop;
			layout(set = 0, binding = 2) uniform sampler2D source_position_tex;
			layout(set = 0, binding = 3) uniform sampler2D source_energy_tex;
			layout(set = 0, binding = 4) uniform sampler2D ghost_tex;
			layout(set = 0, binding = 5) uniform sampler2D surface_tex;
			layout(set = 0, binding = 6) uniform sampler2D exposure_tex;
			layout(set = 0, binding = 8) uniform sampler2D warp_tex;
			const float WARP_ENTRIES = ]] .. lens.WARP_ENTRIES .. [[.0;
		]] .. exposure_model.GetCameraSettingsGLSL("trace_data") .. lens.GetGLSL("trace_data") .. trace_glsl .. [[
		]] .. RAY_GLSL .. [[

			void main() {
				ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
				ivec2 size = imageSize(out_position);

				if (pos.x >= size.x || pos.y >= size.y) return;

				int row = pos.y;
				channel = row % 3;
				int ghost = (row / 3) % MAX_GHOSTS;
				int source = row / (3 * MAX_GHOSTS);
				imageStore(out_stop, pos, vec4(0.0));
				vec3 energy = texelFetch(source_energy_tex, ivec2(source, 0), 0).rgb;
				float n = camera_settings(texture(exposure_tex, vec2(0.5)).r).y;
				stop_radius = lens_stop_radius(n);
				vec2 target_size = trace_data.target_size;
				float pixels_per_mm = 0.5 * length(target_size) / trace_data.lens_image_radius;

				if (ghost >= trace_data.lens_ghost_count || energy.r + energy.g + energy.b <= 0.0 || !ghost_is_traced(source, texelFetch(ghost_tex, ivec2(1, ghost), 0).g, stop_radius * pixels_per_mm, trace_data.traced, texelFetch(ghost_tex, ivec2(7, ghost), 0).z)) {
					imageStore(out_position, pos, vec4(0.0, 0.0, 0.0, -1.0));
					return;
				}

				surface_count = textureSize(surface_tex, 0).y - 1;
				coating0 = texelFetch(surface_tex, ivec2(0, surface_count), 0);
				coating1 = texelFetch(surface_tex, ivec2(1, surface_count), 0);
				vec4 path = texelFetch(ghost_tex, ivec2(5, ghost), 0);
				int i = int(path.x + 0.5);
				int j = int(path.y + 0.5);
				vec2 source_px = texelFetch(source_position_tex, ivec2(source, 0), 0).xy * target_size + JITTER_SIGN * 0.5 * trace_data.jitter - 0.5 * target_size;
				vec2 slope = (-source_px / pixels_per_mm - texelFetch(surface_tex, ivec2(2, surface_count), 0).xy) / trace_data.lens_focal;
				vec2 grid = vec2(pos.x % GRID, pos.x / GRID) / float(GRID - 1) * 2.0 - 1.0;
				vec2 entrance = (grid * TRACE_EXTENT * stop_radius - path.w * slope) / path.z;
				ray_p = vec3(entrance - slope, -1.0);
				ray_d = normalize(vec3(slope, 1.0));
				transmission = 1.0;
				clearance = 1.0;
				stop_q = vec2(0.0);
				stop_seen = false;
				alive = true;

				for (int k = 1; k < j && alive; k++) refract_at(k, medium_index(k - 1), medium_index(k));

				if (alive) reflect_at(j, medium_index(j - 1), medium_index(j));

				for (int k = j - 1; k > i && alive; k--) refract_at(k, medium_index(k), medium_index(k - 1));

				if (alive) reflect_at(i, medium_index(i), medium_index(i - 1));

				for (int k = i + 1; k <= surface_count && alive; k++) refract_at(k, medium_index(k - 1), medium_index(k));

				if (!alive || ray_d.z <= 0.0) {
					imageStore(out_position, pos, vec4(0.0, 0.0, 0.0, -1.0));
					return;
				}

				ray_p += (trace_data.lens_sensor_z - ray_p.z) / ray_d.z * ray_d;
				float actual = length(ray_p.xy) / trace_data.lens_actual_radius;
				float ratio = texture(warp_tex, vec2((min(actual, 1.0) * (WARP_ENTRIES - 1.0) + 0.5) / WARP_ENTRIES, 0.5)).g;
				vec2 ideal = -ray_p.xy / max(length(ray_p.xy), 1e-9) * actual * ratio * 0.5 * length(target_size);
				imageStore(out_position, pos, vec4(ideal + 0.5 * target_size, transmission, clearance));
				imageStore(out_stop, pos, vec4(stop_q, 0.0, 0.0));
			}
		]],
	},
	{
		name = "lens_ghost_raster",
		timing_group = "bloom",
		is_enabled = is_traced_enabled,
		ColorFormat = {{"r16g16b16a16_sfloat", {"lens_traced", "rgba"}}},
		framebuffer_count = 1,
		scale = 0.5,
		vertex = {
			outputs = {
				{"stop", "vec2"},
				{"clearance", "float"},
				{"intensity", "vec3"},
			},
			uniform_buffers = {raster_block},
			shader = [[
				const int GRID = ]] .. lens.TRACE_GRID .. [[;
				const int MAX_GHOSTS = ]] .. lens.MAX_GHOSTS .. [[;
				const float TRACE_EXTENT = ]] .. string.format("%.3f", lens.TRACE_EXTENT) .. [[;
				const float MIN_CELL_PIXELS = ]] .. string.format("%.3f", MIN_CELL_PIXELS) .. [[;
				const ivec2 CORNERS[6] = ivec2[6](ivec2(0, 0), ivec2(1, 0), ivec2(1, 1), ivec2(0, 0), ivec2(1, 1), ivec2(0, 1));

				vec4 traced_vertex(ivec2 g) {
					return texelFetch(TEXTURE(raster_data.position_tex), ivec2(g.x + g.y * GRID, gl_InstanceIndex), 0);
				}

				vec2 neighbour_position(ivec2 g, vec4 self_vertex) {
					if (any(lessThan(g, ivec2(0))) || any(greaterThanEqual(g, ivec2(GRID)))) return self_vertex.xy;

					vec4 v = traced_vertex(g);
					return v.w < -0.5 ? self_vertex.xy : v.xy;
				}

				void main() {
					int quad = gl_VertexIndex / 6;
					ivec2 cell = ivec2(quad % (GRID - 1), quad / (GRID - 1));
					ivec2 g = cell + CORNERS[gl_VertexIndex % 6];
					vec4 v = traced_vertex(g);
					bool quad_alive = v.w > -0.5 && traced_vertex(cell).w > -0.5 && traced_vertex(cell + ivec2(1, 0)).w > -0.5 && traced_vertex(cell + ivec2(0, 1)).w > -0.5 && traced_vertex(cell + ivec2(1, 1)).w > -0.5;

					if (!quad_alive) {
						gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
						out_stop = vec2(0.0);
						out_clearance = -1.0;
						out_intensity = vec3(0.0);
						return;
					}

					vec2 dx = neighbour_position(g + ivec2(1, 0), v) - neighbour_position(g - ivec2(1, 0), v);
					vec2 dy = neighbour_position(g + ivec2(0, 1), v) - neighbour_position(g - ivec2(0, 1), v);
					float span_x = float(min(g.x + 1, GRID - 1) - max(g.x - 1, 0));
					float span_y = float(min(g.y + 1, GRID - 1) - max(g.y - 1, 0));
					int channel = gl_InstanceIndex % 3;
					int source = gl_InstanceIndex / (3 * MAX_GHOSTS);
					int ghost = (gl_InstanceIndex / 3) % MAX_GHOSTS;
					int first_channel = gl_InstanceIndex - channel;
					float dispersion = distance(
						texelFetch(TEXTURE(raster_data.position_tex), ivec2(g.x + g.y * GRID, first_channel), 0).xy,
						texelFetch(TEXTURE(raster_data.position_tex), ivec2(g.x + g.y * GRID, first_channel + 2), 0).xy
					);
					float extent = abs(texelFetch(TEXTURE(raster_data.ghost_tex), ivec2(0, ghost), 0).g) * texelFetch(TEXTURE(raster_data.source_position_tex), ivec2(source, 0), 0).z;
					float smear = max(0.5 * dispersion, 2.0 * extent);
					float cell_pixels = max(abs(dx.x * dy.y - dx.y * dy.x) / (span_x * span_y), max(MIN_CELL_PIXELS, smear * smear));
					float cell_share = pow(2.0 * TRACE_EXTENT / float(GRID - 1), 2.0) / 3.14159265;
					float energy = texelFetch(TEXTURE(raster_data.energy_tex), ivec2(source, 0), 0)[channel];
					vec3 intensity = vec3(0.0);
					intensity[channel] = energy * v.z * cell_share / cell_pixels * raster_data.ghost_intensity;
					vec2 target = vec2(raster_data.target_size);
					gl_Position = vec4(v.xy / target * 2.0 - 1.0, 0.0, 1.0);
					out_stop = texelFetch(TEXTURE(raster_data.stop_tex), ivec2(g.x + g.y * GRID, gl_InstanceIndex), 0).xy;
					out_clearance = v.w;
					out_intensity = intensity;
				}
			]],
		},
		fragment = {
			uniform_buffers = {raster_block},
			shader = exposure_model.GetCameraSettingsGLSL("raster_data") .. lens.GetGLSL("raster_data") .. [[
				void main() {
					float n = camera_settings(texture(TEXTURE(raster_data.exposure_tex), vec2(0.5)).r).y;
					float d = lens_shape_distance(in_stop, lens_curvature_at(n));
					float aperture = clamp(0.5 - d / max(fwidth(d), 1e-4), 0.0, 1.0);
					float clear = clamp(0.5 + in_clearance / max(fwidth(in_clearance), 1e-5), 0.0, 1.0);
					set_lens_traced(vec4(in_intensity * aperture * clear, 0.0));
				}
			]],
		},
		on_draw = function(self, cmd)
			self:UploadConstants()
			cmd:Draw(TRACE_QUADS * 6, TRACE_ROWS, 0, 0)
		end,
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		Blend = true,
		SrcColorBlendFactor = "one",
		DstColorBlendFactor = "one",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "one",
		AlphaBlendOp = "add",
	},
}
return lens_flare
