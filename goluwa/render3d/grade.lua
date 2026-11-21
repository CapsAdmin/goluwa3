local ffi = require("ffi")
local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local vfs = import("goluwa/vfs.lua")
local lut_codec = import("goluwa/codecs/lut.lua")
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
	help = "an S curve around mid grey, black and white stay, below 0 it flattens",
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
pvars.StartGroup("Post", "Color balance", {store = false, prefix = "grade_"})
local lift_r = pvars.Setup2{
	key = "r_grade_lift_r",
	default = 0,
	min = -0.5,
	max = 0.5,
	help = "red added to the tonemapped image, mostly seen in the shadows",
}
local lift_g = pvars.Setup2{
	key = "r_grade_lift_g",
	default = 0,
	min = -0.5,
	max = 0.5,
	help = "green added to the tonemapped image, mostly seen in the shadows",
}
local lift_b = pvars.Setup2{
	key = "r_grade_lift_b",
	default = 0,
	min = -0.5,
	max = 0.5,
	help = "blue added to the tonemapped image, mostly seen in the shadows",
}
local gain_r = pvars.Setup2{
	key = "r_grade_gain_r",
	default = 1,
	min = 0,
	max = 4,
	help = "scales the red of the tonemapped image, mostly seen in the highlights",
}
local gain_g = pvars.Setup2{
	key = "r_grade_gain_g",
	default = 1,
	min = 0,
	max = 4,
	help = "scales the green of the tonemapped image, mostly seen in the highlights",
}
local gain_b = pvars.Setup2{
	key = "r_grade_gain_b",
	default = 1,
	min = 0,
	max = 4,
	help = "scales the blue of the tonemapped image, mostly seen in the highlights",
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
	{"grade_saturation", "float"},
	{"grade_warmth", "float"},
	{"grade_lift_r", "float"},
	{"grade_lift_g", "float"},
	{"grade_lift_b", "float"},
	{"grade_gain_r", "float"},
	{"grade_gain_g", "float"},
	{"grade_gain_b", "float"},
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

function grade.WriteBlock(block)
	update_lut()
	block.grade_brightness = brightness:Get() / 100
	block.grade_contrast = contrast:Get() / 100
	block.grade_saturation = saturation:Get() / 100
	block.grade_warmth = warmth:Get() / 100
	block.grade_lift_r = lift_r:Get()
	block.grade_lift_g = lift_g:Get()
	block.grade_lift_b = lift_b:Get()
	block.grade_gain_r = gain_r:Get()
	block.grade_gain_g = gain_g:Get()
	block.grade_gain_b = gain_b:Get()
	block.grade_on = (
			block.grade_brightness ~= 0 or
			block.grade_contrast ~= 0 or
			block.grade_saturation ~= 0 or
			block.grade_warmth ~= 0 or
			block.grade_lift_r ~= 0 or
			block.grade_lift_g ~= 0 or
			block.grade_lift_b ~= 0 or
			block.grade_gain_r ~= 1 or
			block.grade_gain_g ~= 1 or
			block.grade_gain_b ~= 1
		)
		and
		1 or
		0
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

-- binding_3d and binding_1d are the bindings of the table samplers, a shader that gives none has no table
function grade.GetGLSL(block_name, binding_3d, binding_1d)
	local lut = binding_3d and LUT_GLSL:format(binding_3d, binding_1d) or LUT_STUB
	return (
		(
			lut .. [[
		vec3 grade_controls(vec3 x) {
			if (BLOCK.grade_on == 0) return x;

			if (BLOCK.grade_brightness != 0.0) x = pow(max(x, vec3(0.0)), vec3(exp2(-0.8 * BLOCK.grade_brightness)));

			if (BLOCK.grade_contrast != 0.0) {
				float p = exp2(0.75 * BLOCK.grade_contrast);
				vec3 a = pow(x, vec3(p));
				vec3 b = pow(1.0 - x, vec3(p));
				x = a / (a + b);
			}

			float saturation = max(1.0 + BLOCK.grade_saturation, 0.0);
			x = mix(vec3(dot(x, vec3(0.2126, 0.7152, 0.0722))), x, saturation);
			x *= vec3(1.0 + 0.15 * BLOCK.grade_warmth, 1.0, 1.0 - 0.15 * BLOCK.grade_warmth);
			return x * vec3(BLOCK.grade_gain_r, BLOCK.grade_gain_g, BLOCK.grade_gain_b) + vec3(BLOCK.grade_lift_r, BLOCK.grade_lift_g, BLOCK.grade_lift_b);
		}

		vec3 grade_display(vec3 c) {
			if (BLOCK.grade_on == 0 && (BLOCK.lut_mode & 1) == 0) return c;

			vec3 x = LinearToSRGB(clamp(c, 0.0, 1.0));

			if ((BLOCK.lut_mode & 3) == 3) x = grade_lut(x);

			x = grade_controls(x);

			if ((BLOCK.lut_mode & 3) == 1) x = grade_lut(x);

			return SRGBToLinear(clamp(x, 0.0, 1.0));
		}

		vec3 grade_display_log(vec3 encoded, vec3 plain) {
			vec3 x = clamp(encoded, 0.0, 1.0);

			if ((BLOCK.lut_mode & 16) != 0) x = LinearToSRGB(plain);

			if ((BLOCK.lut_mode & 1) != 0) x = grade_lut_log(encoded, x);

			return SRGBToLinear(clamp(grade_controls(x), 0.0, 1.0));
		}

		vec3 grade_display_hdr(vec3 c) {
			vec3 sdr = min(c, vec3(1.0));
			return grade_display(sdr) + (c - sdr);
		}
	]]
		):gsub("BLOCK", block_name)
	)
end

local fields = {
	{key = "r_grade_brightness"},
	{key = "r_grade_contrast"},
	{key = "r_grade_saturation"},
	{key = "r_grade_warmth"},
	{key = "r_grade_lift_r"},
	{key = "r_grade_lift_g"},
	{key = "r_grade_lift_b"},
	{key = "r_grade_gain_r"},
	{key = "r_grade_gain_g"},
	{key = "r_grade_gain_b"},
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

local function apply(a, b, t)
	for _, field in ipairs(fields) do
		local from, to = a[field.key], b[field.key]
		local value

		if type(from) ~= "number" then
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
