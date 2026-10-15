-- the exposure meter against what a reflected light meter reads. Emissive walls of known luminance fill the view in a
-- dark scene (no sun, no ground, ddgi, reflections and ambient occlusion off); the frame's own luminance map (the scene
-- before exposure, absolute cd/m2, sampled on the meter's 160 x 90 grid) is the ground truth, and the engine's metered EV
-- (the g channel of the exposure texture) is compared with
--   the centre weighted arithmetic mean luminance (what an averaging meter integrates, ISO 2720: EV100 = log2(L S / K), K = 12.5),
--   the same with every pixel held at the 95th percentile (what the engine meters: a small highlight does not pull it),
--   the centre weighted geometric mean (log average, what many auto exposures use).
-- luajit glw --3d --background --validate lua "import('test/harnesses/exposure/meter.lua')"
-- CASES=uniform,split4,split16,split64,spot_bright,spot_dark,highlight,sky_ground FRAMES=30
local test_scene = import("goluwa/render3d/test_scene.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local View = import("goluwa/render3d/view.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local pvars = import("goluwa/cli/pvars.lua")
local EMISSIVE_REFERENCE = 2000

for key, value in pairs{
	r_dither = false,
	r_eye = false,
	r_bloom_strength = 0,
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

-- a case is a background luminance and rectangles {u0, v0, u1, v1, luminance} in the view (0, 0 top left)
local base = 2000
local cases = {
	uniform = {base, {}},
	split4 = {base, {{0, 0, 0.5, 1, base / 4}}},
	split16 = {base, {{0, 0, 0.5, 1, base / 16}}},
	split64 = {base, {{0, 0, 0.5, 1, base / 64}}},
	spot_bright = {base / 4, {{0.4, 0.35, 0.6, 0.65, base * 4}}},
	spot_dark = {base, {{0.4, 0.35, 0.6, 0.65, base / 64}}},
	highlight = {base / 2, {{0.7, 0.2, 0.74, 0.28, base * 100}}},
	sky_ground = {base * 2, {{0, 0.55, 1, 1, base / 16}}},
}
local order = {"uniform", "split4", "split16", "split64", "spot_bright", "spot_dark", "highlight", "sky_ground"}
local wanted = {}

for v in (os.getenv("CASES") or table.concat(order, ",")):gmatch("[^,]+") do
	wanted[#wanted + 1] = v
end

local frames = test_scene.GetNumber("FRAMES", 30)
local DISTANCE = 10
local FOV = math.rad(60)
local ASPECT = 16 / 9
local half_h = math.tan(FOV / 2) * DISTANCE
local half_w = half_h * ASPECT

local function emitter(luminance)
	return shapes.Material{
		Color = Color(1, 1, 1, 1),
		Roughness = 1,
		Metallic = 0,
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 1, 1, luminance / EMISSIVE_REFERENCE),
	}
end

local function smoothstep(a, b, x)
	local t = math.min(math.max((x - a) / (b - a), 0), 1)
	return t * t * (3 - 2 * t)
end

local GRID_X, GRID_Y = 160, 90
local view
local case_index = 0
local frame = 0
local wait_frames = 0

local function build(name)
	test_scene.Reset{sun = {elevation = -30, azimuth = 0}, clouds = {}, ground_fog_visibility = math.huge}
	local case = cases[name]
	test_scene.Box{name = "wall", pos = Vec3(0, 0, -DISTANCE), size = Vec3(half_w * 2.2, half_h * 2.2, 0.1), material = emitter(case[1])}

	for i, r in ipairs(case[2]) do
		local cx, cy = (r[1] + r[3]) / 2, (r[2] + r[4]) / 2
		local w, h = r[3] - r[1], r[4] - r[2]
		test_scene.Box{
			name = "rect" .. i,
			pos = Vec3((cx * 2 - 1) * half_w, (1 - cy * 2) * half_h, -DISTANCE + 0.2),
			size = Vec3(w * half_w * 2, h * half_h * 2, 0.1),
			material = emitter(r[5]),
		}
	end
end

local function measure(name)
	local source = post_source.GetSceneSourceTexture({name = "blit_compute"}):Download()
	local exposure_img = post_source.GetExposureTexture():Download()
	local exposure, metered_ev = exposure_img:GetPixelFloat(0, 0)
	local pre = exposure / post_source.PRE_EXPOSURE_HEADROOM
	-- the exposure texture's g is the metered EV; the scene was pre exposed with the frame before's exposure, which the meter undid
	local sum_w, sum_arith, sum_log = 0, 0, 0
	for n = 0, GRID_X * GRID_Y - 1 do
		local u, v = ((n % GRID_X) + 0.5) / GRID_X, (math.floor(n / GRID_X) + 0.5) / GRID_Y
		local px, py = math.min(source.width - 1, math.floor(u * source.width)), math.min(source.height - 1, math.floor(v * source.height))
		local r, g, b = source:GetPixelFloat(px, py)
		local luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / pre
		local rr = math.sqrt((u * 2 - 1) ^ 2 + (v * 2 - 1) ^ 2)
		local w = 1 + 3 * (1 - smoothstep(0.2, 1.0, rr))
		sum_w = sum_w + w
		sum_arith = sum_arith + w * luma
		sum_log = sum_log + w * math.log(math.max(luma, 1e-6)) / math.log(2)
	end

	local function ev(luminance)
		return math.log(luminance * 100 / 12.5) / math.log(2)
	end

	-- the arithmetic mean with every pixel clamped at the 95th percentile of the luminance (weighted): an averaging meter
	-- that is not pulled by a small highlight
	local samples = {}

	for n = 0, GRID_X * GRID_Y - 1 do
		local u, v = ((n % GRID_X) + 0.5) / GRID_X, (math.floor(n / GRID_X) + 0.5) / GRID_Y
		local px, py = math.min(source.width - 1, math.floor(u * source.width)), math.min(source.height - 1, math.floor(v * source.height))
		local r, g, b = source:GetPixelFloat(px, py)
		local rr = math.sqrt((u * 2 - 1) ^ 2 + (v * 2 - 1) ^ 2)
		samples[#samples + 1] = {(0.2126 * r + 0.7152 * g + 0.0722 * b) / pre, 1 + 3 * (1 - smoothstep(0.2, 1.0, rr))}
	end

	table.sort(samples, function(a, b) return a[1] < b[1] end)
	local running, p95 = 0, samples[#samples][1]

	for _, sample in ipairs(samples) do
		running = running + sample[2]

		if running >= sum_w * 0.95 then p95 = sample[1] break end
	end

	local clamped = 0

	for _, sample in ipairs(samples) do
		clamped = clamped + sample[2] * math.min(sample[1], p95)
	end

	local clamped_ev = ev(clamped / sum_w)
	local arith = ev(sum_arith / sum_w)
	local geo = sum_log / sum_w + 3
	print(string.format("  %-12s engine %6.2f   arithmetic %6.2f (%+.2f)   clamped at p95 %6.2f (%+.2f)   geometric %6.2f (%+.2f)", name, metered_ev, arith, metered_ev - arith, clamped_ev, metered_ev - clamped_ev, geo, metered_ev - geo))
end

print("metered EV100 (engine), against the centre weighted arithmetic mean (an averaging meter), the same held at the 95th percentile, and the geometric mean; differences in stops")
event.AddListener("FrameEnd", "meter_harness", function()
	frame = frame + 1

	if not view then
		view = View.New{Priority = 100, Position = Vec3(0, 0, 0), Rotation = QuatDeg3(0, 0, 0), FOV = FOV, LocalExposure = 0}:Activate()
	end

	if wait_frames > 0 then
		wait_frames = wait_frames - 1

		if wait_frames == 0 then
			measure(wanted[case_index])

			if case_index >= #wanted then
				event.RemoveListener("FrameEnd", "meter_harness")
				system.ShutDown(0)
			end
		end

		return
	end

	case_index = case_index + 1
	build(wanted[case_index])
	wait_frames = frames
end)
