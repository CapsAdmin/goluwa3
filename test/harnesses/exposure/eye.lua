-- the eye model (r_eye on): uniform emissive fields of known luminance in a dark scene, adapted, and what the display shows
-- (the SDR output decoded to linear; the neutral tonemapper leaves everything below 0.76 as it is) against the curve's
-- own definition in passes/blit.lua: the exposed grey is 0.18 * 2^stops(EV), stops the visibility matching response
-- (luminance over its threshold, Ward Larson et al. 1997's threshold versus intensity for rods and cones, mesopic blend,
-- Ward 1994 above EV 9) relative to the reference at EV 9 and to EV 15.
-- luajit glw --3d --background --validate lua "import('test/harnesses/exposure/eye.lua')"
-- LUMINANCES=0.001,0.01,0.1,1,10,100,1000,10000,100000 SETTLE=12 (seconds per field) PVARS=k=v
local test_scene = import("goluwa/render3d/test_scene.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local View = import("goluwa/render3d/view.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local pvars = import("goluwa/cli/pvars.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local EMISSIVE_REFERENCE = 2000

for key, value in pairs{
	r_dither = false,
	r_eye = true,
	r_bloom_strength = 0,
	r_eye_night_vision = false,
	r_eye_local_shadows = 0,
	r_eye_local_highlights = 0,
	ddgi_strength = 0,
	r_pass_reflections = false,
	r_pass_ambient_occlusion = false,
	r_camera_white_balance = 6500,
} do
	pvars.SetSession(key, value)
end

for pair in (os.getenv("PVARS") or ""):gmatch("[^,]+") do
	local k, v = pair:match("^([^=]+)=(.*)$")

	if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end

	pvars.SetSession(k, v)
end

local luminances = {}

for v in (os.getenv("LUMINANCES") or "0.001,0.01,0.1,1,10,100,1000,10000,100000"):gmatch("[^,]+") do
	luminances[#luminances + 1] = tonumber(v)
end

-- the curve of passes/blit.lua, in lua
local function log10(x) return math.log(x) / math.log(10) end
local function log2(x) return math.log(x) / math.log(2) end
local function smoothstep(a, b, x)
	local t = math.min(math.max((x - a) / (b - a), 0), 1)
	return t * t * (3 - 2 * t)
end
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
local function eye_response(L)
	local cones = smoothstep(-2.3, 0.7, log10(L))
	return cones * L / cone_threshold(L) + (1 - cones) * L / rod_threshold(L)
end
local function cones_response(L) return L / cone_threshold(L) end
local function ward(L) return ((1.219 + 50 ^ 0.4) / (1.219 + L ^ 0.4)) ^ 2.5 * L end
local reference = 2 ^ (9 - 3)
local EV_MIN, STEP, COUNT = -10, 0.5, 65
local function build(response)
	local curve = {}
	for i = 1, COUNT do
		local ev = EV_MIN + (i - 1) * STEP
		local L = 2 ^ (ev - 3)
		curve[i] = ev >= 9 and log2(ward(L) / ward(reference)) or log2(response(L) / response(reference))
	end
	for i = COUNT - 1, 1, -1 do curve[i] = math.min(curve[i], curve[i + 1]) end
	local anchor = curve[(15 - EV_MIN) / STEP + 1]
	for i = 1, COUNT do curve[i] = curve[i] - anchor end
	return curve
end
local rods, cones = build(eye_response), build(cones_response)
local rod_adaptation = pvars.Get("r_eye_rod_adaptation")

local function stops(ev)
	local x = math.min(math.max((ev - EV_MIN) / STEP, 0), COUNT - 1)
	local i = math.min(math.floor(x), COUNT - 2)
	local f = x - i
	local r = rods[i + 1] + (rods[i + 2] - rods[i + 1]) * f
	local c = cones[i + 1] + (cones[i + 2] - cones[i + 1]) * f
	return c + (r - c) * rod_adaptation
end

local function srgb_to_linear(v)
	v = v / 255
	return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
end

local DISTANCE, FOV = 10, math.rad(60)
local half_h = math.tan(FOV / 2) * DISTANCE
local half_w = half_h * 16 / 9
local index, frame_count, view = 0, 0, nil
local settle_frames = math.floor(test_scene.GetNumber("SETTLE", 12) * 60)
local min_ev, max_ev = 0, 0
print("uniform field   metered EV   adapted EV    exposed grey (display linear)   curve says     ratio")

local function build_scene(luminance)
	test_scene.Reset{sun = {elevation = -30, azimuth = 0}, clouds = {}, ground_fog_visibility = math.huge}
	local material = shapes.Material{Color = Color(1, 1, 1, 1), Roughness = 1, Metallic = 0, AlbedoAlphaIsEmissive = true, EmissiveMultiplier = Color(1, 1, 1, luminance / EMISSIVE_REFERENCE)}
	test_scene.Box{name = "wall", pos = Vec3(0, 0, -DISTANCE), size = Vec3(half_w * 2.2, half_h * 2.2, 0.1), material = material}
end

event.AddListener("PostUpdate", "eye_harness", function()
	if not view then
		view = View.New{Priority = 100, Position = Vec3(0, 0, 0), Rotation = QuatDeg3(0, 0, 0), FOV = FOV, LocalExposure = 0}:Activate()
	end

	frame_count = frame_count + 1

	if index > 0 and frame_count == settle_frames then
		local exposure_img = post_source.GetExposureTexture():Download()
		local _, metered, adapted = exposure_img:GetPixelFloat(0, 0)
		local luminance = luminances[index]

		Screenshot(function(texture)
			local r, g, b = texture:GetPixel(math.floor(texture.width / 2), math.floor(texture.height / 2))
			local shown = 0.2126 * srgb_to_linear(r) + 0.7152 * srgb_to_linear(g) + 0.0722 * srgb_to_linear(b)
			local ev = math.log(luminance * 100 / 12.5) / math.log(2)
			local clamped = math.min(math.max(ev - stops(ev), exposure_model.eye.min_ev), exposure_model.eye.max_ev)
			-- the shader: ev = clamp(metered - stops(metered)), exposed = L * 0.18 * 8 / 2^ev
			local expected = luminance * 0.18 * 8 / 2 ^ clamped
			print(string.format("  %9.4g cd/m2   %6.2f      %6.2f           %.5f                    %.5f      %.3f", luminance, metered, adapted, shown, math.min(expected, 0.76), shown / math.min(expected, 0.76)))
		end)
	end

	if frame_count >= settle_frames + 5 or index == 0 then
		index = index + 1
		frame_count = 0

		if index > #luminances then
			event.RemoveListener("PostUpdate", "eye_harness")
			system.ShutDown(0)

			return
		end

		build_scene(luminances[index])
	end
end)
