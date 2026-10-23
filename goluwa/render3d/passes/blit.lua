local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local View = import("goluwa/render3d/view.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local grade = import("goluwa/render3d/grade.lua")
local assets = import("goluwa/assets.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local LOG_EXPOSURE_AT_EV0 = exposure_model.LOG_EXPOSURE_AT_EV0
pvars.StartGroup("Post", "Camera effects", {store = false})
local grain_enabled = pvars.Setup2{
	key = "r_grain",
	default = false,
	help = "film grain that grows with the ISO the camera would pick for the exposure",
}
pvars.EndGroup()
local tonemappers = {agx = 0, agx_punchy = 1, aces = 2, gt7 = 3, neutral = 4}
pvars.StartGroup("Post", "Display", {store = false})
local tonemapper = pvars.Setup2{
	key = "r_tonemapper",
	default = "neutral",
	enums = {"agx", "agx_punchy", "aces", "gt7", "neutral"},
	help = "the curve that maps the exposed scene to the display. neutral keeps the exposed colour as it is and only rolls the highlights off to the display's peak, the others are looks",
}

function render3d.GetTonemapperIndex()
	return tonemappers[tonemapper:Get()]
end

local update_hdr_metadata
local hdr_paper_white = pvars.Setup2{
	key = "r_hdr_paper_white",
	default = 200,
	min = 1,
	help = "nits SDR white is shown at in HDR output",
	callback = function(_, is_init)
		if not is_init then update_hdr_metadata() end
	end,
}
local hdr_peak = pvars.Setup2{
	key = "r_hdr_peak",
	default = 2000,
	min = 1,
	help = "nits of the brightest the display can show in HDR output",
	callback = function(_, is_init)
		if not is_init then update_hdr_metadata() end
	end,
}
local dither = pvars.Setup2{
	key = "r_dither",
	default = true,
	help = "dither the output to hide banding",
}
pvars.EndGroup()

function update_hdr_metadata()
	if not render.target:IsHDR() then return end

	local told = render.target:SetHDRMetadata{
		primaries = {{0.64, 0.33}, {0.30, 0.60}, {0.15, 0.06}, {0.3127, 0.3290}},
		max_luminance = hdr_peak:Get(),
		min_luminance = 0,
		max_content_light_level = hdr_peak:Get(),
		max_frame_average_light_level = hdr_paper_white:Get(),
	}
	logf(
		"[blit] HDR metadata %s: peak %d nits, paper white %d nits\n",
		told and "set" or "unavailable",
		hdr_peak:Get(),
		hdr_paper_white:Get()
	)
end

update_hdr_metadata()

local function get_scene_source_texture()
	return post_source.GetSceneSourceTexture({name = "blit_compute"})
end

local last_exposure_time

local function get_exposure_dt()
	local t = system.GetElapsedTime()
	local dt = last_exposure_time and (t - last_exposure_time) or 1 / 60
	last_exposure_time = t
	return math.clamp(dt, 0.0, 0.1)
end

local function get_exposure_feedback_texture()
	return post_source.GetExposureTexture()
end

local function get_white_balance_texture()
	local pipeline = render3d.pipelines.white_balance_feedback

	if not pipeline or not pipeline.framebuffers then return nil end

	return pipeline:GetFramebuffer():GetAttachment(1)
end

local function get_previous_exposure_texture()
	return post_source.GetExposureTexture(true)
end

local ROD_RESPONSE_GLSL = "const vec3 ROD_RESPONSE = vec3(0.0329, 0.7652, 0.2017);\n"
local ADAPTATION_GLSL = [[
	const float ADAPTATION_EV_MIN = -10.0;
	const float ADAPTATION_EV_MAX = 22.0;
	const float ADAPTATION_ANCHOR_EV = 15.0;
	const float ADAPTATION_REFERENCE = 64.0;
	const float MESOPIC_LOG10_MIN = -2.3;
	const float MESOPIC_LOG10_MAX = 0.7;
	const float SCOTOPIC_PER_PHOTOPIC_D65 = 2.3;

	float log10_of(float x) {
		return log2(x) * 0.30102999566;
	}

	float cone_threshold(float L) {
		float l = log10_of(L);

		if (l <= -2.6) return pow(10.0, -0.72);

		if (l >= 1.9) return pow(10.0, l - 1.255);

		return pow(10.0, pow(0.249 * l + 0.65, 2.7) - 0.72);
	}

	float rod_threshold(float L) {
		float l = log10_of(L);

		if (l <= -3.94) return pow(10.0, -2.86);

		if (l >= -1.44) return pow(10.0, l - 0.395);

		return pow(10.0, pow(0.405 * l + 1.6, 2.18) - 2.86);
	}

	float ward_response(float L) {
		return pow((1.219 + pow(50.0, 0.4)) / (1.219 + pow(L, 0.4)), 2.5) * L;
	}

	float eye_response(float photopic, float scotopic) {
		float cones = smoothstep(MESOPIC_LOG10_MIN, MESOPIC_LOG10_MAX, log10_of(photopic));
		return cones * photopic / cone_threshold(photopic) + (1.0 - cones) * scotopic / rod_threshold(scotopic);
	}

	float adaptation_raw(float ev, float scotopic_ratio) {
		float L = exp2(ev - 3.0);

		if (ev >= 9.0) return log2(ward_response(L) / ward_response(ADAPTATION_REFERENCE));

		return log2(eye_response(L, L * scotopic_ratio) / (ADAPTATION_REFERENCE / cone_threshold(ADAPTATION_REFERENCE)));
	}

	float adaptation_monotone(float ev, float scotopic_ratio) {
		float stops = adaptation_raw(ev, scotopic_ratio);

		for (float e = ev + 0.25; e <= ADAPTATION_EV_MAX; e += 0.25) stops = min(stops, adaptation_raw(e, scotopic_ratio));

		return stops;
	}

	float adaptation_stops(float ev, float scotopic_ratio) {
		return adaptation_monotone(clamp(ev, ADAPTATION_EV_MIN, ADAPTATION_EV_MAX), scotopic_ratio) - adaptation_monotone(ADAPTATION_ANCHOR_EV, scotopic_ratio);
	}
]]
local WHITE_BALANCE_GLSL = [[

	vec2 illuminant_xy(float t) {
		t = clamp(t, 2000.0, 25000.0);
		float x;
		float y;

		if (t < 4000.0) {
			x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910;
			y = t < 2222.0 ?
				-1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683 :
				-0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867;
		} else {
			x = t < 7000.0 ?
				-4.6070e9 / (t * t * t) + 2.9678e6 / (t * t) + 0.09911e3 / t + 0.244063 :
				-2.0064e9 / (t * t * t) + 1.9018e6 / (t * t) + 0.24748e3 / t + 0.237040;
			y = -3.0 * x * x + 2.87 * x - 0.275;
		}

		return vec2(x, y);
	}

	const mat3 SRGB_TO_XYZ = mat3(
		0.4124564, 0.2126729, 0.0193339,
		0.3575761, 0.7151522, 0.1191920,
		0.1804375, 0.0721750, 0.9503041
	);
	const mat3 XYZ_TO_SRGB = mat3(
		3.2404542, -0.9692660, 0.0556434,
		-1.5371385, 1.8760108, -0.2040259,
		-0.4985314, 0.0415560, 1.0572252
	);

	mat3 white_balance_matrix(vec2 xy) {
		const mat3 bradford = mat3(
			0.8951, -0.7502, 0.0389,
			0.2664, 1.7135, -0.0685,
			-0.1614, 0.0367, 1.0296
		);
		const mat3 bradford_inverse = mat3(
			0.9869929, 0.4323053, -0.0085287,
			-0.1470543, 0.5183603, 0.0400428,
			0.1599627, 0.0492912, 0.9684867
		);
		vec3 source = bradford * vec3(xy.x / xy.y, 1.0, (1.0 - xy.x - xy.y) / xy.y);
		vec3 target = bradford * vec3(0.95047, 1.0, 1.08883);
		vec3 gain = target / source;
		mat3 adapt = bradford_inverse * mat3(gain.x, 0.0, 0.0, 0.0, gain.y, 0.0, 0.0, 0.0, gain.z) * bradford;
		return XYZ_TO_SRGB * adapt * SRGB_TO_XYZ;
	}

	vec2 rgb_to_xy(vec3 rgb) {
		vec3 xyz = SRGB_TO_XYZ * rgb;
		return xyz.xy / max(xyz.x + xyz.y + xyz.z, 1e-6);
	}
]]
local exposure_feedback_shader = glsl_common.GetLuminanceGLSL() .. [[
	layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_exposure;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;
	layout(set = 0, binding = 2) uniform sampler2D prev_exposure_tex;
	]] .. post_source.GetPreExposureFromExposureGLSL() .. [[

	#define BINS 128
	#define LOG_MIN -10.0
	#define LOG_MAX 22.0
	#define GRID_X 160
	#define GRID_Y 90

	shared uint bins[BINS];
	shared float clamp_luma;
	shared float partial_light[256];
	shared float partial_weight[256];
	shared float partial_log[256];
	shared float partial_log_scotopic[256];

	float log2_to_ev(float log_luma) {
		return log_luma + 3.0;
	}

	]] .. ROD_RESPONSE_GLSL .. ADAPTATION_GLSL .. [[

	float sample_luma(int n, float to_absolute, out float weight, out float scotopic) {
		vec2 uv = (vec2(n % GRID_X, n / GRID_X) + 0.5) / vec2(GRID_X, GRID_Y);
		weight = 1.0 + 3.0 * (1.0 - smoothstep(0.2, 1.0, length(uv * 2.0 - 1.0)));
		vec3 rgb = textureLod(source_tex, uv, 0.0).rgb * to_absolute;
		scotopic = SCOTOPIC_PER_PHOTOPIC_D65 * dot(rgb, ROD_RESPONSE);
		return luminance(rgb);
	}

	void main() {
		uint id = gl_LocalInvocationIndex;

		for (uint i = id; i < BINS; i += 256u) bins[i] = 0u;

		float to_absolute = 1.0 / pre_exposure_from_exposure(texture(prev_exposure_tex, vec2(0.5)).r);
		barrier();

		for (int n = int(id); n < GRID_X * GRID_Y; n += 256) {
			float weight;
			float scotopic;
			float luma = sample_luma(n, to_absolute, weight, scotopic);
			float bin = clamp((log2(max(luma, 1e-6)) - LOG_MIN) / (LOG_MAX - LOG_MIN) * float(BINS), 0.0, float(BINS - 1));
			atomicAdd(bins[int(bin)], uint(weight));
		}

		barrier();

		if (id == 0u) {
			float total = 0.0;

			for (int i = 0; i < BINS; i++) total += float(bins[i]);

			float cut = total * compute.high_percent;
			float running = 0.0;
			int top = BINS - 1;

			for (int i = 0; i < BINS; i++) {
				running += float(bins[i]);

				if (running >= cut) {
					top = i;
					break;
				}
			}

			clamp_luma = exp2(LOG_MIN + (float(top) + 1.0) / float(BINS) * (LOG_MAX - LOG_MIN));
		}

		barrier();

		float light = 0.0;
		float light_weight = 0.0;
		float log_light = 0.0;
		float log_scotopic = 0.0;

		for (int n = int(id); n < GRID_X * GRID_Y; n += 256) {
			float weight;
			float scotopic;
			float luma = sample_luma(n, to_absolute, weight, scotopic);
			light += min(luma, clamp_luma) * weight;
			light_weight += weight;
			log_light += log2(max(luma, 1e-6));
			log_scotopic += log2(max(scotopic, 1e-6));
		}

		partial_light[id] = light;
		partial_weight[id] = light_weight;
		partial_log[id] = log_light;
		partial_log_scotopic[id] = log_scotopic;
		barrier();

		if (id != 0u) return;

		float light_sum = 0.0;
		float weight_sum = 0.0;
		float log_sum = 0.0;
		float log_scotopic_sum = 0.0;

		for (int i = 0; i < 256; i++) {
			light_sum += partial_light[i];
			weight_sum += partial_weight[i];
			log_sum += partial_log[i];
			log_scotopic_sum += partial_log_scotopic[i];
		}

		float metered_ev = compute.eye != 0 ?
			log2_to_ev(log_sum / float(GRID_X * GRID_Y)) :
			log2_to_ev(log2(max(light_sum / max(weight_sum, 1.0), 1e-6)));
		float ev;

		if (compute.eye != 0) {
			float adapting_ev = clamp(metered_ev, compute.min_ev, compute.max_ev);
			float scotopic_ratio = exp2((log_scotopic_sum - log_sum) / float(GRID_X * GRID_Y));
			ev = adapting_ev - adaptation_stops(adapting_ev, scotopic_ratio) - compute.compensation;
		} else {
			ev = clamp(metered_ev - compute.compensation, compute.min_ev, compute.max_ev);
		}

		if (compute.lock != 0) ev = compute.lock_ev - compute.compensation;

		float log_target = ]] .. LOG_EXPOSURE_AT_EV0 .. [[ - ev;
		vec4 prev = texture(prev_exposure_tex, vec2(0.5));

		if (!(prev.r > 0.0)) prev.b = metered_ev;

		if (!(prev.r > 0.0) || compute.lock != 0) prev.r = exp2(log_target);

		float log_prev = log2(prev.r);
		float tau = log_target > log_prev ? compute.tau_darken : compute.tau_brighten;
		float k = 1.0 - exp(-compute.dt / tau);
		float adapted_k = 1.0 - exp(-compute.dt / (metered_ev < prev.b ? compute.tau_darken : compute.tau_brighten));
		imageStore(out_exposure, ivec2(0, 0), vec4(exp2(log_prev + (log_target - log_prev) * k), metered_ev, prev.b + (metered_ev - prev.b) * adapted_k, 1.0));
	}
]]
local exposure_feedback_pass = {
	name = "exposure_feedback",
	ComputePass = true,
	ColorFormat = {
		{"r32g32b32a32_sfloat", {"exposure", "rgba"}},
		{"r32g32b32a32_sfloat", {"exposure_prev", "rgba"}},
	},
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 16, y = 16, z = 1},
	storage_images = {
		{
			binding_index = 0,
			get_texture = get_exposure_feedback_texture,
			dst_stage = "compute",
		},
	},
	sampled_images = {
		{
			binding_index = 1,
			get_texture = function()
				return post_source.GetSceneSourceTexture({name = "exposure_feedback"})
			end,
		},
		{
			binding_index = 2,
			get_texture = function()
				return post_source.GetExposureTexture(true)
			end,
		},
	},
	block = {
		{"dt", "float"},
		{"lock", "int"},
		{"lock_ev", "float"},
		{"compensation", "float"},
		{"eye", "int"},
		{"min_ev", "float"},
		{"max_ev", "float"},
		{"high_percent", "float"},
		{"tau_brighten", "float"},
		{"tau_darken", "float"},
	},
	write = function(self, block)
		local view = View.GetActive()
		local eye = exposure_model.IsEye()
		local lock = view and view.ExposureLock or exposure_model.GetManualEV()
		local meter = eye and exposure_model.eye or exposure_model.camera
		local min_ev, max_ev = exposure_model.GetRange()
		block.dt = get_exposure_dt()
		block.lock = lock and 1 or 0
		block.lock_ev = lock or 0
		block.compensation = view and view.ExposureCompensation or exposure_model.GetCompensation()
		block.eye = eye and 1 or 0
		block.min_ev = min_ev
		block.max_ev = max_ev
		block.high_percent = meter.high_percent
		block.tau_brighten = meter.tau_brighten
		block.tau_darken = meter.tau_darken
		return block
	end,
	shader = exposure_feedback_shader,
}

local function get_bloom_texture()
	local pipeline = render3d.pipelines.bloom_up1
	return pipeline and pipeline:GetFramebuffer():GetAttachment(1) or nil
end

local function get_bloom_strength()
	return get_bloom_texture() and
		math.min(select(2, render3d.GetBloomWeights()) * render3d.bloom_strength:Get(), 1) or
		0
end

local glare_pass

do
	local last_frame = -1
	local last_width, last_height = 0, 0

	local function get_history_texture()
		return render3d.pipelines.glare:GetFramebuffer((system.GetFrameNumber() + 1) % 2 + 1):GetAttachment(1)
	end

	glare_pass = {
		name = "glare",
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"glare", "rgba"}}},
		framebuffer_count = 2,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		sampled_images = {
			{binding_index = 1, get_texture = get_bloom_texture},
			{binding_index = 2, get_texture = get_history_texture},
			{binding_index = 3, get_texture = get_exposure_feedback_texture},
			{binding_index = 4, get_texture = get_previous_exposure_texture},
		},
		block = {
			{"bloom_strength", "float"},
			{"history_valid", "int"},
			{"persistence", "float"},
		},
		write = function(self, block)
			local frame = system.GetFrameNumber()
			local size = render.GetRenderImageSize()
			block.bloom_strength = get_bloom_strength()
			block.history_valid = (
					render3d.bloom_smear:Get() > 0 and
					last_frame == frame - 1 and
					last_width == size.x and
					last_height == size.y
				)
				and
				1 or
				0
			block.persistence = render3d.bloom_smear:Get() > 0 and
				math.exp(-system.GetFrameTime() / render3d.bloom_smear:Get()) or
				0
			last_frame = frame
			last_width, last_height = size.x, size.y
			return block
		end,
		shader = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_glare;
			layout(set = 0, binding = 1) uniform sampler2D bloom_tex;
			layout(set = 0, binding = 2) uniform sampler2D history_tex;
			layout(set = 0, binding = 3) uniform sampler2D exposure_tex;
			layout(set = 0, binding = 4) uniform sampler2D prev_exposure_tex;
		]] .. post_source.GetPreExposureFromExposureGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_glare);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec2 uv = get_screen_uv(pos, size);
				vec2 half_texel = 0.5 / vec2(textureSize(bloom_tex, 0));
				float exposure = texture(exposure_tex, vec2(0.5)).r / pre_exposure_from_exposure(texture(prev_exposure_tex, vec2(0.5)).r);
				vec3 glare = textureLod(bloom_tex, clamp(uv, half_texel, 1.0 - half_texel), 0.0).rgb * compute.bloom_strength * exposure;

				if (compute.history_valid != 0) {
					glare = mix(glare, texelFetch(history_tex, pos, 0).rgb, compute.persistence);
				}

				imageStore(out_glare, pos, vec4(glare, 1.0));
			}
		]],
	}
end

local function get_glare_texture()
	return render3d.pipelines.glare:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1)
end

local compute_shader = [[
	layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;
	layout(set = 0, binding = 2) uniform sampler2D bloom_tex;
	layout(set = 0, binding = 3) uniform sampler2D glare_tex;
	layout(set = 0, binding = 4) uniform sampler2D exposure_tex;
	layout(set = 0, binding = 5) uniform sampler2D prev_exposure_tex;
	layout(set = 0, binding = 6) uniform sampler2D blue_noise_tex;
	layout(set = 0, binding = 7) uniform sampler2D white_balance_tex;
	]] .. post_source.GetPreExposureFromExposureGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. glsl_common.GetBlueNoiseGLSL() .. compute_helpers.GetColorHelpersGLSL() .. grade.GetGLSL("compute") .. WHITE_BALANCE_GLSL .. [[

	float effective_paper_white;

	vec3 tonemap_hdr(vec3 x, float peak, int tonemapper) {
		x = max(x, vec3(0.0));

		if (tonemapper == 3) {
			float paper_white = effective_paper_white / 100.0;
			return gt7(x * paper_white, peak * paper_white) / paper_white;
		}

		if (tonemapper == 4) return neutral(x, peak);

		const float knee = 0.6;
		float m = max(x.r, max(x.g, x.b));

		if (m <= knee) return mix(tonemap(x, tonemapper), x, smoothstep(0.25, 0.45, m));

		float range = peak - knee;
		float mapped = knee + range * (1.0 - exp(-(m - knee) / range));
		float compressed = 1.0 - mapped / m;
		return mix(x * (mapped / m), vec3(mapped), compressed * compressed);
	}

	]] .. ROD_RESPONSE_GLSL .. [[

	]] .. exposure_model.GetCameraSettingsGLSL("compute") .. [[

	uint pcg_hash(uint v) {
		uint state = v * 747796405u + 2891336453u;
		uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
		return (word >> 22u) ^ word;
	}

	vec3 blue_noise(ivec2 pos) {
		vec3 noise = vec3(blue_noise_texel(blue_noise_tex, pos).rg, blue_noise_texel(blue_noise_tex, pos + ivec2(37, 19)).r);
		return fract(noise + 0.61803398875 * float(compute.frame % 16));
	}

	void main() {
		ivec2 pos = get_screen_pos();
		ivec2 size = imageSize(out_color);

		if (!is_screen_pos_in_bounds(pos, size)) return;

		if (compute.has_source_tex == 0) {
			imageStore(out_color, pos, vec4(1.0, 0.0, 1.0, 1.0));
			return;
		}

		vec2 uv = get_screen_uv(pos, size);
		vec3 col = texture(source_tex, uv).rgb;

		if (compute.white_balance_on != 0) {
			vec2 illuminant = vec2(0.3127, 0.3290);

			if (compute.white_balance > 0.0) {
				illuminant = illuminant_xy(compute.white_balance);
				illuminant.y += compute.white_balance_tint * 0.02;
			} else {
				vec4 estimate = texture(white_balance_tex, vec2(0.5));

				if (estimate.z > 0.5) illuminant = estimate.xy;
			}

			col = max(white_balance_matrix(illuminant) * col, vec3(0.0));
		}
		float exposure = compute.has_exposure_tex != 0 ? texture(exposure_tex, vec2(0.5)).r : exp2(]] .. LOG_EXPOSURE_AT_EV0 .. [[ - 10.0);
		float pre_exposure = pre_exposure_from_exposure(compute.has_exposure_tex != 0 ? texture(prev_exposure_tex, vec2(0.5)).r : 0.0);
		exposure /= pre_exposure;

		float adapted_ev = compute.has_exposure_tex != 0 ? texture(exposure_tex, vec2(0.5)).b : 10.0;
		float display_scale = pow(min(exp2(adapted_ev - 3.0) / 64.0, 1.0), compute.viewer_adaptation);
		effective_paper_white = compute.hdr_paper_white * display_scale;
		float pixel_log10 = log(max(luminance(col) / pre_exposure, 1e-9)) * 0.4342945;
		float cones = smoothstep(compute.night_vision_log10_threshold - 1.5, compute.night_vision_log10_threshold + 1.5, max((adapted_ev - 3.0) * 0.30103, pixel_log10));

		if (compute.has_bloom_tex != 0) {
			col = col * (1.0 - compute.bloom_strength) + texelFetch(glare_tex, pos, 0).rgb / exposure;
		}

		col = mix(col, vec3(dot(max(col, vec3(0.0)), ROD_RESPONSE)), (1.0 - cones) * compute.night_vision);

		if (compute.grain != 0 && compute.has_exposure_tex != 0) {
			float iso = camera_settings(texture(exposure_tex, vec2(0.5)).r).x;
			uint h = pcg_hash(uint(pos.x) + pcg_hash(uint(pos.y) + pcg_hash(uint(compute.frame))));
			float grain = float(h & 0xffffu) / 65535.0 + float(h >> 16) / 65535.0 - 1.0;
			col *= 1.0 + 0.006 * sqrt(max(iso / 100.0 - 1.0, 0.0)) * grain;
		}

		if (compute.output_mode == 0) {
			col = compute.debug_passthrough != 0 ? clamp(col, 0.0, 1.0) : grade_display(clamp(tonemap(col * exposure, compute.tonemapper), 0.0, 1.0)) * display_scale;

			col = SRGBToLinear(dither(LinearToSRGB(col), blue_noise(pos), compute.dither_steps));

			if (compute.requires_manual_gamma == 1) col = LinearToSRGB(col);
		} else {
			vec3 nits = compute.debug_passthrough != 0 ? clamp(col, 0.0, 1.0) * compute.hdr_paper_white : grade_display_hdr(tonemap_hdr(col * exposure, compute.hdr_peak / effective_paper_white, compute.tonemapper)) * effective_paper_white;

			if (compute.output_mode == 1) {
				col = pq_decode(dither(pq_encode(nits), blue_noise(pos), compute.dither_steps)) / 80.0;
			} else {
				const mat3 bt709_to_bt2020 = mat3(
					0.6274, 0.0691, 0.0164,
					0.3293, 0.9195, 0.0880,
					0.0433, 0.0114, 0.8956
				);
				col = dither(pq_encode(bt709_to_bt2020 * nits), blue_noise(pos), compute.dither_steps);
			}
		}

		imageStore(out_color, pos, vec4(col, 1.0));
	}
]]
local white_balance_feedback_shader = glsl_common.GetLuminanceGLSL() .. [[

	layout(set = 0, binding = 0, rgba32f) uniform image2D white_balance_state;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;
	]] .. WHITE_BALANCE_GLSL .. [[

	#define GRID_X 160
	#define GRID_Y 90
	shared uint chroma_sum[3];
	shared uint chroma_weight;

	void main() {
		uint id = gl_LocalInvocationIndex;

		if (id < 3u) chroma_sum[id] = 0u;

		if (id == 0u) chroma_weight = 0u;

		barrier();

		for (int n = int(id); n < GRID_X * GRID_Y; n += 256) {
			vec2 uv = (vec2(n % GRID_X, n / GRID_X) + 0.5) / vec2(GRID_X, GRID_Y);
			vec3 rgb = textureLod(source_tex, uv, 0.0).rgb;
			vec3 chroma = clamp(rgb / max(luminance(rgb), 1e-9), vec3(0.0), vec3(4.0));
			float weight = 1.0 + 3.0 * (1.0 - smoothstep(0.2, 1.0, length(uv * 2.0 - 1.0)));
			atomicAdd(chroma_sum[0], uint(chroma.r * weight * 64.0));
			atomicAdd(chroma_sum[1], uint(chroma.g * weight * 64.0));
			atomicAdd(chroma_sum[2], uint(chroma.b * weight * 64.0));
			atomicAdd(chroma_weight, uint(weight * 64.0));
		}

		barrier();

		if (id != 0u) return;

		vec3 mean = vec3(float(chroma_sum[0]), float(chroma_sum[1]), float(chroma_sum[2])) / max(float(chroma_weight), 1.0);
		vec2 xy = rgb_to_xy(mean);
		xy.x = clamp(xy.x, 0.28, 0.44);
		float locus = -3.0 * xy.x * xy.x + 2.87 * xy.x - 0.275;
		xy.y = clamp(xy.y, locus - 0.02, locus + 0.02);
		vec4 prev = imageLoad(white_balance_state, ivec2(0, 0));
		float k = 1.0 - exp(-compute.dt / compute.tau);
		imageStore(white_balance_state, ivec2(0, 0), vec4(prev.z > 0.5 ? mix(prev.xy, xy, k) : xy, 1.0, 1.0));
	}
]]
local white_balance_feedback_pass = {
	name = "white_balance_feedback",
	ComputePass = true,
	is_enabled = function()
		return not exposure_model.IsEye() and exposure_model.Get("camera.white_balance") == 0
	end,
	ColorFormat = {{"r32g32b32a32_sfloat", {"white_balance", "rgba"}}},
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 16, y = 16, z = 1},
	storage_images = {
		{
			binding_index = 0,
			get_texture = get_white_balance_texture,
			dst_stage = "compute",
		},
	},
	sampled_images = {
		{
			binding_index = 1,
			get_texture = function()
				return post_source.GetSceneSourceTexture({name = "white_balance_feedback"})
			end,
		},
	},
	block = {
		{"dt", "float"},
		{"tau", "float"},
	},
	write = function(self, block)
		block.dt = math.clamp(system.GetFrameTime(), 0, 0.1)
		block.tau = exposure_model.camera.tau_darken
		return block
	end,
	shader = white_balance_feedback_shader,
}
local r = {
	exposure_feedback_pass,
	white_balance_feedback_pass,
}

for _, pass in ipairs(import("goluwa/render3d/passes/bloom.lua")()) do
	r[#r + 1] = pass
end

r[#r + 1] = glare_pass

for _, pass in ipairs{
	{
		name = "blit_compute",
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "fragment",
			},
		},
		sampled_images = {
			{
				binding_index = 1,
				get_texture = get_scene_source_texture,
			},
			{
				binding_index = 2,
				get_texture = get_bloom_texture,
			},
			{
				binding_index = 3,
				get_texture = get_glare_texture,
			},
			{
				binding_index = 4,
				get_texture = get_exposure_feedback_texture,
			},
			{
				binding_index = 5,
				get_texture = get_previous_exposure_texture,
			},
			{
				binding_index = 6,
				get_texture = function()
					return assets.GetTexture("textures/render/blue_noise.lua")
				end,
			},
			{binding_index = 7, get_texture = get_white_balance_texture},
		},
		block = {
			{"has_source_tex", "int"},
			{"frame", "int"},
			{"has_bloom_tex", "int"},
			{"requires_manual_gamma", "int"},
			{"output_mode", "int"},
			{"hdr_paper_white", "float"},
			{"viewer_adaptation", "float"},
			{"hdr_peak", "float"},
			{"dither_steps", "float"},
			{"has_exposure_tex", "int"},
			{"tonemapper", "int"},
			{"bloom_strength", "float"},
			{"night_vision", "float"},
			{"night_vision_log10_threshold", "float"},
			{"debug_passthrough", "int"},
			{"white_balance_on", "int"},
			{"white_balance", "float"},
			{"white_balance_tint", "float"},
			{"grain", "int"},
			exposure_model.camera_block,
			grade.block,
		},
		write = function(self, block)
			block.has_source_tex = get_scene_source_texture() and 1 or 0
			block.frame = system.GetFrameNumber()
			block.has_bloom_tex = get_bloom_texture() and 1 or 0
			block.has_exposure_tex = get_exposure_feedback_texture() and 1 or 0
			block.requires_manual_gamma = render.target:RequiresManualGamma() and 1 or 0
			block.output_mode = render.target:GetColorSpace() == "extended_srgb_linear_ext" and
				1 or
				render.target:GetColorSpace() == "hdr10_st2084_ext" and
				2 or
				0
			block.hdr_paper_white = hdr_paper_white:Get()
			block.viewer_adaptation = exposure_model.IsEye() and exposure_model.Get("eye.viewer_adaptation") or 0
			block.hdr_peak = hdr_peak:Get()
			local bits = render.target:GetColorBits()

			if bits >= 16 then bits = render.target:IsHDR() and 10 or 8 end

			block.dither_steps = dither:Get() and 2 ^ bits - 1 or 0
			block.tonemapper = render3d.GetTonemapperIndex()
			block.bloom_strength = get_bloom_strength()
			block.night_vision = exposure_model.IsEye() and exposure_model.Get("eye.night_vision") and 1 or 0
			block.night_vision_log10_threshold = math.log(exposure_model.Get("eye.night_vision_threshold")) / math.log(10)
			block.debug_passthrough = post_source.GetDebugTexture() and 1 or 0
			block.white_balance_on = not exposure_model.IsEye() and 1 or 0
			block.white_balance = exposure_model.Get("camera.white_balance")
			block.white_balance_tint = exposure_model.Get("camera.white_balance_tint")
			block.grain = grain_enabled:Get() and 1 or 0
			exposure_model.WriteCameraBlock(block)
			grade.WriteBlock(block)

			if block.debug_passthrough == 1 then
				block.has_bloom_tex = 0
				block.night_vision = 0
				block.white_balance_on = 0
				block.grade_on = 0
			end

			return block
		end,
		shader = compute_shader,
	},
	{
		name = "blit",
		RasterizationSamples = function()
			return render.target.samples
		end,
		on_pre_draw = function(self)
			self._cached_blit_source_tex = -1

			for _, pipeline in ipairs(render3d.pipelines_i) do
				local texture = pipeline.present_texture and pipeline.present_texture()

				if texture then
					self._cached_blit_source_tex = self:GetTextureIndex(texture)
					return
				end
			end

			if not render3d.pipelines.blit_compute then return end

			local framebuffer = render3d.pipelines.blit_compute:GetFramebuffer()

			if not framebuffer then return end

			local texture = framebuffer:GetAttachment(1)

			if not texture then return end

			self._cached_blit_source_tex = self:GetTextureIndex(texture)
		end,
		fragment = {
			push_constants = {
				{
					name = "blit_present",
					block = {
						{"source_tex", "int"},
					},
					write = function(self, block)
						block.source_tex = self._cached_blit_source_tex or -1
						return block
					end,
				},
			},
			shader = [[
				layout(location = 0) out vec4 frag_color;

				void main() {
					if (blit_present.source_tex == -1) {
						frag_color = vec4(1.0, 0.0, 1.0, 1.0);
						return;
					}

					frag_color = texture(TEXTURE(blit_present.source_tex), in_uv);
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "blit_scene",
		fallback = true,
		draw_in_prerender = false,
		RasterizationSamples = function()
			return render.target.samples
		end,
		on_pre_draw = function(self)
			self._scene_tex = self:GetTextureIndex(post_source.GetSceneSourceTexture({name = "blit_scene"}))
		end,
		fragment = {
			push_constants = {
				{
					name = "blit_present",
					block = {
						{"source_tex", "int"},
						{"scale", "float"},
					},
					write = function(self, block)
						block.source_tex = self._scene_tex
						block.scale = render.target:IsHDR() and 1 or 1 / post_source.UNEXPOSED_SDR_WHITE
						return block
					end,
				},
			},
			shader = [[
				layout(location = 0) out vec4 frag_color;

				void main() {
					frag_color = vec4(texture(TEXTURE(blit_present.source_tex), in_uv).rgb * blit_present.scale, 1.0);
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
} do
	r[#r + 1] = pass
end

return r
