local pvars = import("goluwa/cli/pvars.lua")
local exposure = {}
-- Exposure is one number, EV100. A camera reaches it with its settings: EV100 = log2(N^2 / t) - log2(ISO / 100),
-- for the f-number N, the shutter time t and the sensitivity ISO. The eye has no such settings and gets its own table.
-- What both give is how much the scene's luminance is multiplied by before the tonemapper (see passes/blit.lua).
pvars.StartGroup("camera", {store = false})
local mode = pvars.Setup2{
	key = "r_camera_mode",
	default = "program",
	enums = {"program", "aperture_priority", "shutter_priority", "manual"},
	help = "program picks aperture, shutter and ISO within their limits, the priority modes keep the aperture or the shutter you set and pick the rest, manual keeps all three (and then the exposure does not follow the scene)",
}
local iso = pvars.Setup2{
	key = "r_camera_iso",
	default = 100,
	min = 12,
	max = 409600,
	help = "sensitivity in manual mode",
}
local iso_min = pvars.Setup2{
	key = "r_camera_iso_min",
	default = 100,
	min = 12,
	max = 409600,
	help = "lowest ISO auto exposure picks",
}
local iso_max = pvars.Setup2{
	key = "r_camera_iso_max",
	default = 6400,
	min = 12,
	max = 409600,
	help = "highest ISO auto exposure picks",
}
local aperture = pvars.Setup2{
	key = "r_camera_aperture",
	default = 8,
	min = 0.7,
	max = 64,
	help = "f-number in manual and aperture priority mode",
}
local aperture_min = pvars.Setup2{
	key = "r_camera_aperture_min",
	default = 1.4,
	min = 0.7,
	max = 64,
	help = "smallest f-number (widest opening) program mode picks",
}
local aperture_max = pvars.Setup2{
	key = "r_camera_aperture_max",
	default = 16,
	min = 0.7,
	max = 64,
	help = "largest f-number (smallest opening) program mode picks",
}
local shutter = pvars.Setup2{
	key = "r_camera_shutter",
	default = 1 / 125,
	min = 1 / 100000,
	max = 60,
	help = "shutter time in seconds in manual and shutter priority mode",
}
local shutter_min = pvars.Setup2{
	key = "r_camera_shutter_min",
	default = 1 / 8000,
	min = 1 / 100000,
	max = 60,
	help = "shortest shutter time auto exposure picks, in seconds",
}
local shutter_max = pvars.Setup2{
	key = "r_camera_shutter_max",
	default = 1 / 30,
	min = 1 / 100000,
	max = 60,
	help = "longest shutter time auto exposure picks, in seconds",
}
local compensation = pvars.Setup2{
	key = "r_camera_compensation",
	default = 0,
	min = -10,
	max = 10,
	help = "exposure compensation in stops, how much brighter than the meter the camera exposes",
}
local white_balance = pvars.Setup2{
	key = "r_camera_white_balance",
	default = 6500,
	min = 0,
	max = 25000,
	help = "colour temperature in kelvin of the light the camera takes for white, 6500 (D65, the display's white) leaves the colours as they are, 5500 is daylight, 0 estimates it from the frame (gray world)",
}
local white_balance_tint = pvars.Setup2{
	key = "r_camera_white_balance_tint",
	default = 0,
	min = -1,
	max = 1,
	help = "how green (+) or magenta (-) the light is that the white balance takes for white, on top of its colour temperature",
}
pvars.EndGroup()

local function log2(x)
	return math.log(x) / math.log(2)
end

local function settings_to_ev(n, t, s)
	return log2(n * n / t) - log2(s / 100)
end

function exposure.GetCameraCompensation()
	return compensation:Get()
end

function exposure.GetCameraWhiteBalance()
	return white_balance:Get()
end

function exposure.GetCameraWhiteBalanceTint()
	return white_balance_tint:Get()
end

function exposure.GetCameraMode()
	return mode:Get()
end

-- what the manual settings expose for
function exposure.GetManualEV()
	return settings_to_ev(aperture:Get(), shutter:Get(), iso:Get())
end

-- the darkest and the brightest scene, as EV100, that the camera can expose properly with the settings it may change
function exposure.GetCameraRange()
	local m = mode:Get()
	local n_lo, n_hi = aperture_min:Get(), aperture_max:Get()
	local t_lo, t_hi = shutter_min:Get(), shutter_max:Get()

	if m == "aperture_priority" then
		n_lo, n_hi = aperture:Get(), aperture:Get()
	elseif m == "shutter_priority" then
		t_lo, t_hi = shutter:Get(), shutter:Get()
	end

	local lo = settings_to_ev(n_lo, t_hi, iso_max:Get())
	local hi = settings_to_ev(n_hi, t_lo, iso_min:Get())
	return lo, math.max(lo, hi)
end

-- one way for the camera to reach ev: the program line moves aperture and shutter evenly away from f/8 and 1/125, and the ISO
-- makes up what the limits do not allow. Only for reading out, the image depends on ev alone
function exposure.DescribeCamera(ev)
	local m = mode:Get()

	if m == "manual" then return iso:Get(), aperture:Get(), shutter:Get() end

	local s = iso_min:Get()
	-- log2(N^2 / t) at that ISO
	local light = ev + log2(s / 100)
	local n, t

	if m == "aperture_priority" then
		n = aperture:Get()
		t = math.clamp(n * n / 2 ^ light, shutter_min:Get(), shutter_max:Get())
	elseif m == "shutter_priority" then
		t = shutter:Get()
		n = math.clamp(math.sqrt(2 ^ light * t), aperture_min:Get(), aperture_max:Get())
	else
		local delta = light - log2(64 * 125)
		n = math.clamp(8 * 2 ^ (delta / 4), aperture_min:Get(), aperture_max:Get())
		t = math.clamp(n * n / 2 ^ light, shutter_min:Get(), shutter_max:Get())
		n = math.clamp(math.sqrt(2 ^ light * t), aperture_min:Get(), aperture_max:Get())
	end

	s = math.clamp(100 * 2 ^ (log2(n * n / t) - ev), iso_min:Get(), iso_max:Get())
	return s, n, t
end

-- how the metering and the adaptation behave. The meter is an averaging one: the centre weighted mean of the frame's luminance
-- (linear light, ISO 2720) with every pixel held at the high_percent percentile of the histogram, so a small highlight does
-- not pull it. tau: seconds to adapt to a brighter and to a darker scene
exposure.camera = {
	high_percent = 0.95,
	tau_brighten = 0.5,
	tau_darken = 1.5,
}
-- what the eye can adapt to as EV100 (darkest rod vision to a sunlit snow field) and how it meters
exposure.eye = {
	min_ev = -4,
	max_ev = 18,
	high_percent = 0.95,
	tau_brighten = 0.5,
	tau_darken = 1.5,
}
return exposure
