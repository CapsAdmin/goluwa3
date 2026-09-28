local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local View = import("goluwa/render3d/view.lua")
local assets = import("goluwa/assets.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local KEY = 0.28
-- exposure = 2^(LOG_EXPOSURE_AT_EV0 - ev): KEY / luminance, with luminance =
-- 2^ev * 12.5 / 100
local LOG_EXPOSURE_AT_EV0 = math.log(KEY * 8) / math.log(2)
-- Exposure is metered in EV100 (log2 of scene luminance * 100 / 12.5, the
-- reflected light meter calibration): about 15 in sunlight, 8-10 in a lit
-- room, 0-3 at night. exposure = KEY / (average luminance) maps the metered
-- average to KEY. That is above photographic middle grey (0.18) because AgX
-- renders 0.18 darker than the old ACES fit did; 0.28 looks about as bright.
--
-- mode "camera" is a camera's auto exposure: every scene's average is shown at
-- KEY, and there is no night vision.
--
-- mode "eye" shows what a person would see. The eye doesn't fully adapt: a
-- night street stays dark and noon stays bright. The metered average is shown
-- adaptation_stops stops above KEY, 0 at a lit room (EV 9). Darker than that
-- the curve follows Ferwerda et al. 1996 ("A model of visual adaptation for
-- realistic image synthesis"): brightness goes with L / threshold(L), the
-- cones' and the rods' threshold versus intensity weighted by the same mesopic
-- share of cones the night vision uses, so one adaptation state decides both
-- how dark the night is and how much of its colour is lost. The rods keep a
-- night 3-4 stops under a lit room, where the cones alone would make it 7-9;
-- dusk, where the cones are fading and the rods aren't much help yet, is the
-- hardest to see. Brighter than EV 9 the thresholds grow as fast as the light
-- (Weber's law) and would show noon as bright as a room; Ward 1994's contrast
-- based scale factor (for a 100 nit display) keeps noon a little brighter.
-- The curve is made monotonic: a darker scene is never shown brighter.
--
-- Ferwerda's model matches how visible detail is, which makes nights look
-- brighter than they feel: with rods the curve is almost flat from dusk to
-- moonlight. rod_adaptation blends its dark end from the cones alone (0, a
-- night keeps getting darker with the light) to the full rod response (1).
render3d.exposure = {
	mode = "eye",
	rod_adaptation = 0.5,
	lock = nil,
	compensation = 0,
	min_ev = -4,
	max_ev = 18,
	-- the metered average is taken between these fractions of the (centre
	-- weighted) luminance histogram, ignoring the darkest corners and the
	-- brightest highlights
	low_percent = 0.4,
	high_percent = 0.95,
	tau_brighten = 0.5,
	tau_darken = 1.5,
}
-- Local exposure (the eye's local adaptation): each pixel is exposed partly
-- for its surroundings, so a dark corner next to a bright window both read.
-- The surroundings are the average log luminance of the pixels near it on
-- screen AND close to it in brightness (a bilateral grid, as in Unreal's local
-- exposure), so the window's light doesn't bleed a halo over the wall next to
-- it. A strength of 1 would expose every region to KEY (flat); 0 is
-- off. The adjustment is capped at max_stops either way.
render3d.local_exposure = {
	shadows = 0.4,
	highlights = 0.4,
	max_stops = 4,
}
-- 0 = AgX, 1 = AgX punchy, 2 = ACES (Narkowicz fit). SDR output only; HDR
-- output has its own curve (tonemap_hdr).
render3d.tonemapper = 0
-- HDR output (--hdr, see ImageRenderTarget:IsHDR), in nits: paper white is
-- what SDR white (and the metered average's surroundings) is shown at, 203 by
-- BT.2408; peak is the brightest the display can show. Vulkan can't query the
-- display, so match these to it (KDE's HDR settings show both).
render3d.hdr = {
	paper_white = 203,
	peak = 1000,
}
render3d.bloom_strength = 0.04
-- the eye's switch to rod vision in dim light (mode "eye" only): colour fades
-- and reds darken (the Purkinje shift). threshold is the luminance in cd/m2 at
-- which half the colour is gone, the fade spanning 1.5 decades either side of
-- it; the default is the middle of CIE 191's mesopic range (0.005 to 5). tint
-- is how blue what the rods see is shown, 0 neutral grey and 1 the film
-- convention of Jensen et al. 2000. Rods can't tell colours apart, the blue is
-- a perceptual trick rather than what they see. The adaptation curve keeps
-- CIE's range, these only change how the loss of colour looks.
render3d.night_vision = {
	enabled = true,
	threshold = 0.03,
	tint = 0.5,
}

commands.Add("r_exposure_lock=number|nil", function(ev)
	render3d.exposure.lock = ev
	logf("[blit] exposure %s\n", ev and ("locked at EV " .. ev) or "auto")
end)

commands.Add("r_exposure_compensation=number[0]", function(stops)
	render3d.exposure.compensation = stops
end)

commands.Add("r_exposure_rod_adaptation=number[0.65]", function(value)
	render3d.exposure.rod_adaptation = value
end)

commands.Add("r_exposure_mode=string[eye]", function(mode)
	assert(mode == "eye" or mode == "camera", "exposure mode is eye or camera")
	render3d.exposure.mode = mode
end)

commands.Add("r_tonemapper=string[agx]", function(name)
	render3d.tonemapper = assert(({agx = 0, agx_punchy = 1, aces = 2})[name], "tonemapper is one of agx, agx_punchy, aces")
end)

commands.Add("r_local_exposure=number[0.4],number|nil", function(shadows, highlights)
	render3d.local_exposure.shadows = shadows
	render3d.local_exposure.highlights = highlights or shadows
end)

commands.Add("r_bloom_strength=number[0.04]", function(value)
	render3d.bloom_strength = value
end)

-- Tells the compositor or display the range our HDR output uses (see
-- VK_EXT_hdr_metadata): nothing brighter than peak, frames averaging no more
-- than paper white, in BT.709's gamut (scRGB's primaries; HDR10 output is
-- converted from BT.709 too). With that, one whose display can't reach peak
-- compresses our highlights instead of clipping them, and one that can passes
-- them through without tonemapping them a second time. Set when it changes,
-- not per frame, since displays may visibly re-adapt on every change.
local function update_hdr_metadata()
	if not render.target:IsHDR() then return end

	local told = render.target:SetHDRMetadata{
		primaries = {{0.64, 0.33}, {0.30, 0.60}, {0.15, 0.06}, {0.3127, 0.3290}},
		max_luminance = render3d.hdr.peak,
		min_luminance = 0,
		max_content_light_level = render3d.hdr.peak,
		max_frame_average_light_level = render3d.hdr.paper_white,
	}
	logf(
		"[blit] HDR metadata %s: peak %d nits, paper white %d nits\n",
		told and "set" or "unavailable",
		render3d.hdr.peak,
		render3d.hdr.paper_white
	)
end

update_hdr_metadata()

commands.Add("r_hdr_paper_white=number[203]", function(nits)
	render3d.hdr.paper_white = nits
	update_hdr_metadata()
end)

commands.Add("r_hdr_peak=number[1000]", function(nits)
	render3d.hdr.peak = nits
	update_hdr_metadata()
end)

commands.Add("r_bloom_scatter=number[0.7]", function(value)
	render3d.bloom_scatter = value
end)

commands.Add("r_bloom_max=number[10000]", function(value)
	render3d.bloom_max = value
end)

commands.Add("r_night_vision=boolean[true]", function(enabled)
	render3d.night_vision.enabled = enabled
end)

commands.Add("r_night_vision_threshold=number[0.03]", function(cd_m2)
	render3d.night_vision.threshold = cd_m2
end)

commands.Add("r_night_vision_tint=number[0.3]", function(value)
	render3d.night_vision.tint = value
end)

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

-- what the scene was pre-exposed with (see post_source.PRE_EXPOSURE_HEADROOM)
local function get_previous_exposure_texture()
	return post_source.GetExposureTexture(true)
end

local MESOPIC_LOG10_MIN = -2.3
local MESOPIC_LOG10_MAX = 0.7
local ADAPTATION_CURVE_EV_MIN = -10
local ADAPTATION_CURVE_EV_STEP = 0.5
local ADAPTATION_CURVE_COUNT = 65
-- stops the metered average is shown above KEY in mode "eye", per metered EV
-- from ADAPTATION_CURVE_EV_MIN in ADAPTATION_CURVE_EV_STEP steps (see
-- render3d.exposure), with the rods and with the cones alone, as comma
-- separated GLSL lists
local ADAPTATION_CURVE_RODS_GLSL
local ADAPTATION_CURVE_CONES_GLSL

do
	local function log10(x)
		return math.log(x) / math.log(10)
	end

	-- threshold versus intensity in cd/m2, Ferwerda et al. 1996
	local function cone_threshold(L)
		local l = log10(L)

		if l <= -2.6 then return 10 ^ -0.72 end

		if l >= 1.9 then return 10 ^ (l - 1.255) end

		return 10 ^ ((0.249 * l + 0.65) ^ 2.7 - 0.72)
	end

	local function rod_threshold(L)
		local l = log10(L)

		if l <= -3.94 then return 10 ^ -2.86 end

		if l >= -1.44 then return 10 ^ (l - 0.395) end

		return 10 ^ ((0.405 * l + 1.6) ^ 2.18 - 2.86)
	end

	local function eye(L)
		local cones = math.smoothstep(MESOPIC_LOG10_MIN, MESOPIC_LOG10_MAX, log10(L))
		return cones * L / cone_threshold(L) + (1 - cones) * L / rod_threshold(L)
	end

	local function ward(L)
		return ((1.219 + 50 ^ 0.4) / (1.219 + L ^ 0.4)) ^ 2.5 * L
	end

	local function cones(L)
		return L / cone_threshold(L)
	end

	local reference = 2 ^ (9 - 3)

	local function build(response)
		local curve = {}

		for i = 1, ADAPTATION_CURVE_COUNT do
			local ev = ADAPTATION_CURVE_EV_MIN + (i - 1) * ADAPTATION_CURVE_EV_STEP
			local L = 2 ^ (ev - 3)
			curve[i] = ev >= 9 and
				math.log(ward(L) / ward(reference)) / math.log(2)
				or
				math.log(response(L) / response(reference)) / math.log(2)
		end

		for i = ADAPTATION_CURVE_COUNT - 1, 1, -1 do
			curve[i] = math.min(curve[i], curve[i + 1])
		end

		for i, stops in ipairs(curve) do
			curve[i] = string.format("%.5f", stops)
		end

		return table.concat(curve, ", ")
	end

	ADAPTATION_CURVE_RODS_GLSL = build(eye)
	ADAPTATION_CURVE_CONES_GLSL = build(cones)
end

-- r = exposure multiplier, g = the metered EV100 before adaptation and
-- compensation (for r_exposure_info), b = the metered EV100 the eye has adapted
-- to (g smoothed over time, what night vision is driven by)
local exposure_feedback_shader = [[
	layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_exposure;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;
	layout(set = 0, binding = 2) uniform sampler2D prev_exposure_tex;
	]] .. post_source.GetPreExposureFromExposureGLSL() .. [[

	#define BINS 128
	// log2 luminance range of the histogram
	#define LOG_MIN -10.0
	#define LOG_MAX 22.0
	#define GRID_X 160
	#define GRID_Y 90

	shared uint bins[BINS];

	float log2_to_ev(float log_luma) {
		return log_luma + 3.0; // log2(100 / 12.5)
	}

	const float ADAPTATION_CURVE_RODS[]] .. ADAPTATION_CURVE_COUNT .. [[] = float[](]] .. ADAPTATION_CURVE_RODS_GLSL .. [[);
	const float ADAPTATION_CURVE_CONES[]] .. ADAPTATION_CURVE_COUNT .. [[] = float[](]] .. ADAPTATION_CURVE_CONES_GLSL .. [[);

	float adaptation_stops(float ev) {
		float x = clamp((ev - ]] .. string.format("%.1f", ADAPTATION_CURVE_EV_MIN) .. [[) / ]] .. string.format("%.2f", ADAPTATION_CURVE_EV_STEP) .. [[, 0.0, ]] .. string.format("%.1f", ADAPTATION_CURVE_COUNT - 1) .. [[);
		int i = min(int(x), ]] .. (
		ADAPTATION_CURVE_COUNT - 2
	) .. [[);
		float rods = mix(ADAPTATION_CURVE_RODS[i], ADAPTATION_CURVE_RODS[i + 1], x - float(i));
		float cones = mix(ADAPTATION_CURVE_CONES[i], ADAPTATION_CURVE_CONES[i + 1], x - float(i));
		return mix(cones, rods, compute.rod_adaptation);
	}

	void main() {
		uint id = gl_LocalInvocationIndex;

		for (uint i = id; i < BINS; i += 256u) bins[i] = 0u;

		// the scene was pre-exposed with last frame's exposure, the meter reads absolute luminance
		float to_absolute = 1.0 / pre_exposure_from_exposure(texture(prev_exposure_tex, vec2(0.5)).r);
		barrier();

		for (int n = int(id); n < GRID_X * GRID_Y; n += 256) {
			vec2 uv = (vec2(n % GRID_X, n / GRID_X) + 0.5) / vec2(GRID_X, GRID_Y);
			float luma = dot(textureLod(source_tex, uv, 0.0).rgb, vec3(0.2126, 0.7152, 0.0722)) * to_absolute;
			float bin = clamp((log2(max(luma, 1e-6)) - LOG_MIN) / (LOG_MAX - LOG_MIN) * float(BINS), 0.0, float(BINS - 1));
			// the centre of the view counts four times as much as the corners
			float weight = 1.0 + 3.0 * (1.0 - smoothstep(0.2, 1.0, length(uv * 2.0 - 1.0)));
			atomicAdd(bins[int(bin)], uint(weight));
		}

		barrier();

		if (id != 0u) return;

		float total = 0.0;

		for (int i = 0; i < BINS; i++) total += float(bins[i]);

		float lo = total * compute.low_percent;
		float hi = total * compute.high_percent;
		float below = 0.0;
		float log_sum = 0.0;
		float weight_sum = 0.0;

		for (int i = 0; i < BINS; i++) {
			float count = float(bins[i]);
			float take = clamp(below + count, lo, hi) - clamp(below, lo, hi);
			log_sum += take * (LOG_MIN + (float(i) + 0.5) / float(BINS) * (LOG_MAX - LOG_MIN));
			weight_sum += take;
			below += count;
		}

		float metered_ev = log2_to_ev(log_sum / max(weight_sum, 1.0));
		float ev = compute.eye != 0 ? metered_ev - adaptation_stops(metered_ev) : metered_ev;
		ev = clamp(ev - compute.compensation, compute.min_ev, compute.max_ev);

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
		{"rod_adaptation", "float"},
		{"min_ev", "float"},
		{"max_ev", "float"},
		{"low_percent", "float"},
		{"high_percent", "float"},
		{"tau_brighten", "float"},
		{"tau_darken", "float"},
	},
	write = function(self, block)
		local e = render3d.exposure
		local view = View.GetActive()
		local lock = view and view.ExposureLock or e.lock
		block.dt = get_exposure_dt()
		block.lock = lock and 1 or 0
		block.lock_ev = lock or 0
		block.compensation = view and view.ExposureCompensation or e.compensation
		block.eye = e.mode == "eye" and 1 or 0
		block.rod_adaptation = e.rod_adaptation
		block.min_ev = e.min_ev
		block.max_ev = e.max_ev
		block.low_percent = e.low_percent
		block.high_percent = e.high_percent
		block.tau_brighten = e.tau_brighten
		block.tau_darken = e.tau_darken
		return block
	end,
	shader = exposure_feedback_shader,
}

commands.Add("r_exposure_info", function()
	local texture = get_exposure_feedback_texture()
	local exposure, metered_ev, adapted_ev = texture:Download():GetPixelFloat(0, 0)
	logf(
		"[blit] %s: metered EV %.2f, adapted EV %.2f, exposure %.3g (EV %.2f)\n",
		render3d.exposure.mode,
		metered_ev,
		adapted_ev,
		exposure,
		LOG_EXPOSURE_AT_EV0 - math.log(exposure) / math.log(2)
	)
end)

-- The grid: GRID_X x GRID_Y screen tiles x GRID_Z bins of exposed log2
-- luminance from GRID_LOG_MIN to GRID_LOG_MAX stops around KEY, laid
-- out as GRID_Z slices side by side. Each cell holds (sum of log luminance,
-- count) so blurring it stays a weighted average.
local GRID_X, GRID_Y, GRID_Z = 64, 36, 16
local GRID_GLSL = (
	[[
	#define GRID_X %d
	#define GRID_Y %d
	#define GRID_Z %d
	#define GRID_LOG_MIN -10.0
	#define GRID_LOG_MAX 10.0
	// log2 of KEY, what the metered average is exposed to
	#define LOG_KEY %.7g

	// log2 of the exposed average of the frame the eye adapted to (b of the
	// exposure texture), relative to which a region is lighter or darker. In
	// mode "eye" and with a locked exposure the average isn't at KEY on purpose;
	// local exposure only evens out the differences within the frame.
	float get_frame_log_level(vec4 exposure) {
		return exposure.r > 0.0 ? exposure.b - (%.7g - log2(exposure.r)) + LOG_KEY : LOG_KEY;
	}
]]
):format(GRID_X, GRID_Y, GRID_Z, math.log(KEY) / math.log(2), LOG_EXPOSURE_AT_EV0)

local function get_pipeline_texture(name)
	return function()
		local pipeline = render3d.pipelines[name]
		return pipeline and pipeline:GetFramebuffer():GetAttachment(1) or nil
	end
end

local local_exposure_grid_pass = {
	name = "local_exposure_grid",
	ComputePass = true,
	ColorFormat = {{"r32g32_sfloat", {"grid", "rg"}}},
	FramebufferSize = {x = GRID_X * GRID_Z, y = GRID_Y},
	framebuffer_count = 1,
	-- one workgroup per tile, each invocation one sample of it
	LocalSize = {x = 16, y = 16, z = 1},
	storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
	sampled_images = {
		{
			binding_index = 1,
			get_texture = function()
				return post_source.GetSceneSourceTexture({name = "local_exposure_grid"})
			end,
		},
		{binding_index = 2, get_texture = get_exposure_feedback_texture},
		{binding_index = 3, get_texture = get_previous_exposure_texture},
	},
	block = {
		{"unused", "int"},
	},
	write = function(self, block)
		return block
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, GRID_X * 16, GRID_Y * 16, 1, desc, self.dynamic_offsets)
	end,
	shader = GRID_GLSL .. [[
		layout(set = 0, binding = 0, rg32f) uniform writeonly image2D out_grid;
		layout(set = 0, binding = 1) uniform sampler2D source_tex;
		layout(set = 0, binding = 2) uniform sampler2D exposure_tex;
		layout(set = 0, binding = 3) uniform sampler2D prev_exposure_tex;
		]] .. post_source.GetPreExposureFromExposureGLSL() .. [[

		// fixed point, since shared float atomics are an extension
		#define FIXED 256.0
		shared uint cell_sum[GRID_Z];
		shared uint cell_count[GRID_Z];

		void main() {
			uint id = gl_LocalInvocationIndex;

			if (id < uint(GRID_Z)) {
				cell_sum[id] = 0u;
				cell_count[id] = 0u;
			}

			barrier();
			ivec2 tile = ivec2(gl_WorkGroupID.xy);
			vec2 uv = (vec2(tile) + (vec2(gl_LocalInvocationID.xy) + 0.5) / 16.0) / vec2(GRID_X, GRID_Y);
			// the scene is pre-exposed with last frame's exposure
			float exposure = texture(exposure_tex, vec2(0.5)).r / pre_exposure_from_exposure(texture(prev_exposure_tex, vec2(0.5)).r);
			float luma = dot(textureLod(source_tex, uv, 0.0).rgb, vec3(0.2126, 0.7152, 0.0722)) * exposure;
			float l = clamp(log2(max(luma, 1e-6)) - get_frame_log_level(texture(exposure_tex, vec2(0.5))), GRID_LOG_MIN, GRID_LOG_MAX);
			int z = min(int((l - GRID_LOG_MIN) / (GRID_LOG_MAX - GRID_LOG_MIN) * float(GRID_Z)), GRID_Z - 1);
			atomicAdd(cell_sum[z], uint((l - GRID_LOG_MIN) * FIXED));
			atomicAdd(cell_count[z], 1u);
			barrier();

			if (id < uint(GRID_Z)) {
				float count = float(cell_count[id]);
				float sum = float(cell_sum[id]) / FIXED + GRID_LOG_MIN * count;
				imageStore(out_grid, ivec2(tile.x + int(id) * GRID_X, tile.y), vec4(sum, count, 0.0, 0.0));
			}
		}
	]],
}
-- 5x5 across the screen, 3 across luminance
local local_exposure_blur_pass = {
	name = "local_exposure_blur",
	ComputePass = true,
	ColorFormat = {{"r32g32_sfloat", {"grid", "rg"}}},
	FramebufferSize = {x = GRID_X * GRID_Z, y = GRID_Y},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
	sampled_images = {
		{binding_index = 1, get_texture = get_pipeline_texture("local_exposure_grid")},
	},
	block = {
		{"unused", "int"},
	},
	write = function(self, block)
		return block
	end,
	shader = GRID_GLSL .. [[
		layout(set = 0, binding = 0, rg32f) uniform writeonly image2D out_grid;
		layout(set = 0, binding = 1) uniform sampler2D grid_tex;

		void main() {
			ivec2 pos = ivec2(gl_GlobalInvocationID.xy);

			if (pos.x >= GRID_X * GRID_Z || pos.y >= GRID_Y) return;

			ivec3 cell = ivec3(pos.x % GRID_X, pos.y, pos.x / GRID_X);
			const float w5[5] = float[5](1.0, 4.0, 6.0, 4.0, 1.0);
			const float w3[3] = float[3](1.0, 2.0, 1.0);
			vec2 sum = vec2(0.0);

			for (int dz = -1; dz <= 1; dz++) {
				int z = cell.z + dz;

				if (z < 0 || z >= GRID_Z) continue;

				for (int dy = -2; dy <= 2; dy++) {
					for (int dx = -2; dx <= 2; dx++) {
						ivec2 xy = clamp(cell.xy + ivec2(dx, dy), ivec2(0), ivec2(GRID_X - 1, GRID_Y - 1));
						sum += texelFetch(grid_tex, ivec2(xy.x + z * GRID_X, xy.y), 0).rg * w5[dx + 2] * w5[dy + 2] * w3[dz + 1];
					}
				}
			}

			// the kernel's weights sum to 16 * 16 * 4; keep counts in samples
			imageStore(out_grid, pos, vec4(sum / 1024.0, 0.0, 0.0));
		}
	]],
}

local function get_bloom_texture()
	local pipeline = render3d.pipelines.bloom_up1
	return pipeline and pipeline:GetFramebuffer():GetAttachment(1) or nil
end

local compute_shader = [[
	layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;
	layout(set = 0, binding = 2) uniform sampler2D bloom_tex;
	layout(set = 0, binding = 4) uniform sampler2D exposure_tex;
	layout(set = 0, binding = 5) uniform sampler2D grid_tex;
	layout(set = 0, binding = 6) uniform sampler2D prev_exposure_tex;
	layout(set = 0, binding = 7) uniform sampler2D blue_noise_tex;
	]] .. post_source.GetPreExposureFromExposureGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. compute_helpers.GetColorHelpersGLSL() .. GRID_GLSL .. [[

	// average exposed log2 luminance (relative to KEY) around uv among
	// pixels about as bright as l
	float local_log_luma(vec2 uv, float l) {
		float z = clamp((l - GRID_LOG_MIN) / (GRID_LOG_MAX - GRID_LOG_MIN) * float(GRID_Z) - 0.5, 0.0, float(GRID_Z - 1));
		int z0 = int(z);
		int z1 = min(z0 + 1, GRID_Z - 1);
		// bilinear within a slice, kept off its edges so it can't read the next
		vec2 xy = clamp(uv * vec2(GRID_X, GRID_Y), vec2(0.5), vec2(GRID_X, GRID_Y) - 0.5);
		vec2 size = vec2(GRID_X * GRID_Z, GRID_Y);
		vec2 a = texture(grid_tex, (xy + vec2(z0 * GRID_X, 0.0)) / size).rg;
		vec2 b = texture(grid_tex, (xy + vec2(z1 * GRID_X, 0.0)) / size).rg;
		vec2 cell = mix(a, b, z - float(z0));
		// one sample's worth of the pixel itself, so a sparse cell leans
		// towards no adjustment smoothly instead of switching to it
		return (cell.x + l) / (cell.y + 1.0);
	}

	// For HDR output: x exposed, returns linear light in units of paper white.
	// The shadows and midtones go through the SDR tonemapper so they look the
	// same as in SDR: AgX's toe puts an exposed 0.005 at 0.0017, 1.5 stops
	// darker than leaving it alone would, and a night scene lives down there.
	// AgX crosses x at 0.335, where it hands over to x. Above the knee the
	// brightest channel rolls off smoothly to peak, and the harder a colour is
	// compressed the more it moves towards white.
	vec3 tonemap_hdr(vec3 x, float peak, int tonemapper) {
		x = max(x, vec3(0.0));
		const float knee = 0.6;
		float m = max(x.r, max(x.g, x.b));

		if (m <= knee) return mix(tonemap(x, tonemapper), x, smoothstep(0.25, 0.45, m));

		float range = peak - knee;
		float mapped = knee + range * (1.0 - exp(-(m - knee) / range));
		float compressed = 1.0 - mapped / m;
		return mix(x * (mapped / m), vec3(mapped), compressed * compressed);
	}

	// SMPTE ST 2084 (PQ) of absolute luminance
	vec3 pq_encode(vec3 nits) {
		vec3 y = pow(clamp(nits / 10000.0, 0.0, 1.0), vec3(0.1593017578125));
		return pow((0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), vec3(78.84375));
	}

	// Between ~5 and ~0.005 cd/m2 the rods take over from the cones (the mesopic range, CIE 191).
	// Rods only see once the eye has adapted to the dark (in a lit room they are saturated), and
	// only light too dim for the cones: a lamp or a traffic light keeps its colour at night. Rods have one kind of receptor, so they see no
	// colour, and they peak at 507 nm, so reds go dark and blues light up (Purkinje).
	// Their response to each primary is Larson's scotopic luminance
	// Y (1.33 (1 + (Y + Z) / X) - 1.68) at that primary, relative to white.
	const vec3 ROD_RESPONSE = vec3(0.0329, 0.7652, 0.2017);
	// what rod vision is seen as, chromaticity (0.25, 0.25) (Jensen et al. 2000)
	const vec3 ROD_TINT = vec3(0.7062, 0.9899, 1.9657);

	// Blue noise per channel, moved along the golden ratio each frame so 16
	// frames in a row see different values (as in NVIDIA's RTXGI sample)
	vec3 blue_noise(ivec2 pos) {
		ivec2 size = textureSize(blue_noise_tex, 0);
		vec3 noise = vec3(texelFetch(blue_noise_tex, pos % size, 0).rg, texelFetch(blue_noise_tex, (pos + ivec2(37, 19)) % size, 0).r);
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
		float exposure = compute.has_exposure_tex != 0 ? texture(exposure_tex, vec2(0.5)).r : exp2(]] .. LOG_EXPOSURE_AT_EV0 .. [[ - 10.0);
		// the scene is pre-exposed with last frame's exposure
		float pre_exposure = pre_exposure_from_exposure(compute.has_exposure_tex != 0 ? texture(prev_exposure_tex, vec2(0.5)).r : 0.0);
		exposure /= pre_exposure;
		// Share of vision the cones provide: all of it when the eye is adapted to
		// light (a dark corner of a lit room) or when the pixel itself is bright
		// enough for them (a lamp in a dark room). Adapted EV100 to log10 cd/m2 is
		// (ev - 3) * log10(2).
		float adapted_ev = compute.has_exposure_tex != 0 ? texture(exposure_tex, vec2(0.5)).b : 10.0;
		float pixel_log10 = log(max(dot(col, vec3(0.2126, 0.7152, 0.0722)) / pre_exposure, 1e-9)) * 0.4342945;
		float cones = smoothstep(compute.night_vision_log10_threshold - 1.5, compute.night_vision_log10_threshold + 1.5, max((adapted_ev - 3.0) * 0.30103, pixel_log10));

		// Local exposure adapts the scene; bloom is scattered light in the
		// eye, added after at the global exposure. Adapting the bloom as well
		// would lift a bright light's faint glow over a dark area into a halo.
		vec3 bloom = col;

		if (compute.has_bloom_tex != 0) {
			vec2 half_texel = 0.5 / vec2(textureSize(bloom_tex, 0));
			bloom = texture(bloom_tex, clamp(uv, half_texel, 1.0 - half_texel)).rgb;
		}

		if (compute.has_grid_tex != 0) {
			float luma = dot(col, vec3(0.2126, 0.7152, 0.0722)) * exposure;
			float l = log2(max(luma, 1e-6)) - get_frame_log_level(texture(exposure_tex, vec2(0.5)));
			float local_l = local_log_luma(uv, l);
			float stops = -local_l * (local_l > 0.0 ? compute.local_highlights : compute.local_shadows);
			col *= exp2(clamp(stops, -compute.local_max_stops, compute.local_max_stops));
		}

		// bloom keeps the scene's energy (see passes/bloom.lua), so it is
		// mixed in rather than added
		col = mix(col, bloom, compute.bloom_strength);
		col = mix(col, mix(vec3(1.0), ROD_TINT, compute.night_vision_tint) * dot(max(col, vec3(0.0)), ROD_RESPONSE), (1.0 - cones) * compute.night_vision);

		if (compute.output_mode == 0) {
			col = clamp(tonemap(col * exposure, compute.tonemapper), 0.0, 1.0);

			// 8 bit output bands in gradients; a dither of one output step hides
			// it. In the encoded (sRGB) space, where a step is the same size in
			// the shadows as in the highlights
			vec3 encoded = LinearToSRGB(col);
			encoded += (blue_noise(pos) - 0.5) / 255.0;
			col = SRGBToLinear(clamp(encoded, 0.0, 1.0));

			if (compute.requires_manual_gamma == 1) col = LinearToSRGB(col);
		} else {
			vec3 nits = tonemap_hdr(col * exposure, compute.hdr_peak / compute.hdr_paper_white, compute.tonemapper) * compute.hdr_paper_white;

			if (compute.output_mode == 1) {
				// scRGB: linear BT.709, 1.0 = 80 nits
				col = nits / 80.0;
			} else {
				// HDR10: PQ encoded BT.2020
				const mat3 bt709_to_bt2020 = mat3(
					0.6274, 0.0691, 0.0164,
					0.3293, 0.9195, 0.0880,
					0.0433, 0.0114, 0.8956
				);
				col = pq_encode(bt709_to_bt2020 * nits);
			}
		}

		imageStore(out_color, pos, vec4(col, 1.0));
	}
]]
local r = {
	exposure_feedback_pass,
	local_exposure_grid_pass,
	local_exposure_blur_pass,
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
				binding_index = 4,
				get_texture = get_exposure_feedback_texture,
			},
			{
				binding_index = 5,
				get_texture = get_pipeline_texture("local_exposure_blur"),
			},
			{
				binding_index = 6,
				get_texture = get_previous_exposure_texture,
			},
			{
				binding_index = 7,
				get_texture = function()
					return assets.GetTexture("textures/render/blue_noise.lua")
				end,
			},
		},
		block = {
			{"has_source_tex", "int"},
			{"frame", "int"},
			{"has_bloom_tex", "int"},
			{"requires_manual_gamma", "int"},
			-- 0 = SDR, 1 = scRGB, 2 = HDR10
			{"output_mode", "int"},
			{"hdr_paper_white", "float"},
			{"hdr_peak", "float"},
			{"has_exposure_tex", "int"},
			{"tonemapper", "int"},
			{"bloom_strength", "float"},
			{"night_vision", "float"},
			{"night_vision_log10_threshold", "float"},
			{"night_vision_tint", "float"},
			{"has_grid_tex", "int"},
			{"local_shadows", "float"},
			{"local_highlights", "float"},
			{"local_max_stops", "float"},
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
			block.hdr_paper_white = render3d.hdr.paper_white
			block.hdr_peak = render3d.hdr.peak
			block.tonemapper = render3d.tonemapper
			block.bloom_strength = render3d.bloom_strength
			block.night_vision = render3d.exposure.mode == "eye" and render3d.night_vision.enabled and 1 or 0
			block.night_vision_log10_threshold = math.log(render3d.night_vision.threshold) / math.log(10)
			block.night_vision_tint = render3d.night_vision.tint
			block.has_grid_tex = get_pipeline_texture("local_exposure_blur")() and 1 or 0
			local view = View.GetActive()
			local local_exposure = view and view.LocalExposure
			block.local_shadows = local_exposure or render3d.local_exposure.shadows
			block.local_highlights = local_exposure or render3d.local_exposure.highlights
			block.local_max_stops = render3d.local_exposure.max_stops
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
}
return r
