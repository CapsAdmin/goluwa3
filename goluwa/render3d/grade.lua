local ffi = require("ffi")
local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local vfs = import("goluwa/vfs.lua")
local lut_codec = import("goluwa/codecs/lut.lua")
local curve = import("goluwa/math/curve.lua")
local system = import("goluwa/system.lua")
local grade = {}
grade.BLEND_TIME = 2
pvars.StartGroup("Post", "Grade", {store = false, prefix = "grade_"})
local brightness = pvars.Setup2{
	key = "r_grade_brightness",
	default = 0,
	min = -100,
	max = 100,
	help = "brightens or darkens the midtones of the tonemapped image, black and white stay. Grading after the tonemapper works on what the display shows",
}
local contrast = pvars.Setup2{
	key = "r_grade_contrast",
	default = 0,
	min = -100,
	max = 100,
	help = "an S curve around the pivot, black and white stay, below 0 it flattens",
}
local contrast_pivot = pvars.Setup2{
	key = "r_grade_contrast_pivot",
	default = 0.5,
	min = 0.01,
	max = 0.99,
	help = "the display value contrast turns around, it stays where it is. 0.5 is about 21% grey, lower keeps the shadows and spreads the highlights, higher the other way",
}
local saturation = pvars.Setup2{
	key = "r_grade_saturation",
	default = 0,
	min = -100,
	max = 100,
	help = "colourfulness, -100 is grey and 100 twice the colour",
}
local warmth = pvars.Setup2{
	key = "r_grade_warmth",
	default = 0,
	min = -100,
	max = 100,
	help = "warms (above 0, orange) or cools (below 0, blue) the image",
}
pvars.EndGroup()
pvars.StartGroup("Post", "Tone curve", {store = false, prefix = "grade_"})
local curve_help = "points of a tone curve on the tonemapped image as \"x y, x y, ...\" in sRGB encoded display values where 1 is white (paper white on HDR outputs, which go on above it up to the display's peak). Between points it is a smooth curve that never overshoots, past the first and last point it goes on one to one. Empty is no change"
local curves = {
	pvars.Setup2{
		key = "r_grade_curve",
		default = "",
		help = curve_help .. ". Applied to all three channels, before the per channel curves",
	},
	pvars.Setup2{key = "r_grade_curve_r", default = "", help = curve_help .. ". Red only"},
	pvars.Setup2{key = "r_grade_curve_g", default = "", help = curve_help .. ". Green only"},
	pvars.Setup2{key = "r_grade_curve_b", default = "", help = curve_help .. ". Blue only"},
}
pvars.EndGroup()
pvars.StartGroup("Post", "Look LUT", {store = false, prefix = "grade_"})
local lut_path = pvars.Setup2{
	key = "r_grade_lut",
	default = "",
	help = "vfs or absolute path of a .cube, .dat (with a 3DLUTSIZE header) or strip .png look up table applied to the tonemapped image, empty for none. Every luts/ folder of an addon is searched by the Look window",
}
local lut_strength = pvars.Setup2{
	key = "r_grade_lut_strength",
	default = 100,
	help = "how much of the look up table is applied, 0 is the plain image and 100 the table as it is",
}
local lut_spaces = {srgb = 0, gamma24 = 1, linear = 2}
local lut_space = pvars.Setup2{
	key = "r_grade_lut_space",
	default = "srgb",
	enums = {"srgb", "gamma24", "linear"},
	help = "the encoding the table reads and writes: srgb, a plain 2.4 gamma (what Resolve film looks output) or linear light. With a slog3 or logc tonemapper the table reads the camera log and this is only how it writes: Rec709 camera tables write BT.709 video, srgb shows it lighter and gamma24 darker and contrastier like a video monitor",
}
local lut_order = pvars.Setup2{
	key = "r_grade_lut_order",
	default = "after",
	enums = {"after", "before"},
	help = "whether the table runs after the grade controls (they adjust what goes in) or before them (they trim the finished look)",
}
pvars.EndGroup()
grade.block = {
	{"grade_on", "int"},
	{"grade_brightness", "float"},
	{"grade_contrast", "float"},
	{"grade_contrast_pivot", "float"},
	{"grade_curve", "int"},
	{"histogram", "int"},
	{"histogram_range", "float"},
	{"grade_saturation", "float"},
	{"grade_warmth", "float"},
	{"lut_mode", "int"},
	{"lut_strength", "float"},
	{"lut_size_3d", "int"},
	{"lut_size_1d", "int"},
	{"lut_domain_min", "float"},
	{"lut_domain_max", "float"},
	{"lut_shaper_min", "float"},
	{"lut_shaper_max", "float"},
}
local lut_state = {path = ""}

function grade.LoadLut(path)
	return lut_codec.Decode(path, assert(vfs.Read(path)))
end

local LUT_DIRECTORY = "luts/"

function grade.FindLuts()
	local paths = {}
	local seen = {}

	vfs.FindRecursive(
		LUT_DIRECTORY,
		function(path)
			if not seen[path] then
				seen[path] = true
				paths[#paths + 1] = path
			end
		end,
		{"cube", "dat", "png"}
	)

	table.sort(paths, function(a, b)
		return a:lower() < b:lower()
	end)

	return paths
end

local function update_lut()
	local path = lut_path:Get()

	if path == lut_state.path then return end

	if lut_state.texture_3d then lut_state.texture_3d:Remove() end

	if lut_state.texture_1d then lut_state.texture_1d:Remove() end

	lut_state = {path = path}

	if path == "" then return end

	local ok, lut = pcall(grade.LoadLut, path)

	if ok then lut_state.lut = lut else wlog("grade lut %s: %s", path, lut) end
end

local LUT_SAMPLER = {
	min_filter = "nearest",
	mag_filter = "nearest",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
}

-- the 3d table as a strip of slices (x = blue * size + red, y = green) and the shaper as a row, both read with texelFetch
function grade.GetLutTexture3D()
	update_lut()
	local lut = lut_state.lut

	if not lut or not lut.size then return nil end

	if not lut_state.texture_3d then
		local Texture = import("goluwa/render/texture.lua")
		local size = lut.size
		local width = size * size
		local pixels = ffi.new("float[?]", width * size * 4)

		for blue = 0, size - 1 do
			for green = 0, size - 1 do
				for red = 0, size - 1 do
					local from = (red + green * size + blue * size * size) * 3
					local to = (green * width + blue * size + red) * 4
					pixels[to] = lut.data[from]
					pixels[to + 1] = lut.data[from + 1]
					pixels[to + 2] = lut.data[from + 2]
					pixels[to + 3] = 1
				end
			end
		end

		lut_state.texture_3d = Texture.New{
			buffer = pixels,
			width = width,
			height = size,
			format = "r32g32b32a32_sfloat",
			sampler = LUT_SAMPLER,
		}
	end

	return lut_state.texture_3d
end

function grade.GetLutTexture1D()
	update_lut()
	local lut = lut_state.lut

	if not lut or not lut.shaper_size then return nil end

	if not lut_state.texture_1d then
		local Texture = import("goluwa/render/texture.lua")
		local size = lut.shaper_size
		local pixels = ffi.new("float[?]", size * 4)

		for i = 0, size - 1 do
			pixels[i * 4] = lut.shaper[i * 3]
			pixels[i * 4 + 1] = lut.shaper[i * 3 + 1]
			pixels[i * 4 + 2] = lut.shaper[i * 3 + 2]
			pixels[i * 4 + 3] = 1
		end

		lut_state.texture_1d = Texture.New{
			buffer = pixels,
			width = size,
			height = 1,
			format = "r32g32b32a32_sfloat",
			sampler = LUT_SAMPLER,
		}
	end

	return lut_state.texture_1d
end

grade.CURVE_SIZE = 4096
grade.CURVE_RANGE = 8

function grade.ParseCurve(text)
	local points = {}

	for x, y in text:gmatch("([^%s,]+)%s+([^%s,]+)") do
		points[#points + 1] = {assert(tonumber(x), text), assert(tonumber(y), text)}
	end

	for i = 2, #points do
		assert(points[i][1] > points[i - 1][1], "tone curve points must have increasing x: " .. text)
	end

	return points
end

function grade.FormatCurve(points)
	local parts = {}

	for i, point in ipairs(points) do
		parts[i] = string.format("%.4g %.4g", point[1], point[2])
	end

	return table.concat(parts, ", ")
end

function grade.CompileCurve(text)
	if text == "" then return nil end

	local points = grade.ParseCurve(text)

	if not points[1] then return nil end

	return {points = points, tangents = curve.MonotoneTangents(points)}
end

function grade.EvaluateCurve(compiled, x)
	if not compiled then return x end

	return curve.EvaluateMonotone(compiled.points, compiled.tangents, x, 1)
end

function grade.GetCurveDisplayRange()
	local render = import("goluwa/render/render.lua")

	if not render.target or not render.target:IsHDR() then return 1 end

	local peak = pvars.Get("r_hdr_peak") / pvars.Get("r_hdr_paper_white")
	return peak <= 0.0031308 and peak * 12.92 or 1.055 * peak ^ (1 / 2.4) - 0.055
end

local curve_state = {key = ""}

function grade.GetCurveTexture()
	local key = curves[1]:Get() .. "|" .. curves[2]:Get() .. "|" .. curves[3]:Get() .. "|" .. curves[4]:Get()

	if key == curve_state.key then return curve_state.texture end

	if curve_state.texture then curve_state.texture:Remove() end

	curve_state = {key = key}

	if key == "|||" then return nil end

	local ok, compiled = pcall(function()
		return {
			grade.CompileCurve(curves[1]:Get()),
			grade.CompileCurve(curves[2]:Get()),
			grade.CompileCurve(curves[3]:Get()),
			grade.CompileCurve(curves[4]:Get()),
		}
	end)

	if not ok then
		wlog("grade curve: %s", compiled)
		return nil
	end

	local size = grade.CURVE_SIZE
	local pixels = ffi.new("float[?]", size * 4)

	for i = 0, size - 1 do
		local x = grade.EvaluateCurve(compiled[1], i / (size - 1) * grade.CURVE_RANGE)
		pixels[i * 4] = grade.EvaluateCurve(compiled[2], x)
		pixels[i * 4 + 1] = grade.EvaluateCurve(compiled[3], x)
		pixels[i * 4 + 2] = grade.EvaluateCurve(compiled[4], x)
		pixels[i * 4 + 3] = 1
	end

	local Texture = import("goluwa/render/texture.lua")
	curve_state.texture = Texture.New{
		buffer = pixels,
		width = size,
		height = 1,
		format = "r32g32b32a32_sfloat",
		sampler = LUT_SAMPLER,
	}
	return curve_state.texture
end

grade.HISTOGRAM_BINS = 256
grade.HISTOGRAM_STRIDE = 4
grade.HISTOGRAM_LINGER = 0.5

do
	local HistogramPointer = ffi.typeof("uint32_t*")
	local byte_size = grade.HISTOGRAM_BINS * 4 * 4
	local buffers = {}
	local requested = -math.huge
	local histogram

	function grade.IsHistogramActive()
		return system.GetElapsedTime() - requested < grade.HISTOGRAM_LINGER
	end

	function grade.GetHistogram()
		requested = system.GetElapsedTime()
		return histogram
	end

	function grade.GetHistogramBuffer()
		local render = import("goluwa/render/render.lua")
		local slot = (
				(
					render.GetCurrentFrame() or
					1
				) - 1
			) % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
		local buffer = buffers[slot]

		if not buffer then
			buffer = render.CreateBuffer{
				byte_size = byte_size,
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = "grade_histogram",
				data = ffi.new("uint8_t[?]", byte_size),
			}
			buffers[slot] = buffer
			return buffer
		end

		if not grade.IsHistogramActive() then
			histogram = nil
			return buffer
		end

		local counts = ffi.cast(HistogramPointer, buffer:Map(0, byte_size))
		local bins = grade.HISTOGRAM_BINS
		local total = 0

		for i = 0, bins - 1 do
			total = total + counts[3 * bins + i]
		end

		if total > 0 then
			histogram = histogram or {r = {}, g = {}, b = {}, luma = {}}
			histogram.range = grade.GetCurveDisplayRange()

			for channel, name in ipairs{"r", "g", "b", "luma"} do
				local values = histogram[name]
				local offset = (channel - 1) * bins

				for i = 0, bins - 1 do
					values[i + 1] = counts[offset + i] / total
				end
			end
		end

		ffi.fill(counts, byte_size)
		return buffer
	end
end

function grade.WriteBlock(block)
	update_lut()
	block.grade_brightness = brightness:Get() / 100
	block.grade_contrast = contrast:Get() / 100
	block.grade_contrast_pivot = contrast_pivot:Get()
	block.grade_saturation = saturation:Get() / 100
	block.grade_warmth = warmth:Get() / 100
	block.grade_on = (
			block.grade_brightness ~= 0 or
			block.grade_contrast ~= 0 or
			block.grade_saturation ~= 0 or
			block.grade_warmth ~= 0
		)
		and
		1 or
		0
	block.grade_curve = grade.GetCurveTexture() and 1 or 0
	block.histogram = grade.IsHistogramActive() and 1 or 0
	block.histogram_range = grade.GetCurveDisplayRange()
	local lut = lut_state.lut
	local strength = lut_strength:Get() / 100
	block.lut_strength = strength
	block.lut_mode = lut and
		bit.bor(
			16,
			strength ~= 0 and 1 or 0,
			lut_order:Get() == "before" and 2 or 0,
			bit.lshift(lut_spaces[lut_space:Get()], 2)
		) or
		0
	block.lut_size_3d = lut and lut.size or 0
	block.lut_size_1d = lut and lut.shaper_size or 0

	if lut then
		block.lut_domain_min = lut.domain_min
		block.lut_domain_max = lut.domain_max
		block.lut_shaper_min = lut.shaper_min
		block.lut_shaper_max = lut.shaper_max
	end

	return block
end

local LUT_GLSL = [[
	layout(set = 0, binding = %d) uniform sampler2D grade_lut_3d_tex;
	layout(set = 0, binding = %d) uniform sampler2D grade_lut_1d_tex;

	vec3 grade_lut_shaper(vec3 v) {
		int last = BLOCK.lut_size_1d - 1;
		vec3 f = clamp((v - BLOCK.lut_shaper_min) / (BLOCK.lut_shaper_max - BLOCK.lut_shaper_min), 0.0, 1.0) * float(last);
		ivec3 i0 = ivec3(floor(f));
		ivec3 i1 = min(i0 + 1, ivec3(last));
		vec3 w = f - vec3(i0);
		return vec3(
			mix(texelFetch(grade_lut_1d_tex, ivec2(i0.x, 0), 0).r, texelFetch(grade_lut_1d_tex, ivec2(i1.x, 0), 0).r, w.x),
			mix(texelFetch(grade_lut_1d_tex, ivec2(i0.y, 0), 0).g, texelFetch(grade_lut_1d_tex, ivec2(i1.y, 0), 0).g, w.y),
			mix(texelFetch(grade_lut_1d_tex, ivec2(i0.z, 0), 0).b, texelFetch(grade_lut_1d_tex, ivec2(i1.z, 0), 0).b, w.z)
		);
	}

	vec3 grade_lut_cube(vec3 v) {
		int size = BLOCK.lut_size_3d;
		vec3 f = clamp((v - BLOCK.lut_domain_min) / (BLOCK.lut_domain_max - BLOCK.lut_domain_min), 0.0, 1.0) * float(size - 1);
		ivec3 i0 = ivec3(floor(f));
		ivec3 i1 = min(i0 + 1, ivec3(size - 1));
		vec3 w = f - vec3(i0);
		vec3 c000 = texelFetch(grade_lut_3d_tex, ivec2(i0.b * size + i0.r, i0.g), 0).rgb;
		vec3 c100 = texelFetch(grade_lut_3d_tex, ivec2(i0.b * size + i1.r, i0.g), 0).rgb;
		vec3 c010 = texelFetch(grade_lut_3d_tex, ivec2(i0.b * size + i0.r, i1.g), 0).rgb;
		vec3 c110 = texelFetch(grade_lut_3d_tex, ivec2(i0.b * size + i1.r, i1.g), 0).rgb;
		vec3 c001 = texelFetch(grade_lut_3d_tex, ivec2(i1.b * size + i0.r, i0.g), 0).rgb;
		vec3 c101 = texelFetch(grade_lut_3d_tex, ivec2(i1.b * size + i1.r, i0.g), 0).rgb;
		vec3 c011 = texelFetch(grade_lut_3d_tex, ivec2(i1.b * size + i0.r, i1.g), 0).rgb;
		vec3 c111 = texelFetch(grade_lut_3d_tex, ivec2(i1.b * size + i1.r, i1.g), 0).rgb;

		if (w.r > w.g) {
			if (w.g > w.b) return c000 + (c100 - c000) * w.r + (c110 - c100) * w.g + (c111 - c110) * w.b;

			if (w.r > w.b) return c000 + (c100 - c000) * w.r + (c101 - c100) * w.b + (c111 - c101) * w.g;

			return c000 + (c001 - c000) * w.b + (c101 - c001) * w.r + (c111 - c101) * w.g;
		}

		if (w.r > w.b) return c000 + (c010 - c000) * w.g + (c110 - c010) * w.r + (c111 - c110) * w.b;

		if (w.g > w.b) return c000 + (c010 - c000) * w.g + (c011 - c010) * w.b + (c111 - c011) * w.r;

		return c000 + (c001 - c000) * w.b + (c011 - c001) * w.g + (c111 - c011) * w.r;
	}

	vec3 grade_lut(vec3 x) {
		vec3 v = x;

		int space = (BLOCK.lut_mode >> 2) & 3;

		if (space == 1) v = pow(SRGBToLinear(x), vec3(1.0 / 2.4));
		else if (space == 2) v = SRGBToLinear(x);

		if (BLOCK.lut_size_1d > 0) v = grade_lut_shaper(v);

		if (BLOCK.lut_size_3d > 0) v = grade_lut_cube(v);

		v = clamp(v, 0.0, 1.0);
		vec3 y = v;

		if (space == 1) y = LinearToSRGB(pow(v, vec3(2.4)));
		else if (space == 2) y = LinearToSRGB(v);

		return mix(x, y, BLOCK.lut_strength);
	}

	vec3 grade_lut_log(vec3 v, vec3 plain) {
		if (BLOCK.lut_size_1d > 0) v = grade_lut_shaper(v);

		if (BLOCK.lut_size_3d > 0) v = grade_lut_cube(v);

		vec3 y = clamp(v, 0.0, 1.0);
		int space = (BLOCK.lut_mode >> 2) & 3;

		if (space == 1) y = LinearToSRGB(pow(y, vec3(2.4)));
		else if (space == 2) y = LinearToSRGB(y);

		return mix(plain, y, BLOCK.lut_strength);
	}
]]
local LUT_STUB = [[
	vec3 grade_lut(vec3 x) {
		return x;
	}

	vec3 grade_lut_log(vec3 v, vec3 plain) {
		return plain;
	}
]]
local CURVE_GLSL = [[
	layout(set = 0, binding = %d) uniform sampler2D grade_curve_tex;

	vec3 grade_curve(vec3 x) {
		if (BLOCK.grade_curve == 0) return x;

		int last = %d;
		vec3 f = clamp(x / %s, 0.0, 1.0) * float(last);
		ivec3 i0 = ivec3(floor(f));
		ivec3 i1 = min(i0 + 1, ivec3(last));
		vec3 w = f - vec3(i0);
		return vec3(
			mix(texelFetch(grade_curve_tex, ivec2(i0.x, 0), 0).r, texelFetch(grade_curve_tex, ivec2(i1.x, 0), 0).r, w.x),
			mix(texelFetch(grade_curve_tex, ivec2(i0.y, 0), 0).g, texelFetch(grade_curve_tex, ivec2(i1.y, 0), 0).g, w.y),
			mix(texelFetch(grade_curve_tex, ivec2(i0.z, 0), 0).b, texelFetch(grade_curve_tex, ivec2(i1.z, 0), 0).b, w.z)
		) + max(x - %s, 0.0);
	}
]]
local HISTOGRAM_GLSL = [[
	#define GRADE_HISTOGRAM_BINS %d
	#define GRADE_HISTOGRAM_STRIDE %du

	layout(std430, set = 0, binding = %d) buffer GradeHistogram {
		uint grade_histogram_bins[];
	};

	vec3 grade_histogram(vec3 x) {
		if (BLOCK.histogram == 0 || any(notEqual(gl_GlobalInvocationID.xy %% GRADE_HISTOGRAM_STRIDE, uvec2(0)))) return x;

		vec4 v = vec4(x, dot(x, vec3(0.2126, 0.7152, 0.0722)));
		ivec4 bin = ivec4(0, 1, 2, 3) * GRADE_HISTOGRAM_BINS + clamp(ivec4(v / BLOCK.histogram_range * float(GRADE_HISTOGRAM_BINS)), 0, GRADE_HISTOGRAM_BINS - 1);
		atomicAdd(grade_histogram_bins[bin.r], 1u);
		atomicAdd(grade_histogram_bins[bin.g], 1u);
		atomicAdd(grade_histogram_bins[bin.b], 1u);
		atomicAdd(grade_histogram_bins[bin.a], 1u);
		return x;
	}
]]
local HISTOGRAM_STUB = [[
	vec3 grade_histogram(vec3 x) {
		return x;
	}
]]
local CURVE_STUB = [[
	vec3 grade_curve(vec3 x) {
		return x;
	}
]]

function grade.GetGLSL(block_name, binding_3d, binding_1d, binding_curve, binding_histogram)
	local lut = binding_3d and LUT_GLSL:format(binding_3d, binding_1d) or LUT_STUB
	local range = string.format("%.1f", grade.CURVE_RANGE)
	lut = lut .. (
			binding_curve and
			CURVE_GLSL:format(binding_curve, grade.CURVE_SIZE - 1, range, range) or
			CURVE_STUB
		) .. (
			binding_histogram and
			HISTOGRAM_GLSL:format(grade.HISTOGRAM_BINS, grade.HISTOGRAM_STRIDE, binding_histogram) or
			HISTOGRAM_STUB
		)
	return (
		(
			lut .. [[
		vec3 grade_controls(vec3 x) {
			if (BLOCK.grade_on == 0) return x;

			if (BLOCK.grade_brightness != 0.0) x = pow(max(x, vec3(0.0)), vec3(exp2(-0.8 * BLOCK.grade_brightness)));

			if (BLOCK.grade_contrast != 0.0) {
				float p = exp2(0.75 * BLOCK.grade_contrast);
				float to_pivot = -1.0 / log2(BLOCK.grade_contrast_pivot);
				vec3 t = pow(max(x, vec3(0.0)), vec3(to_pivot));
				vec3 a = pow(t, vec3(p));
				vec3 b = pow(1.0 - t, vec3(p));
				x = pow(a / (a + b), vec3(1.0 / to_pivot));
			}

			float saturation = max(1.0 + BLOCK.grade_saturation, 0.0);
			x = mix(vec3(dot(x, vec3(0.2126, 0.7152, 0.0722))), x, saturation);
			return x * vec3(1.0 + 0.15 * BLOCK.grade_warmth, 1.0, 1.0 - 0.15 * BLOCK.grade_warmth);
		}

		vec3 grade_encoded(vec3 x) {
			if ((BLOCK.lut_mode & 3) == 3) x = grade_lut(x);

			x = grade_controls(x);

			if ((BLOCK.lut_mode & 3) == 1) x = grade_lut(x);

			return x;
		}

		vec3 grade_display(vec3 c) {
			if (BLOCK.grade_on == 0 && BLOCK.grade_curve == 0 && BLOCK.histogram == 0 && (BLOCK.lut_mode & 1) == 0) return c;

			vec3 x = clamp(grade_curve(grade_histogram(LinearToSRGB(clamp(c, 0.0, 1.0)))), 0.0, 1.0);
			return SRGBToLinear(clamp(grade_encoded(x), 0.0, 1.0));
		}

		vec3 grade_display_log(vec3 encoded, vec3 plain) {
			vec3 x = clamp(encoded, 0.0, 1.0);

			if ((BLOCK.lut_mode & 16) != 0) x = LinearToSRGB(plain);

			if ((BLOCK.lut_mode & 1) != 0) x = grade_lut_log(encoded, x);

			x = clamp(grade_curve(grade_histogram(x)), 0.0, 1.0);
			return SRGBToLinear(clamp(grade_controls(x), 0.0, 1.0));
		}

		vec3 grade_display_hdr(vec3 c) {
			if (BLOCK.grade_curve != 0 || BLOCK.histogram != 0) c = SRGBToLinear(max(grade_curve(grade_histogram(LinearToSRGB(max(c, vec3(0.0))))), vec3(0.0)));

			if (BLOCK.grade_on == 0 && (BLOCK.lut_mode & 1) == 0) return c;

			vec3 sdr = min(c, vec3(1.0));
			return SRGBToLinear(clamp(grade_encoded(LinearToSRGB(sdr)), 0.0, 1.0)) + (c - sdr);
		}
	]]
		):gsub("BLOCK", block_name)
	)
end

local fields = {
	{key = "r_grade_brightness"},
	{key = "r_grade_contrast"},
	{key = "r_grade_contrast_pivot"},
	{key = "r_grade_saturation"},
	{key = "r_grade_warmth"},
	{key = "r_grade_curve", curve = true},
	{key = "r_grade_curve_r", curve = true},
	{key = "r_grade_curve_g", curve = true},
	{key = "r_grade_curve_b", curve = true},
	{key = "camera.white_balance", exposure = true, white_balance = true},
	{key = "camera.white_balance_tint", exposure = true},
	{key = "r_tonemapper"},
	{key = "r_bloom_strength"},
	{key = "r_bloom_threshold"},
	{key = "r_bloom_floor"},
}
grade.fields = fields
local field_keys = {}

for _, field in ipairs(fields) do
	field_keys[field.key] = true
end

grade.presets = {
	neutral = {},
	warm = {
		["camera.white_balance"] = 7500,
		r_grade_saturation = 5,
	},
	cool = {
		["camera.white_balance"] = 5200,
		r_grade_saturation = -5,
	},
	muted = {
		r_grade_saturation = -40,
		r_grade_contrast = 10,
	},
	soft = {
		r_grade_contrast = -10,
		r_grade_warmth = 10,
	},
}
grade.blend_time = 0
grade.blend_elapsed = 0

function grade.GetValue(field)
	if field.exposure then return exposure_model.Get(field.key) end

	return pvars.Get(field.key)
end

function grade.SetValue(field, value)
	if field.exposure then
		exposure_model.Set(field.key, value)
	else
		pvars.SetSession(field.key, value)
	end
end

function grade.GetInfo(field)
	if field.exposure then return exposure_model.fields[field.key] end

	return pvars.GetObject(field.key):GetInfo()
end

local function get_default(field)
	if field.exposure then return exposure_model.GetDefault(field.key) end

	return pvars.GetObject(field.key):GetDefault()
end

local function get_state()
	local state = {}

	for _, field in ipairs(fields) do
		state[field.key] = grade.GetValue(field)
	end

	return state
end

local function resolve(preset)
	if type(preset) == "string" then
		preset = grade.presets[preset] or error("unknown grade preset " .. preset, 3)
	end

	for key in pairs(preset) do
		if not field_keys[key] then error("unknown grade field " .. tostring(key), 3) end
	end

	local state = {}

	for _, field in ipairs(fields) do
		local value = preset[field.key]

		if value == nil then value = get_default(field) end

		state[field.key] = value
	end

	return state
end

function grade.BlendCurves(from, to, t)
	if from == to then return from end

	if t <= 0 then return from end

	if t >= 1 then return to end

	local a, b = grade.CompileCurve(from), grade.CompileCurve(to)
	local xs = {}

	for _, compiled in ipairs{a or {points = {{0, 0}, {1, 1}}}, b or {points = {{0, 0}, {1, 1}}}} do
		for _, point in ipairs(compiled.points) do
			xs[#xs + 1] = point[1]
		end
	end

	table.sort(xs)
	local points = {}

	for _, x in ipairs(xs) do
		if not points[1] or x > points[#points][1] then
			points[#points + 1] = {x, math.lerp(t, grade.EvaluateCurve(a, x), grade.EvaluateCurve(b, x))}
		end
	end

	return grade.FormatCurve(points)
end

local function apply(a, b, t)
	for _, field in ipairs(fields) do
		local from, to = a[field.key], b[field.key]
		local value

		if field.curve then
			value = grade.BlendCurves(from, to, t)
		elseif type(from) ~= "number" then
			value = t < 0.5 and from or to
		elseif field.white_balance then
			if from == 0 or to == 0 then
				value = t < 1 and from or to
			else
				value = 1e6 / math.lerp(t, 1e6 / from, 1e6 / to)
			end
		else
			value = math.lerp(t, from, to)
		end

		if value ~= grade.GetValue(field) then grade.SetValue(field, value) end
	end
end

local function update(dt)
	grade.blend_elapsed = grade.blend_elapsed + dt
	local t = grade.blend_time > 0 and math.min(grade.blend_elapsed / grade.blend_time, 1) or 1
	apply(grade.from, grade.to, math.smoothstep(0, 1, t))

	if t >= 1 then
		grade.from = nil
		grade.to = nil
		event.RemoveListener("Update", "grade")
	end
end

function grade.SetPreset(preset, seconds)
	grade.preset = preset
	grade.from = get_state()
	grade.to = resolve(preset)
	grade.blend_time = seconds or grade.BLEND_TIME
	grade.blend_elapsed = 0

	if grade.blend_time <= 0 then
		update(0)
	else
		event.AddListener("Update", "grade", update)
	end
end

function grade.GetPreset()
	return grade.preset
end

function grade.IsBlending()
	return grade.from ~= nil
end

function grade.Stop()
	grade.preset = nil
	grade.from = nil
	grade.to = nil
	event.RemoveListener("Update", "grade")
end

function grade.Blend(a, b, t)
	grade.Stop()
	apply(resolve(a), resolve(b), t)
end

commands.Add("grade=string", function(name)
	grade.SetPreset(name)
end)

return grade
