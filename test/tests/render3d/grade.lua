local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local grade = import("goluwa/render3d/grade.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local pvars = import("goluwa/cli/pvars.lua")
local exposure = import("goluwa/render3d/exposure.lua")
local fs = import("goluwa/filesystem/fs.lua")
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

local function reference(c, p)
	local brightness, contrast, saturation, warmth = (p.brightness or 0) / 100,
	(p.contrast or 0) / 100,
	(p.saturation or 0) / 100,
	(p.warmth or 0) / 100
	local lift, gain = p.lift or {0, 0, 0}, p.gain or {1, 1, 1}
	local x = {}

	for i = 1, 3 do
		x[i] = linear_to_srgb(clamp(c[i], 0, 1))
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
	local amount = math.max(1 + saturation, 0)
	local scale = {1 + 0.15 * warmth, 1, 1 - 0.15 * warmth}
	local out = {}

	for i = 1, 3 do
		local v = (grey + (x[i] - grey) * amount) * scale[i]
		out[i] = srgb_to_linear(clamp(v * gain[i] + lift[i], 0, 1))
	end

	return out
end

local function reference_hdr(c, p)
	local sdr = {math.min(c[1], 1), math.min(c[2], 1), math.min(c[3], 1)}
	local graded = reference(sdr, p)
	return {graded[1] + c[1] - sdr[1], graded[2] + c[2] - sdr[2], graded[3] + c[3] - sdr[3]}
end

local function set(p)
	for _, name in ipairs{
		"brightness",
		"contrast",
		"saturation",
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
	exposure.Set("camera.white_balance", 5000)
	grade.Blend({}, {}, 1)

	for _, field in ipairs(grade.fields) do
		T(grade.GetValue(field))["=="](grade.GetInfo(field).default)
	end
end)

T.Test("Graphics render3d grade blends numbers and moves a temperature in mired", function()
	grade.Blend(
		{r_grade_saturation = -50, r_grade_contrast = -40},
		{r_grade_saturation = 50, r_grade_contrast = 40},
		0.25
	)
	T(pvars.Get("r_grade_saturation"))["~"](-25, 1e-6)
	T(pvars.Get("r_grade_contrast"))["~"](-20, 1e-6)
	grade.Blend({["camera.white_balance"] = 5000}, {["camera.white_balance"] = 10000}, 0.5)
	T(exposure.Get("camera.white_balance"))["~"](1e6 / 150, 1e-3)
	grade.Blend({["camera.white_balance"] = 5000}, {["camera.white_balance"] = 10000}, 0)
	T(exposure.Get("camera.white_balance"))["~"](5000, 1e-3)
	grade.Blend({["camera.white_balance"] = 5000}, {["camera.white_balance"] = 10000}, 1)
	T(exposure.Get("camera.white_balance"))["~"](10000, 1e-3)
	reset()
end)

T.Test("Graphics render3d grade switches what can't be in between", function()
	grade.Blend({r_tonemapper = "agx"}, {r_tonemapper = "aces"}, 0.49)
	T(pvars.Get("r_tonemapper"))["=="]("agx")
	grade.Blend({r_tonemapper = "agx"}, {r_tonemapper = "aces"}, 0.5)
	T(pvars.Get("r_tonemapper"))["=="]("aces")
	grade.Blend({["camera.white_balance"] = 0}, {["camera.white_balance"] = 8000}, 0.99)
	T(exposure.Get("camera.white_balance"))["=="](0)
	grade.Blend({["camera.white_balance"] = 0}, {["camera.white_balance"] = 8000}, 1)
	T(exposure.Get("camera.white_balance"))["=="](8000)
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

T.Test("Graphics render3d grade tone sliders keep black and white and never reverse the tones", function()
	local values = {-100, -50, 0, 50, 100}

	for _, brightness in ipairs(values) do
		for _, contrast in ipairs(values) do
			local p = {brightness = brightness, contrast = contrast}
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
end)

local INPUTS = [[
	vec3 inputs[5] = vec3[5](vec3(0.5), vec3(1.0, 0.0, 0.0), SRGBToLinear(vec3(0.25)), vec3(0.2), vec3(2.0, 0.5, 0.5));
]]
local inputs = {
	{0.5, 0.5, 0.5},
	{1, 0, 0},
	{srgb_to_linear(0.25), srgb_to_linear(0.25), srgb_to_linear(0.25)},
	{0.2, 0.2, 0.2},
	{2, 0.5, 0.5},
}
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

			if (x < 4) imageStore(out_graded, ivec2(x, 0), vec4(grade_display(inputs[x]), 1.0));
			if (x == 4) imageStore(out_graded, ivec2(x, 0), vec4(grade_display_hdr(inputs[x]), 1.0));
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

		reset()
		local cases = {
			{brightness = 60},
			{brightness = -100},
			{contrast = 100},
			{contrast = -100},
			{saturation = -100},
			{saturation = 100},
			{warmth = 100},
			{warmth = -60},
			{lift = {0.1, 0, -0.05}, gain = {1.2, 0.8, 1}},
			{
				brightness = 20,
				contrast = 30,
				saturation = -20,
				warmth = 15,
			},
		}

		for _, p in ipairs(cases) do
			reset()
			set(p)
			texels = run(draw)

			for x = 0, 4 do
				local expected = (x == 4 and reference_hdr or reference)(inputs[x + 1], p)

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

local MATRIX = {{0.6, 0.3, 0.1}, {0.1, 0.8, 0.1}, {0.2, 0.2, 0.6}}
local OFFSET = {0, 0.02, 0}

local function mix_channels(v)
	local out = {}

	for i = 1, 3 do
		out[i] = MATRIX[i][1] * v[1] + MATRIX[i][2] * v[2] + MATRIX[i][3] * v[3] + OFFSET[i]
	end

	return out
end

local function sample_samples(samples, t)
	local f = clamp(t, 0, 1) * (#samples - 1)
	local i0 = math.floor(f)
	local i1 = math.min(i0 + 1, #samples - 1)
	return samples[i0 + 1] + (samples[i1 + 1] - samples[i0 + 1]) * (f - i0)
end

local function lut_reference(c, p)
	local encoded, v = {}, {}

	for i = 1, 3 do
		local x = linear_to_srgb(clamp(c[i], 0, 1))
		encoded[i] = x

		if p.space == "gamma24" then
			x = srgb_to_linear(x) ^ (1 / 2.4)
		elseif p.space == "linear" then
			x = srgb_to_linear(x)
		end

		v[i] = x
	end

	local out = p.map(v)
	local result = {}

	for i = 1, 3 do
		local y = clamp(out[i], 0, 1)

		if p.space == "gamma24" then
			y = linear_to_srgb(y ^ 2.4)
		elseif p.space == "linear" then
			y = linear_to_srgb(y)
		end

		result[i] = srgb_to_linear(clamp(encoded[i] + (y - encoded[i]) * (p.strength or 1), 0, 1))
	end

	return result
end

local function lut_stage(c, p, hdr)
	local sdr = hdr and {math.min(c[1], 1), math.min(c[2], 1), math.min(c[3], 1)} or c
	local out

	if p.order == "before" then
		out = reference(lut_reference(sdr, p), p.grade or {})
	else
		out = lut_reference(reference(sdr, p.grade or {}), p)
	end

	if hdr then for i = 1, 3 do
		out[i] = out[i] + c[i] - sdr[i]
	end end

	return out
end

local lut_pass = table.copy(grade_pass)
lut_pass.name = "grade_lut_test"
lut_pass.sampled_images = {
	{binding_index = 2, get_texture = grade.GetLutTexture3D},
	{binding_index = 3, get_texture = grade.GetLutTexture1D},
}
lut_pass.shader = compute_helpers.GetColorHelpersGLSL() .. grade.GetGLSL("grade_data", 2, 3) .. [[
	void main() {
		int x = int(gl_GlobalInvocationID.x);
		]] .. INPUTS .. [[

		if (x < 4) imageStore(out_graded, ivec2(x, 0), vec4(grade_display(inputs[x]), 1.0));
		if (x == 4) imageStore(out_graded, ivec2(x, 0), vec4(grade_display_hdr(inputs[x]), 1.0));
	}
]]

local function cube_text(header, size, map)
	local rows = {}

	for blue = 0, size - 1 do
		for green = 0, size - 1 do
			for red = 0, size - 1 do
				local out = map{red / (size - 1), green / (size - 1), blue / (size - 1)}
				rows[#rows + 1] = string.format("%.9f %.9f %.9f", out[1], out[2], out[3])
			end
		end
	end

	return header .. table.concat(rows, "\n") .. "\n"
end

local function write_temp(text)
	local path = os.tmpname() .. ".cube"
	assert(fs.write_file(path, text))
	return path
end

local function set_lut(path, strength, space, order)
	pvars.SetSession("r_grade_lut", path)
	pvars.SetSession("r_grade_lut_strength", strength or 100)
	pvars.SetSession("r_grade_lut_space", space or "srgb")
	pvars.SetSession("r_grade_lut_order", order or "after")
end

local function reset_lut()
	set_lut("", 100, "srgb", "after")
end

local function run_lut(draw)
	draw()
	local downloaded = render3d.pipelines.grade_lut_test:GetFramebuffer(1):GetAttachment(1):Download()
	local texels = {}

	for x = 0, 4 do
		texels[x] = {downloaded:GetPixelFloat(x, 0)}
	end

	return texels
end

T.Test("Graphics render3d grade a look up table switches the block on only when it is loaded and not zero", function()
	local block = {}
	reset_lut()
	T(grade.WriteBlock(block).lut_mode)["=="](0)
	local path = write_temp(cube_text("LUT_3D_SIZE 2\n", 2, mix_channels))
	set_lut(path, 100, "srgb", "after")
	T(grade.WriteBlock(block).lut_mode)["=="](16 + 1)
	T(block.lut_size_3d)["=="](2)
	T(block.lut_size_1d)["=="](0)
	set_lut(path, 100, "linear", "before")
	grade.WriteBlock(block)
	T(block.lut_mode)["=="](16 + 1 + 2 + 2 * 4)
	set_lut(path, 0, "srgb", "after")
	T(grade.WriteBlock(block).lut_mode)["=="](16)
	set_lut("/no/such/lut.cube", 100, "srgb", "after")
	T(grade.WriteBlock(block).lut_mode)["=="](0)
	reset_lut()
	os.remove(path)
end)

T.Test3D("Graphics render3d grade shader applies a look up table like the reference", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			lut_pass,
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	reset()
	reset_lut()
	local paths = {}
	local ok, err = pcall(function()
		local function check(name, p, expected_text)
			reset()
			reset_lut()

			if p.grade then set(p.grade) end

			local path = write_temp(expected_text)
			paths[#paths + 1] = path
			set_lut(path, p.strength and p.strength * 100 or 100, p.space, p.order)
			local texels = run_lut(draw)

			for x = 0, 4 do
				local expected = lut_stage(inputs[x + 1], p, x == 4)

				for i = 1, 3 do
					T(texels[x][i], name .. " input " .. x .. " channel " .. i)["~"](expected[i], 5e-4)
				end
			end
		end

		local text3d = cube_text("LUT_3D_SIZE 2\n", 2, mix_channels)
		check("3d table", {map = mix_channels}, text3d)
		check("strength", {map = mix_channels, strength = 0.4}, text3d)
		check("gamma 2.4", {map = mix_channels, space = "gamma24"}, text3d)
		check("linear", {map = mix_channels, space = "linear"}, text3d)
		check(
			"after the grade",
			{map = mix_channels, grade = {contrast = 40, saturation = -30}},
			text3d
		)
		check(
			"before the grade",
			{map = mix_channels, order = "before", grade = {contrast = 40, saturation = -30}},
			text3d
		)
		local squares = {0, 0.25, 1}
		local rows_1d = {}

		for _, value in ipairs(squares) do
			rows_1d[#rows_1d + 1] = string.format("%.9f %.9f %.9f", value, value, value)
		end

		check(
			"1d table",
			{
				map = function(v)
					return {
						sample_samples(squares, v[1]),
						sample_samples(squares, v[2]),
						sample_samples(squares, v[3]),
					}
				end,
			},
			"LUT_1D_SIZE 3\nLUT_1D_INPUT_RANGE 0.0 1.0\n" .. table.concat(rows_1d, "\n") .. "\n"
		)
		check(
			"1d table in front of a 3d table",
			{
				map = function(v)
					return {v[1] / 2, v[2] / 2, v[3] / 2}
				end,
			},
			"LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 0.0 2.0\nLUT_3D_SIZE 2\n0 0 0\n1 1 1\n" .. cube_text("", 2, function(v)
					return v
				end)
		)
	end)
	reset()
	reset_lut()

	for _, path in ipairs(paths) do
		os.remove(path)
	end

	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end
end)

local function chromaticity_matrix(r, g, b, w)
	local function column(p)
		return {p[1] / p[2], 1, (1 - p[1] - p[2]) / p[2]}
	end

	local primaries = {column(r), column(g), column(b)}
	local white = column(w)

	local function det(m)
		return m[1][1] * (
				m[2][2] * m[3][3] - m[2][3] * m[3][2]
			) - m[1][2] * (
				m[2][1] * m[3][3] - m[2][3] * m[3][1]
			) + m[1][3] * (
				m[2][1] * m[3][2] - m[2][2] * m[3][1]
			)
	end

	local m = {
		{primaries[1][1], primaries[2][1], primaries[3][1]},
		{primaries[1][2], primaries[2][2], primaries[3][2]},
		{primaries[1][3], primaries[2][3], primaries[3][3]},
	}
	local d = det(m)
	local scale = {}

	for i = 1, 3 do
		local mi = {
			{m[1][1], m[1][2], m[1][3]},
			{m[2][1], m[2][2], m[2][3]},
			{m[3][1], m[3][2], m[3][3]},
		}

		for row = 1, 3 do
			mi[row][i] = white[row]
		end

		scale[i] = det(mi) / d
	end

	local out = {}

	for row = 1, 3 do
		out[row] = {m[row][1] * scale[1], m[row][2] * scale[2], m[row][3] * scale[3]}
	end

	return out
end

local function invert(m)
	local a, b, c, d, e, f, g, h, i = m[1][1], m[1][2], m[1][3], m[2][1], m[2][2], m[2][3], m[3][1], m[3][2], m[3][3]
	local det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
	return {
		{
			(
				e * i - f * h
			) / det,
			(
				c * h - b * i
			) / det,
			(
				b * f - c * e
			) / det,
		},
		{
			(
				f * g - d * i
			) / det,
			(
				a * i - c * g
			) / det,
			(
				c * d - a * f
			) / det,
		},
		{
			(
				d * h - e * g
			) / det,
			(
				b * g - a * h
			) / det,
			(
				a * e - b * d
			) / det,
		},
	}
end

local function multiply(a, b)
	local out = {}

	for i = 1, 3 do
		out[i] = {}

		for j = 1, 3 do
			out[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
		end
	end

	return out
end

local WHITE = {0.3127, 0.3290}
local REC709 = chromaticity_matrix({0.64, 0.33}, {0.30, 0.60}, {0.15, 0.06}, WHITE)
local FROM_REC709 = {
	[5] = multiply(
		invert(chromaticity_matrix({0.766, 0.275}, {0.225, 0.800}, {0.089, -0.087}, WHITE)),
		REC709
	),
	[6] = multiply(
		invert(chromaticity_matrix({0.6840, 0.3130}, {0.2210, 0.8480}, {0.0861, -0.1020}, WHITE)),
		REC709
	),
}

local function slog3(x)
	if x >= 0.01125 then
		return (420 + math.log10((x + 0.01) / 0.19) * 261.5) / 1023
	end

	return (x * (171.2102946929 - 95) / 0.01125 + 95) / 1023
end

local function logc(x)
	if x > 0.010591 then
		return 0.247190 * math.log10(5.555556 * x + 0.052272) + 0.385537
	end

	return 5.367655 * x + 0.092809
end

local function cineon(x)
	local offset = 10 ^ ((95 - 685) * 0.002 / 0.6)
	return (685 + 300 * math.log10(math.max(x * (1 - offset) + offset, 1e-6))) / 1023
end

local function encode_reference(c, kind)
	local out = {}

	if kind == 7 then
		for i = 1, 3 do
			out[i] = cineon(math.max(c[i], 0))
		end

		return out
	end

	local m = FROM_REC709[kind]

	for i = 1, 3 do
		local v = m[i][1] * math.max(c[1], 0) + m[i][2] * math.max(c[2], 0) + m[i][3] * math.max(c[3], 0)
		out[i] = (kind == 5 and slog3 or logc)(v)
	end

	return out
end

local function log_test_pass(name, width, height, body)
	local pass = table.copy(lut_pass)
	pass.name = name
	pass.FramebufferSize = {x = width, y = height}
	pass.shader = compute_helpers.GetColorHelpersGLSL() .. grade.GetGLSL("grade_data", 2, 3) .. [[
		void main() {
			int x = int(gl_GlobalInvocationID.x);
			int y = int(gl_GlobalInvocationID.y);
			]] .. INPUTS .. body .. [[
		}
	]]
	return pass
end

local encoder_pass = log_test_pass(
	"grade_encoder_test",
	15,
	1,
	[[
	if (x < 15) imageStore(out_graded, ivec2(x, 0), vec4(log_encode(inputs[x % 5], 5 + x / 5), 1.0));
]]
)

local function log_mode_pass(kind)
	return log_test_pass(
		"grade_log_mode_test",
		5,
		2,
		string.format(
			[[
		if (x < 5 && y == 0) imageStore(out_graded, ivec2(x, 0), vec4(grade_display_log(clamp(log_encode(inputs[x], %d), 0.0, 1.0), clamp(tonemap(inputs[x], 4), 0.0, 1.0)), 1.0));
		if (x < 5 && y == 1) imageStore(out_graded, ivec2(x, 1), vec4(grade_display(clamp(tonemap(inputs[x], 4), 0.0, 1.0)), 1.0));
	]],
			kind
		)
	)
end

local function download_texels(pipeline_name, width, height)
	local downloaded = render3d.pipelines[pipeline_name]:GetFramebuffer(1):GetAttachment(1):Download()
	local texels = {}

	for y = 0, height - 1 do
		texels[y] = {}

		for x = 0, width - 1 do
			texels[y][x] = {downloaded:GetPixelFloat(x, y)}
		end
	end

	return texels
end

T.Test3D("Graphics render3d grade log encoders match the camera curves and gamuts", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			encoder_pass,
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	local ok, err = pcall(function()
		draw()
		local texels = download_texels("grade_encoder_test", 15, 1)

		for x = 0, 14 do
			local kind = 5 + math.floor(x / 5)
			local expected = encode_reference(inputs[x % 5 + 1], kind)

			for i = 1, 3 do
				T(texels[0][x][i], "encoder " .. kind .. " input " .. x % 5 .. " channel " .. i)["~"](expected[i], 1e-4)
			end
		end

		T(slog3(0.18))["~"](420 / 1023, 1e-6)
		T(logc(0.18))["~"](0.391, 1e-3)
		T(cineon(1))["~"](685 / 1023, 1e-9)
		T(cineon(13.5216945686))["~"](1, 1e-9)
		T(cineon(-0.0056508194))["~"](0, 1e-9)
		T(texels[0][0][1])["~"](slog3(0.5), 1e-3)
	end)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d grade log mode feeds the encoded scene to the table and writes its output", function(draw)
	local ok, err = pcall(function()
		local paths = {}
		local text3d = cube_text("LUT_3D_SIZE 2\n", 2, mix_channels)

		for _, kind in ipairs{5, 6, 7} do
			render3d.Initialize{
				passes = {
					import("goluwa/render3d/passes/gbuffer.lua"),
					log_mode_pass(kind),
					import("goluwa/render3d/passes/blit.lua"),
				},
			}
			reset()
			reset_lut()
			draw()
			local texels = download_texels("grade_log_mode_test", 5, 2)

			for x = 0, 4 do
				local encoded = encode_reference(inputs[x + 1], kind)

				for i = 1, 3 do
					T(
						texels[0][x][i],
						"no table shows the raw log kind " .. kind .. " input " .. x .. " channel " .. i
					)["~"](srgb_to_linear(clamp(encoded[i], 0, 1)), 5e-4)
				end
			end

			local path = write_temp(text3d)
			paths[#paths + 1] = path

			for _, space in ipairs{"srgb", "gamma24", "linear"} do
				set_lut(path, 100, space, "after")
				draw()
				texels = download_texels("grade_log_mode_test", 5, 2)

				for x = 0, 4 do
					local encoded = encode_reference(inputs[x + 1], kind)

					for i = 1, 3 do
						encoded[i] = clamp(encoded[i], 0, 1)
					end

					local out = mix_channels(encoded)

					for i = 1, 3 do
						local y = clamp(out[i], 0, 1)

						if space == "gamma24" then
							y = linear_to_srgb(y ^ 2.4)
						elseif space == "linear" then
							y = linear_to_srgb(y)
						end

						T(texels[0][x][i], "kind " .. kind .. " " .. space .. " input " .. x .. " channel " .. i)["~"](srgb_to_linear(y), 5e-4)
					end
				end
			end

			set_lut(path, 0, "srgb", "after")
			draw()
			texels = download_texels("grade_log_mode_test", 5, 2)

			for x = 0, 4 do
				for i = 1, 3 do
					T(texels[0][x][i], "strength 0 is the neutral image")["~"](texels[1][x][i], 1e-5)
				end
			end
		end

		reset_lut()

		for _, path in ipairs(paths) do
			os.remove(path)
		end
	end)
	reset()
	reset_lut()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end
end)

local function bend(v)
	local t = 0.2 * (v[1] - v[2]) * (v[2] - v[3])
	return {v[1] + t, v[2], v[3] - t}
end

local function interpolate(map, size, v, tetrahedral)
	local n = size - 1
	local i0, w = {}, {}

	for i = 1, 3 do
		local f = clamp(v[i], 0, 1) * n
		i0[i] = math.floor(f)
		w[i] = f - i0[i]
	end

	local function corner(dr, dg, db)
		return map({
			math.min(i0[1] + dr, n) / n,
			math.min(i0[2] + dg, n) / n,
			math.min(i0[3] + db, n) / n,
		})
	end

	local c = {}

	for dr = 0, 1 do
		for dg = 0, 1 do
			for db = 0, 1 do
				c[dr .. dg .. db] = corner(dr, dg, db)
			end
		end
	end

	local out = {}
	local r, g, b = w[1], w[2], w[3]

	for i = 1, 3 do
		local function at(key)
			return c[key][i]
		end

		if tetrahedral then
			if r > g then
				if g > b then
					out[i] = at("000") + (at("100") - at("000")) * r + (at("110") - at("100")) * g + (at("111") - at("110")) * b
				elseif r > b then
					out[i] = at("000") + (at("100") - at("000")) * r + (at("101") - at("100")) * b + (at("111") - at("101")) * g
				else
					out[i] = at("000") + (at("001") - at("000")) * b + (at("101") - at("001")) * r + (at("111") - at("101")) * g
				end
			elseif r > b then
				out[i] = at("000") + (at("010") - at("000")) * g + (at("110") - at("010")) * r + (at("111") - at("110")) * b
			elseif g > b then
				out[i] = at("000") + (at("010") - at("000")) * g + (at("011") - at("010")) * b + (at("111") - at("011")) * r
			else
				out[i] = at("000") + (at("001") - at("000")) * b + (at("011") - at("001")) * g + (at("111") - at("011")) * r
			end
		else
			local function lerp(a, d, t)
				return a + (d - a) * t
			end

			out[i] = lerp(
				lerp(lerp(at("000"), at("100"), r), lerp(at("010"), at("110"), r), g),
				lerp(lerp(at("001"), at("101"), r), lerp(at("011"), at("111"), r), g),
				b
			)
		end
	end

	return out
end

local TETRA_COLORS = {
	{0.80, 0.55, 0.20},
	{0.85, 0.20, 0.55},
	{0.55, 0.20, 0.85},
	{0.55, 0.85, 0.20},
	{0.20, 0.85, 0.55},
	{0.20, 0.55, 0.85},
	{0.25, 0.25, 0.25},
	{0.60, 0.60, 0.60},
}
local tetra_pass = table.copy(lut_pass)
tetra_pass.name = "grade_tetra_test"
tetra_pass.FramebufferSize = {x = #TETRA_COLORS, y = 1}
tetra_pass.shader = compute_helpers.GetColorHelpersGLSL() .. grade.GetGLSL("grade_data", 2, 3) .. (function()
	local colors = {}

	for i, c in ipairs(TETRA_COLORS) do
		colors[i] = string.format("vec3(%.9f, %.9f, %.9f)", c[1], c[2], c[3])
	end

	return string.format(
		[[
	void main() {
		int x = int(gl_GlobalInvocationID.x);
		vec3 colors[%d] = vec3[%d](%s);

		if (x < %d) imageStore(out_graded, ivec2(x, 0), vec4(grade_display(SRGBToLinear(colors[x])), 1.0));
	}
]],
		#TETRA_COLORS,
		#TETRA_COLORS,
		table.concat(colors, ", "),
		#TETRA_COLORS
	)
end)()

T.Test3D("Graphics render3d grade look up table is interpolated tetrahedrally and keeps greys neutral", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			tetra_pass,
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	local path = write_temp(cube_text("LUT_3D_SIZE 3\n", 3, bend))
	local ok, err = pcall(function()
		reset()
		set_lut(path, 100, "srgb", "after")
		draw()
		local downloaded = render3d.pipelines.grade_tetra_test:GetFramebuffer(1):GetAttachment(1):Download()
		local differs = false

		for x, color in ipairs(TETRA_COLORS) do
			local expected = interpolate(bend, 3, color, true)
			local trilinear = interpolate(bend, 3, color, false)
			local got = {downloaded:GetPixelFloat(x - 1, 0)}

			for i = 1, 3 do
				T(linear_to_srgb(got[i]), "color " .. x .. " channel " .. i)["~"](clamp(expected[i], 0, 1), 5e-4)

				if math.abs(expected[i] - trilinear[i]) > 2e-3 then differs = true end
			end

			if color[1] == color[2] and color[2] == color[3] then
				T(got[1], "grey " .. x .. " r against g")["~"](got[2], 1e-5)
				T(got[2], "grey " .. x .. " g against b")["~"](got[3], 1e-5)
				T(math.abs(trilinear[1] - trilinear[3]) > 1e-3, "trilinear tints grey " .. x)["=="](true)
			end
		end

		T(differs)["=="](true)
	end)
	reset_lut()
	os.remove(path)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end
end)

