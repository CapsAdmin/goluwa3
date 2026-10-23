local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
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
}

function grade.WriteBlock(block)
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
	return block
end

function grade.GetGLSL(block_name)
	return (
		(
			[[
		vec3 grade_display(vec3 c) {
			if (BLOCK.grade_on == 0) return c;

			vec3 x = LinearToSRGB(clamp(c, 0.0, 1.0));

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
			x = x * vec3(BLOCK.grade_gain_r, BLOCK.grade_gain_g, BLOCK.grade_gain_b) + vec3(BLOCK.grade_lift_r, BLOCK.grade_lift_g, BLOCK.grade_lift_b);
			return SRGBToLinear(clamp(x, 0.0, 1.0));
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
