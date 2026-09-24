local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local View = import("goluwa/render3d/view.lua")
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
-- The eye doesn't fully adapt: a night street stays dark and noon stays
-- bright. ADAPTATION is how much of the metered EV's distance from REFERENCE_EV
-- is compensated for, 1 for a camera's full auto exposure.
render3d.exposure = {
	lock = nil,
	compensation = 0,
	adaptation = 0.85,
	reference_ev = 9,
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

commands.Add("r_exposure_lock=number|nil", function(ev)
	render3d.exposure.lock = ev
	logf("[blit] exposure %s\n", ev and ("locked at EV " .. ev) or "auto")
end)

commands.Add("r_exposure_compensation=number[0]", function(stops)
	render3d.exposure.compensation = stops
end)

commands.Add("r_exposure_adaptation=number[0.85]", function(value)
	render3d.exposure.adaptation = value
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

-- r = exposure multiplier, g = the metered EV100 before adaptation and
-- compensation (for r_exposure_info)
local exposure_feedback_shader = [[
	layout(set = 0, binding = 0, rg32f) uniform writeonly image2D out_exposure;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;
	layout(set = 0, binding = 2) uniform sampler2D prev_exposure_tex;

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

	void main() {
		uint id = gl_LocalInvocationIndex;

		for (uint i = id; i < BINS; i += 256u) bins[i] = 0u;

		barrier();

		for (int n = int(id); n < GRID_X * GRID_Y; n += 256) {
			vec2 uv = (vec2(n % GRID_X, n / GRID_X) + 0.5) / vec2(GRID_X, GRID_Y);
			float luma = dot(textureLod(source_tex, uv, 0.0).rgb, vec3(0.2126, 0.7152, 0.0722));
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
		float ev = compute.reference_ev + (metered_ev - compute.reference_ev) * compute.adaptation;
		ev = clamp(ev - compute.compensation, compute.min_ev, compute.max_ev);

		if (compute.lock != 0) ev = compute.lock_ev - compute.compensation;

		float log_target = ]] .. LOG_EXPOSURE_AT_EV0 .. [[ - ev;
		float prev = texture(prev_exposure_tex, vec2(0.5)).r;

		if (!(prev > 0.0) || compute.lock != 0) prev = exp2(log_target);

		float log_prev = log2(prev);
		float tau = log_target > log_prev ? compute.tau_darken : compute.tau_brighten;
		float k = 1.0 - exp(-compute.dt / tau);
		imageStore(out_exposure, ivec2(0, 0), vec4(exp2(log_prev + (log_target - log_prev) * k), metered_ev, 0.0, 1.0));
	}
]]
local exposure_feedback_pass = {
	name = "exposure_feedback",
	ComputePass = true,
	ColorFormat = {
		{"r32g32_sfloat", {"exposure", "rg"}},
		{"r32g32_sfloat", {"exposure_prev", "rg"}},
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
		{"adaptation", "float"},
		{"reference_ev", "float"},
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
		block.adaptation = e.adaptation
		block.reference_ev = e.reference_ev
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
	local exposure, metered_ev = texture:Download():GetPixelFloat(0, 0)
	logf(
		"[blit] metered EV %.2f, exposure %.3g (EV %.2f)\n",
		metered_ev,
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
]]
):format(GRID_X, GRID_Y, GRID_Z, math.log(KEY) / math.log(2))

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
			float exposure = texture(exposure_tex, vec2(0.5)).r;
			float luma = dot(textureLod(source_tex, uv, 0.0).rgb, vec3(0.2126, 0.7152, 0.0722)) * exposure;
			float l = clamp(log2(max(luma, 1e-6)) - LOG_KEY, GRID_LOG_MIN, GRID_LOG_MAX);
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
	]] .. compute_helpers.GetScreenHelpersGLSL() .. compute_helpers.GetColorHelpersGLSL() .. GRID_GLSL .. [[

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
	// Up to the knee it is left alone, which is about where SDR AgX puts the
	// same values; above it the brightest channel rolls off smoothly to peak,
	// and the harder a colour is compressed the more it moves towards white.
	vec3 tonemap_hdr(vec3 x, float peak) {
		x = max(x, vec3(0.0));
		const float knee = 0.6;
		float m = max(x.r, max(x.g, x.b));

		if (m <= knee) return x;

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

	float interleaved_gradient_noise(vec2 p) {
		return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
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
			float l = log2(max(luma, 1e-6)) - LOG_KEY;
			float local_l = local_log_luma(uv, l);
			float stops = -local_l * (local_l > 0.0 ? compute.local_highlights : compute.local_shadows);
			col *= exp2(clamp(stops, -compute.local_max_stops, compute.local_max_stops));
		}

		// bloom keeps the scene's energy (see passes/bloom.lua), so it is
		// mixed in rather than added
		col = mix(col, bloom, compute.bloom_strength);

		if (compute.output_mode == 0) {
			col = clamp(tonemap(col * exposure, compute.tonemapper), 0.0, 1.0);

			// 8 bit output bands in dark gradients; triangular dither of one
			// output step in the encoded (sRGB) space hides it
			vec3 encoded = LinearToSRGB(col);
			encoded += (interleaved_gradient_noise(vec2(pos)) + interleaved_gradient_noise(vec2(pos) + vec2(47.0, 17.0)) - 1.0) / 255.0;
			col = SRGBToLinear(clamp(encoded, 0.0, 1.0));

			if (compute.requires_manual_gamma == 1) col = LinearToSRGB(col);
		} else {
			vec3 nits = tonemap_hdr(col * exposure, compute.hdr_peak / compute.hdr_paper_white) * compute.hdr_paper_white;

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
		},
		block = {
			{"has_source_tex", "int"},
			{"has_bloom_tex", "int"},
			{"requires_manual_gamma", "int"},
			-- 0 = SDR, 1 = scRGB, 2 = HDR10
			{"output_mode", "int"},
			{"hdr_paper_white", "float"},
			{"hdr_peak", "float"},
			{"has_exposure_tex", "int"},
			{"tonemapper", "int"},
			{"bloom_strength", "float"},
			{"has_grid_tex", "int"},
			{"local_shadows", "float"},
			{"local_highlights", "float"},
			{"local_max_stops", "float"},
		},
		write = function(self, block)
			block.has_source_tex = get_scene_source_texture() and 1 or 0
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

if HOTRELOAD then
	import("goluwa/timer.lua").Delay(0, function()
		render3d.Initialize()
	end)
end

return r
