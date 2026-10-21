local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
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
local ambiance = pvars.Setup2{
	key = "r_grade_ambiance",
	default = 0,
	min = -100,
	max = 100,
	help = "above 0 lifts the shadows, brings the highlights down, adds detail and colour, below 0 flattens and softens. Works on a pixel against its surroundings",
}
local highlights = pvars.Setup2{
	key = "r_grade_highlights",
	default = 0,
	min = -100,
	max = 100,
	help = "brightens (above 0) or recovers (below 0) the bright regions, white stays where it is surrounded by white",
}
local shadows = pvars.Setup2{
	key = "r_grade_shadows",
	default = 0,
	min = -100,
	max = 100,
	help = "lifts (above 0) or deepens (below 0) the dark regions, black stays",
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
grade.block = {
	{"grade_on", "int"},
	{"grade_tone", "int"},
	{"grade_local", "int"},
	{"grade_brightness", "float"},
	{"grade_contrast", "float"},
	{"grade_saturation", "float"},
	{"grade_ambiance", "float"},
	{"grade_highlights", "float"},
	{"grade_shadows", "float"},
	{"grade_warmth", "float"},
	{"grade_lift_r", "float"},
	{"grade_lift_g", "float"},
	{"grade_lift_b", "float"},
	{"grade_gain_r", "float"},
	{"grade_gain_g", "float"},
	{"grade_gain_b", "float"},
}

function grade.NeedsLocal()
	return ambiance:Get() ~= 0 or highlights:Get() ~= 0 or shadows:Get() ~= 0
end

function grade.WriteBlock(block)
	block.grade_brightness = brightness:Get() / 100
	block.grade_contrast = contrast:Get() / 100
	block.grade_saturation = saturation:Get() / 100
	block.grade_ambiance = ambiance:Get() / 100
	block.grade_highlights = highlights:Get() / 100
	block.grade_shadows = shadows:Get() / 100
	block.grade_warmth = warmth:Get() / 100
	block.grade_lift_r = lift_r:Get()
	block.grade_lift_g = lift_g:Get()
	block.grade_lift_b = lift_b:Get()
	block.grade_gain_r = gain_r:Get()
	block.grade_gain_g = gain_g:Get()
	block.grade_gain_b = gain_b:Get()
	block.grade_tone = (block.grade_ambiance ~= 0 or block.grade_highlights ~= 0 or block.grade_shadows ~= 0) and 1 or 0
	block.grade_local = 0
	block.grade_on = (
			block.grade_brightness ~= 0 or
			block.grade_contrast ~= 0 or
			block.grade_saturation ~= 0 or
			block.grade_ambiance ~= 0 or
			block.grade_highlights ~= 0 or
			block.grade_shadows ~= 0 or
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
	return block
end

function grade.GetGLSL(block_name)
	return (([[
		vec3 grade_display(vec3 c, float base) {
			if (BLOCK.grade_on == 0) return c;

			vec3 x = LinearToSRGB(clamp(c, 0.0, 1.0));

			if (BLOCK.grade_tone != 0) {
				const vec3 luma_weights = vec3(0.2126, 0.7152, 0.0722);
				float b = base < 0.0 ? dot(x, luma_weights) : base;
				float s = clamp(BLOCK.grade_shadows + 0.5 * BLOCK.grade_ambiance, -1.0, 1.0);
				float h = clamp(BLOCK.grade_highlights - 0.5 * BLOCK.grade_ambiance, -1.0, 1.0);
				float lower = (1.0 - b) * (1.0 - b);
				lower = lower * lower * lower;
				float upper = b * b;
				upper = upper * upper * b * (1.0 - b);
				float gain = 1.0 + s * (s > 0.0 ? 3.5 : 1.0) * lower + h * (h < 0.0 ? 3.5 : 1.0) * upper;
				x *= gain;

				if (BLOCK.grade_ambiance != 0.0) {
					float luma = dot(x, luma_weights);
					float surroundings = b * gain;
					x *= clamp((surroundings + (luma - surroundings) * (1.0 + 0.8 * BLOCK.grade_ambiance)) / max(luma, 1e-3), 0.0, 4.0);
				}

				x = clamp(x, 0.0, 1.0);
			}

			if (BLOCK.grade_brightness != 0.0) x = pow(max(x, vec3(0.0)), vec3(exp2(-0.8 * BLOCK.grade_brightness)));

			if (BLOCK.grade_contrast != 0.0) {
				float p = exp2(0.75 * BLOCK.grade_contrast);
				vec3 a = pow(x, vec3(p));
				vec3 b = pow(1.0 - x, vec3(p));
				x = a / (a + b);
			}

			float saturation = max(1.0 + BLOCK.grade_saturation + 0.25 * BLOCK.grade_ambiance, 0.0);
			x = mix(vec3(dot(x, vec3(0.2126, 0.7152, 0.0722))), x, saturation);
			x *= vec3(1.0 + 0.15 * BLOCK.grade_warmth, 1.0, 1.0 - 0.15 * BLOCK.grade_warmth);
			x = x * vec3(BLOCK.grade_gain_r, BLOCK.grade_gain_g, BLOCK.grade_gain_b) + vec3(BLOCK.grade_lift_r, BLOCK.grade_lift_g, BLOCK.grade_lift_b);
			return SRGBToLinear(clamp(x, 0.0, 1.0));
		}

		vec3 grade_display_hdr(vec3 c, float base) {
			vec3 sdr = min(c, vec3(1.0));
			return grade_display(sdr, base) + (c - sdr);
		}
	]]):gsub("BLOCK", block_name))
end

local fields = {
	{key = "r_grade_brightness"},
	{key = "r_grade_contrast"},
	{key = "r_grade_saturation"},
	{key = "r_grade_ambiance"},
	{key = "r_grade_highlights"},
	{key = "r_grade_shadows"},
	{key = "r_grade_warmth"},
	{key = "r_grade_lift_r"},
	{key = "r_grade_lift_g"},
	{key = "r_grade_lift_b"},
	{key = "r_grade_gain_r"},
	{key = "r_grade_gain_g"},
	{key = "r_grade_gain_b"},
	{key = "r_camera_compensation"},
	{key = "r_camera_white_balance", white_balance = true},
	{key = "r_camera_white_balance_tint"},
	{key = "r_tonemapper"},
	{key = "r_bloom_strength"},
}
grade.fields = fields
local field_keys = {}

for _, field in ipairs(fields) do
	field_keys[field.key] = true
end

grade.presets = {
	neutral = {},
	warm = {
		r_camera_white_balance = 7500,
		r_grade_saturation = 5,
	},
	cool = {
		r_camera_white_balance = 5200,
		r_grade_saturation = -5,
	},
	muted = {
		r_grade_saturation = -40,
		r_grade_contrast = 10,
	},
	soft = {
		r_grade_ambiance = 40,
		r_grade_contrast = -10,
		r_grade_warmth = 10,
	},
}
grade.blend_time = 0
grade.blend_elapsed = 0

local function get_state()
	local state = {}

	for _, field in ipairs(fields) do
		state[field.key] = pvars.Get(field.key)
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

		if value == nil then value = pvars.GetObject(field.key):GetDefault() end

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

		if value ~= pvars.Get(field.key) then pvars.SetSession(field.key, value) end
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
