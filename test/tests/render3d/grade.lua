local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local grade = import("goluwa/render3d/grade.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local pvars = import("goluwa/cli/pvars.lua")
import("goluwa/render3d/exposure.lua")
import("goluwa/render3d/passes/bloom.lua")
import("goluwa/render3d/passes/blit.lua")

local function reset()
	grade.Stop()
	grade.Blend("neutral", "neutral", 0)
end

local function srgb_to_linear(c)
	return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

local function linear_to_srgb(c)
	return c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055
end

local function clamp(x, min, max)
	return math.max(min, math.min(max, x))
end

local function luma(x)
	return 0.2126 * x[1] + 0.7152 * x[2] + 0.0722 * x[3]
end

local function reference(c, p, base)
	local brightness, contrast, saturation = (p.brightness or 0) / 100, (p.contrast or 0) / 100, (p.saturation or 0) / 100
	local ambiance, highlights, shadows, warmth = (p.ambiance or 0) / 100,
	(p.highlights or 0) / 100,
	(p.shadows or 0) / 100,
	(p.warmth or 0) / 100
	local lift, gain = p.lift or {0, 0, 0}, p.gain or {1, 1, 1}
	local x = {}

	for i = 1, 3 do
		x[i] = linear_to_srgb(clamp(c[i], 0, 1))
	end

	if ambiance ~= 0 or highlights ~= 0 or shadows ~= 0 then
		local b = base or luma(x)
		local s = clamp(shadows + 0.5 * ambiance, -1, 1)
		local h = clamp(highlights - 0.5 * ambiance, -1, 1)
		local factor = 1 + s * (
				s > 0 and
				3.5 or
				1
			) * (
				1 - b
			) ^ 6 + h * (
				h < 0 and
				3.5 or
				1
			) * b ^ 5 * (
				1 - b
			)

		for i = 1, 3 do
			x[i] = x[i] * factor
		end

		if ambiance ~= 0 then
			local grey = luma(x)
			local surroundings = b * factor
			local ratio = clamp(
				(
						surroundings + (
							grey - surroundings
						) * (
							1 + 0.8 * ambiance
						)
					) / math.max(grey, 1e-3),
				0,
				4
			)

			for i = 1, 3 do
				x[i] = x[i] * ratio
			end
		end

		for i = 1, 3 do
			x[i] = clamp(x[i], 0, 1)
		end
	end

	if brightness ~= 0 then
		for i = 1, 3 do
			x[i] = math.max(x[i], 0) ^ 2 ^ (-0.8 * brightness)
		end
	end

	if contrast ~= 0 then
		local power = 2 ^ (0.75 * contrast)

		for i = 1, 3 do
			local a, b = x[i] ^ power, (1 - x[i]) ^ power
			x[i] = a / (a + b)
		end
	end

	local grey = luma(x)
	local amount = math.max(1 + saturation + 0.25 * ambiance, 0)
	local scale = {1 + 0.15 * warmth, 1, 1 - 0.15 * warmth}
	local out = {}

	for i = 1, 3 do
		local v = (grey + (x[i] - grey) * amount) * scale[i]
		out[i] = srgb_to_linear(clamp(v * gain[i] + lift[i], 0, 1))
	end

	return out
end

local function reference_hdr(c, p, base)
	local sdr = {math.min(c[1], 1), math.min(c[2], 1), math.min(c[3], 1)}
	local graded = reference(sdr, p, base)
	return {graded[1] + c[1] - sdr[1], graded[2] + c[2] - sdr[2], graded[3] + c[3] - sdr[3]}
end

local function set(p)
	for _, name in ipairs{
		"brightness",
		"contrast",
		"saturation",
		"ambiance",
		"highlights",
		"shadows",
		"warmth",
	} do
		if p[name] then pvars.SetSession("r_grade_" .. name, p[name]) end
	end

	for i, channel in ipairs{"r", "g", "b"} do
		if p.lift then pvars.SetSession("r_grade_lift_" .. channel, p.lift[i]) end

		if p.gain then pvars.SetSession("r_grade_gain_" .. channel, p.gain[i]) end
	end
end

T.Test("Graphics render3d grade a preset leaves out what the defaults give", function()
	pvars.SetSession("r_grade_saturation", -50)
	pvars.SetSession("r_camera_white_balance", 5000)
	grade.Blend({}, {}, 1)

	for _, field in ipairs(grade.fields) do
		T(pvars.Get(field.key))["=="](pvars.GetObject(field.key):GetDefault())
	end
end)

T.Test("Graphics render3d grade blends numbers and moves a temperature in mired", function()
	grade.Blend(
		{r_grade_saturation = -50, r_camera_compensation = -1},
		{r_grade_saturation = 50, r_camera_compensation = 1},
		0.25
	)
	T(pvars.Get("r_grade_saturation"))["~"](-25, 1e-6)
	T(pvars.Get("r_camera_compensation"))["~"](-0.5, 1e-6)
	grade.Blend({r_camera_white_balance = 5000}, {r_camera_white_balance = 10000}, 0.5)
	T(pvars.Get("r_camera_white_balance"))["~"](1e6 / 150, 1e-3)
	grade.Blend({r_camera_white_balance = 5000}, {r_camera_white_balance = 10000}, 0)
	T(pvars.Get("r_camera_white_balance"))["~"](5000, 1e-3)
	grade.Blend({r_camera_white_balance = 5000}, {r_camera_white_balance = 10000}, 1)
	T(pvars.Get("r_camera_white_balance"))["~"](10000, 1e-3)
	reset()
end)

T.Test("Graphics render3d grade switches what can't be in between", function()
	grade.Blend({r_tonemapper = "agx"}, {r_tonemapper = "aces"}, 0.49)
	T(pvars.Get("r_tonemapper"))["=="]("agx")
	grade.Blend({r_tonemapper = "agx"}, {r_tonemapper = "aces"}, 0.5)
	T(pvars.Get("r_tonemapper"))["=="]("aces")
	grade.Blend({r_camera_white_balance = 0}, {r_camera_white_balance = 8000}, 0.99)
	T(pvars.Get("r_camera_white_balance"))["=="](0)
	grade.Blend({r_camera_white_balance = 0}, {r_camera_white_balance = 8000}, 1)
	T(pvars.Get("r_camera_white_balance"))["=="](8000)
	reset()
end)

T.Test("Graphics render3d grade a preset applies at once without a blend time", function()
	grade.SetPreset("muted", 0)
	T(grade.GetPreset())["=="]("muted")
	T(grade.IsBlending())["=="](false)
	T(pvars.Get("r_grade_saturation"))["=="](grade.presets.muted.r_grade_saturation)
	grade.SetPreset("neutral", 0)
	T(pvars.Get("r_grade_saturation"))["=="](0)
	reset()
end)

T.Test("Graphics render3d grade refuses what it doesn't know", function()
	T(pcall(grade.Blend, {r_not_a_field = 1}, {}, 0))["=="](false)
	T(pcall(grade.SetPreset, "no_such_preset", 0))["=="](false)
	reset()
end)

T.Test("Graphics render3d grade is off at the defaults", function()
	local block = {}
	reset()
	T(grade.WriteBlock(block).grade_on)["=="](0)
	pvars.SetSession("r_grade_warmth", 10)
	T(grade.WriteBlock(block).grade_on)["=="](1)
	T(block.grade_warmth)["~"](0.1, 1e-6)
	reset()
	pvars.SetSession("r_grade_gain_g", 1.5)
	T(grade.WriteBlock(block).grade_on)["=="](1)
	reset()
end)

T.Test("Graphics render3d grade only the sliders that look at the surroundings need the grid", function()
	reset()
	T(grade.NeedsLocal())["=="](false)

	for _, name in ipairs{"brightness", "contrast", "saturation", "warmth"} do
		pvars.SetSession("r_grade_" .. name, 50)
		T(grade.NeedsLocal())["=="](false)
		reset()
	end

	for _, name in ipairs{"ambiance", "highlights", "shadows"} do
		pvars.SetSession("r_grade_" .. name, -20)
		T(grade.NeedsLocal())["=="](true)
		T(grade.WriteBlock({}).grade_tone)["=="](1)
		reset()
	end
end)

T.Test("Graphics render3d grade shadows is only the darks and highlights only the brights", function()
	local function shown(x, p)
		local out = reference({srgb_to_linear(x), srgb_to_linear(x), srgb_to_linear(x)}, p)[1]
		return linear_to_srgb(out)
	end

	for _, amount in ipairs{-100, 100} do
		for _, x in ipairs{0.05, 0.1, 0.2} do
			T(shown(x, {highlights = amount}))["~"](x, 0.005)
		end

		for _, x in ipairs{0.8, 0.9, 0.95} do
			T(shown(x, {shadows = amount}))["~"](x, 0.005)
		end

		T(shown(0.5, {highlights = amount}))["~"](0.5, 0.04)
		T(shown(0.5, {shadows = amount}))["~"](0.5, 0.04)
	end

	T(shown(0.14, {shadows = 100}) - 0.14 > 0.1)["=="](true)
	T(0.14 - shown(0.14, {shadows = -100}) > 0.03)["=="](true)
	T(0.86 - shown(0.86, {highlights = -100}) > 0.1)["=="](true)
	T(shown(0.86, {highlights = 100}) - 0.86 > 0.02)["=="](true)
end)

T.Test("Graphics render3d grade tone sliders keep black and white and never reverse the tones", function()
	local values = {-100, -50, 0, 50, 100}

	for _, brightness in ipairs(values) do
		for _, contrast in ipairs(values) do
			for _, ambiance in ipairs(values) do
				for _, highlights in ipairs(values) do
					for _, shadows in ipairs(values) do
						local p = {
							brightness = brightness,
							contrast = contrast,
							ambiance = ambiance,
							highlights = highlights,
							shadows = shadows,
						}
						T(reference({0, 0, 0}, p)[1])["~"](0, 1e-6)
						T(reference({1, 1, 1}, p)[1])["~"](1, 1e-6)
						local previous = -1

						for i = 0, 100 do
							local v = reference({i / 100, i / 100, i / 100}, p)[1]
							T(v >= previous - 1e-9)["=="](true)
							previous = v
						end
					end
				end
			end
		end
	end
end)

local INPUTS = [[
	vec3 inputs[5] = vec3[5](vec3(0.5), vec3(1.0, 0.0, 0.0), SRGBToLinear(vec3(0.25)), vec3(0.2), vec3(2.0, 0.5, 0.5));
	float bases[5] = float[5](-1.0, 0.5, 0.7, 0.1, -1.0);
]]
local inputs = {
	{0.5, 0.5, 0.5},
	{1, 0, 0},
	{srgb_to_linear(0.25), srgb_to_linear(0.25), srgb_to_linear(0.25)},
	{0.2, 0.2, 0.2},
	{2, 0.5, 0.5},
}
local bases = {false, 0.5, 0.7, 0.1, false}
local grade_pass = {
	name = "grade_test",
	ComputePass = true,
	ColorFormat = {{"r32g32b32a32_sfloat", {"graded", "rgba"}}},
	FramebufferSize = {x = 5, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 1, z = 1},
	storage_images = {{binding_index = 0, dst_stage = "compute"}},
	uniform_buffers = {
		{
			name = "grade_data",
			binding_index = 1,
			block = {grade.block},
			write = function(self, block)
				return grade.WriteBlock(block)
			end,
		},
	},
	custom_declarations = [[
		layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_graded;
	]],
	shader = compute_helpers.GetColorHelpersGLSL() .. grade.GetGLSL("grade_data") .. [[
		void main() {
			int x = int(gl_GlobalInvocationID.x);
			]] .. INPUTS .. [[

			if (x < 4) imageStore(out_graded, ivec2(x, 0), vec4(grade_display(inputs[x], bases[x]), 1.0));
			if (x == 4) imageStore(out_graded, ivec2(x, 0), vec4(grade_display_hdr(inputs[x], bases[x]), 1.0));
		}
	]],
}

local function run(draw)
	draw()
	local downloaded = render3d.pipelines.grade_test:GetFramebuffer(1):GetAttachment(1):Download()
	local texels = {}

	for x = 0, 4 do
		texels[x] = {downloaded:GetPixelFloat(x, 0)}
	end

	return texels
end

T.Test3D("Graphics render3d grade shader grades the tonemapped colour like the reference", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			grade_pass,
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	reset()
	local ok, err = pcall(function()
		local texels = run(draw)

		for x = 0, 4 do
			for i = 1, 3 do
				T(texels[x][i])["~"](inputs[x + 1][i], 1e-6)
			end
		end

		T(render3d.pipelines.local_exposure_grid.is_enabled())["=="](false)
		T(render3d.pipelines.local_exposure_blur.is_enabled())["=="](false)
		set{shadows = 40}
		T(render3d.pipelines.local_exposure_grid.is_enabled())["=="](true)
		T(render3d.pipelines.local_exposure_blur.is_enabled())["=="](true)
		reset()
		local cases = {
			{brightness = 60},
			{brightness = -100},
			{contrast = 100},
			{contrast = -100},
			{saturation = -100},
			{saturation = 100},
			{shadows = 100, highlights = -100},
			{shadows = -100, highlights = 100},
			{ambiance = -70},
			{ambiance = 100},
			{ambiance = 60, shadows = 30},
			{highlights = 80},
			{warmth = 100},
			{warmth = -60},
			{lift = {0.1, 0, -0.05}, gain = {1.2, 0.8, 1}},
			{
				brightness = 20,
				contrast = 30,
				saturation = -20,
				ambiance = 25,
				highlights = -40,
				shadows = 35,
				warmth = 15,
			},
		}

		for _, p in ipairs(cases) do
			reset()
			set(p)
			texels = run(draw)

			for x = 0, 4 do
				local expected = (x == 4 and reference_hdr or reference)(inputs[x + 1], p, bases[x + 1] or nil)

				for i = 1, 3 do
					T(texels[x][i])["~"](expected[i], 5e-4)
				end
			end
		end

		reset()
		set{saturation = -100}
		texels = run(draw)
		T(texels[1][1])["~"](srgb_to_linear(0.2126), 1e-4)
		T(texels[1][3])["~"](srgb_to_linear(0.2126), 1e-4)
		reset()
		set{contrast = -100}
		texels = run(draw)
		T(texels[2][1] > inputs[3][1] * 1.5)["=="](true)
	end)
	reset()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end
end)
