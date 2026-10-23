local exposure = {}
local KEY = 0.18
local LOG2_10 = math.log(10) / math.log(2)
exposure.LOG_EXPOSURE_AT_EV0 = math.log(KEY * 8) / math.log(2)
local APERTURE_MIN = 1.4
local APERTURE_MAX = 16
local SHUTTER_MIN = 1 / 8000
local SHUTTER_MAX = 1 / 30
local ISO_BASE = 100
local ISO_MIN = 12
local ISO_MAX = 409600
local fields = {}
local state = {}
exposure.fields = fields
exposure.modes = {program = 0, aperture_priority = 1, shutter_priority = 2, manual = 3}

local function log2(x)
	return math.log(x) / math.log(2)
end

local function define(key, default, info)
	info.key = key
	info.default = default
	info.type = type(default)
	info.friendly = info.friendly or (key:match("%.(.+)$"):gsub("_", " "))
	fields[#fields + 1] = info
	fields[key] = info
	state[key] = default
end

define(
	"camera.mode",
	"program",
	{
		group = "Camera",
		enums = {"program", "aperture_priority", "shutter_priority", "manual"},
		help = "program picks aperture, shutter and ISO for the exposure, the priority modes keep the aperture or the shutter you set and pick the rest, manual keeps all three (and then the exposure does not follow the scene)",
	}
)
define(
	"camera.ev_min",
	5,
	{
		group = "Camera",
		min = -6,
		max = 21,
		help = "darkest exposure (EV100) the camera picks, scenes darker than this stay dark. The ISO, aperture and shutter follow from the exposure. Set min and max equal to lock the exposure",
	}
)
define(
	"camera.ev_max",
	17,
	{
		group = "Camera",
		min = -6,
		max = 21,
		help = "brightest exposure (EV100) the camera picks, scenes brighter than this stay bright",
	}
)
define(
	"camera.grey",
	50,
	{
		group = "Camera",
		min = 1,
		max = 90,
		help = "the grey midpoint in percent, the brightness the metered scene average is exposed to. 18 is middle grey, higher exposes brighter, lower darker",
	}
)
define(
	"camera.iso",
	100,
	{
		group = "Manual",
		min = ISO_MIN,
		max = ISO_MAX,
		help = "sensitivity in manual mode",
	}
)
define(
	"camera.aperture",
	8,
	{
		group = "Manual",
		min = 0.7,
		max = 64,
		help = "f-number in manual and aperture priority mode",
	}
)
define(
	"camera.shutter",
	1 / 125,
	{
		group = "Manual",
		min = 1 / 100000,
		max = 60,
		help = "shutter time in seconds in manual and shutter priority mode",
	}
)
define(
	"camera.white_balance",
	6500,
	{
		group = "White balance",
		min = 0,
		max = 25000,
		help = "colour temperature in kelvin of the light the camera takes for white, 6500 (D65, the display's white) leaves the colours as they are, 5500 is daylight, 0 estimates it from the frame (gray world)",
	}
)
define(
	"camera.white_balance_tint",
	0,
	{
		group = "White balance",
		min = -1,
		max = 1,
		help = "how green (+) or magenta (-) the light is that the white balance takes for white, on top of its colour temperature",
	}
)
define(
	"eye.enabled",
	false,
	{
		group = "Eye",
		help = "expose like an eye, which shows what a person would see (dim scenes stay dim, local adaptation, rod vision). Off exposes like a camera, which shows every scene's average at the same brightness",
	}
)
define(
	"eye.adaptation_min",
	-4,
	{
		group = "Eye",
		min = -4,
		max = 5,
		help = "lowest adapting luminance in log10 cd/m2, a darker scene is treated as this dark (-4 is the dimmest starlight the curve covers)",
	}
)
define(
	"eye.adaptation_max",
	5,
	{
		group = "Eye",
		min = -4,
		max = 5,
		help = "highest adapting luminance in log10 cd/m2, a brighter scene is treated as this bright (5 is direct sunlight on snow)",
	}
)
define(
	"eye.night_vision",
	true,
	{
		group = "Eye",
		help = "rod vision in dim light",
	}
)
define(
	"eye.night_vision_threshold",
	0.03,
	{
		group = "Eye",
		min = 0.0001,
		max = 10,
		help = "luminance in cd/m2 at which half the colour is gone",
	}
)

function exposure.Get(key)
	local value = state[key]

	if value == nil then error("unknown exposure setting " .. tostring(key), 2) end

	return value
end

function exposure.Set(key, value)
	local info = fields[key] or error("unknown exposure setting " .. tostring(key), 2)

	if type(value) ~= info.type then
		error(key .. " expects a " .. info.type .. ", got " .. type(value), 2)
	end

	if info.enums then
		if not table.has_value(info.enums, value) then
			error(
				key .. " expects one of " .. table.concat(info.enums, ", ") .. ", got " .. value,
				2
			)
		end
	elseif info.type == "number" then
		value = math.clamp(value, info.min or -math.huge, info.max or math.huge)
	end

	state[key] = value
end

function exposure.GetDefault(key)
	return (fields[key] or error("unknown exposure setting " .. tostring(key), 2)).default
end

function exposure.IsEye()
	return state["eye.enabled"]
end

function exposure.GetCompensation()
	if state["eye.enabled"] then return 0 end

	return log2(state["camera.grey"] / (KEY * 100))
end

function exposure.GetRange()
	if state["eye.enabled"] then
		local low, high = state["eye.adaptation_min"], state["eye.adaptation_max"]
		return 3 + low * LOG2_10, 3 + math.max(low, high) * LOG2_10
	end

	return state["camera.ev_min"],
	math.max(state["camera.ev_min"], state["camera.ev_max"])
end

function exposure.GetManualEV()
	if state["eye.enabled"] or state["camera.mode"] ~= "manual" then return nil end

	return log2(state["camera.aperture"] ^ 2 / state["camera.shutter"]) - log2(state["camera.iso"] / ISO_BASE)
end

exposure.camera_block = {
	{"camera_mode", "int"},
	{"camera_iso", "float"},
	{"camera_aperture", "float"},
	{"camera_shutter", "float"},
}

function exposure.WriteCameraBlock(block)
	block.camera_mode = state["eye.enabled"] and -1 or exposure.modes[state["camera.mode"]]
	block.camera_iso = state["camera.iso"]
	block.camera_aperture = state["camera.aperture"]
	block.camera_shutter = state["camera.shutter"]
	return block
end

function exposure.GetCameraSettingsGLSL(block_name)
	local b = block_name
	return [[
		const float CAMERA_LOG_EXPOSURE_AT_EV0 = ]] .. exposure.LOG_EXPOSURE_AT_EV0 .. [[;

		vec3 camera_settings(float exposure) {
			float ev = CAMERA_LOG_EXPOSURE_AT_EV0 - log2(max(exposure, 1e-9));
			float light = exp2(ev);

			if (]] .. b .. [[.camera_mode < 0) return vec3(]] .. ISO_BASE .. [[.0, 64.0, 1.0 / 60.0);

			if (]] .. b .. [[.camera_mode == 3) return vec3(]] .. b .. [[.camera_iso, ]] .. b .. [[.camera_aperture, ]] .. b .. [[.camera_shutter);

			float n;
			float t;

			if (]] .. b .. [[.camera_mode == 1) {
				n = ]] .. b .. [[.camera_aperture;
				t = clamp(n * n / light, ]] .. SHUTTER_MIN .. [[, ]] .. SHUTTER_MAX .. [[);
			} else if (]] .. b .. [[.camera_mode == 2) {
				t = ]] .. b .. [[.camera_shutter;
				n = clamp(sqrt(light * t), ]] .. APERTURE_MIN .. [[, ]] .. APERTURE_MAX .. [[);
			} else {
				n = clamp(8.0 * exp2((ev - ]] .. log2(64 * 125) .. [[) / 4.0), ]] .. APERTURE_MIN .. [[, ]] .. APERTURE_MAX .. [[);
				t = clamp(n * n / light, ]] .. SHUTTER_MIN .. [[, ]] .. SHUTTER_MAX .. [[);
				n = clamp(sqrt(light * t), ]] .. APERTURE_MIN .. [[, ]] .. APERTURE_MAX .. [[);
			}

			return vec3(clamp(]] .. ISO_BASE .. [[.0 * n * n / (t * light), ]] .. ISO_MIN .. [[.0, ]] .. ISO_MAX .. [[.0), n, t);
		}
	]]
end

exposure.camera = {
	high_percent = 0.95,
	tau_brighten = 0.5,
	tau_darken = 1.5,
}
exposure.eye = {
	high_percent = 0.95,
	tau_brighten = 0.5,
	tau_darken = 1.5,
}
return exposure
