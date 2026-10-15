-- what the display gets in HDR output. The window here is SDR, so the render target is made to report scRGB (MODE=scrgb,
-- 1.0 = 80 nits) or HDR10 (MODE=hdr10, PQ BT.2020) and the blit's rgba16f output is read before it reaches the swapchain.
-- Matte plates in the sun at a range of exposures: the nits shown per plate against the exposed scene colour, the shoulder
-- (neutral tonemapper, peak = r_hdr_peak / r_hdr_paper_white) against a plain lua port, the PQ round trip.
-- luajit glw --3d --background --validate lua "import('test/harnesses/hdr/output.lua')"
-- MODE=scrgb|hdr10 PEAK=2000 PAPER=200 SUN=60 TONEMAP=neutral EVS=16,14,13,12,11,10,9
local test_scene = import("goluwa/render3d/test_scene.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local Shot = import("goluwa/render3d/shot.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local pvars = import("goluwa/cli/pvars.lua")
local mode = os.getenv("MODE") or "scrgb"
local peak_nits = test_scene.GetNumber("PEAK", 2000)
local paper = test_scene.GetNumber("PAPER", 200)
local sun_elevation = test_scene.GetNumber("SUN", 60)
local evs = {}

for v in (os.getenv("EVS") or "16,14,13,12,11,10,9"):gmatch("[^,]+") do
	evs[#evs + 1] = tonumber(v)
end

if not os.getenv("NOPATCH") then render.target.GetColorSpace = function()
	return mode == "hdr10" and "hdr10_st2084_ext" or "extended_srgb_linear_ext"
end end

for key, value in pairs{
	r_dither = false,
	r_eye = false,
	r_bloom_strength = 0,
	r_eye_night_vision = false,
	r_hdr_peak = peak_nits,
	r_hdr_paper_white = paper,
	r_camera_white_balance = 6500,
} do
	pvars.SetSession(key, value)
end

if os.getenv("TONEMAP") then pvars.SetSession("r_tonemapper", os.getenv("TONEMAP")) end

test_scene.Reset{sun = {elevation = sun_elevation, azimuth = 30}, clouds = {}, ground_fog_visibility = math.huge}
test_scene.Ground{size = 400, material = test_scene.Matte(0.18)}
local plates = {
	{"white", Color(0.9, 0.9, 0.9, 1)},
	{"orange", Color(0.9, 0.4, 0.05, 1)},
	{"blue", Color(0.1, 0.25, 0.8, 1)},
	{"black", Color(0.03, 0.03, 0.03, 1)},
}

for i, p in ipairs(plates) do
	p.pos = Vec3((i - 2.5) * 1.2, 0.05, 0)
	local material = test_scene.Matte(p[2], 1)
	material:SetSpecularMultiplier(0)
	test_scene.Box{name = p[1], pos = p.pos, size = Vec3(1, 0.1, 1), material = material}
end

-- the light on a flat plate: the sun times the air plus the sky's irradiance (LUT hemisphere), cd/m2 = albedo / pi * E
local function plate_luminance(albedo)
	local se = math.rad(sun_elevation)
	local sun = Vec3(-math.sin(math.rad(30)) * math.cos(se), math.sin(se), -math.cos(math.rad(30)) * math.cos(se))
	local t = atmosphere.GetTransmittance(sun, Vec3(0, 0, 0))
	local E = atmosphere.GetSunIlluminance()
	local c = atmosphere.SUN_COLOR
	local direct = {E * t.x * c.x * sun.y, E * t.y * c.y * sun.y, E * t.z * c.z * sun.y}
	return direct, albedo
end

-- neutral() from compute_helpers.lua
local function neutral(x, peak)
	local start, desaturation = 0.76, 0.15
	local m = math.max(x[1], x[2], x[3])

	if m <= start then return {x[1], x[2], x[3]} end

	local d = peak - start
	local new_peak = peak - d * d / (m + d - start)
	local out = {}
	local g = 1 - 1 / (desaturation * (m - new_peak) + 1)

	for c = 1, 3 do
		local v = x[c] * new_peak / m
		out[c] = v + (new_peak - v) * g
	end

	return out
end

local function pq_encode(nits)
	local y = math.min(math.max(nits / 10000, 0), 1) ^ 0.1593017578125
	return ((0.8359375 + 18.8515625 * y) / (1 + 18.6875 * y)) ^ 78.84375
end

local function pq_decode(n)
	local np = n ^ (1 / 78.84375)
	local l = math.max(np - 0.8359375, 0) / (18.8515625 - 18.6875 * np)
	return l ^ (1 / 0.1593017578125) * 10000
end

local views = {}

for i, ev in ipairs(evs) do
	views[i] = {Position = Vec3(0, 9, 3), Rotation = QuatDeg3(-72, 0, 0), FOV = math.rad(40), ExposureLock = ev, LocalExposure = 0}
end

local peak = peak_nits / paper
print(string.format("mode %s, peak %g nits, paper white %g nits (peak %.3f in paper white units), sun %g degrees", mode, peak_nits, paper, peak, sun_elevation))
Shot.Sequence(views, function(texture, info, index)
	local ev = evs[index]
	local out = render3d.pipelines.blit_compute:GetFramebuffer(1):GetAttachment(1):Download()
	local camera = import("goluwa/render3d/camera3d.lua").New()
	camera:SetFOV(views[index].FOV)
	camera:SetPosition(views[index].Position)
	camera:SetRotation(views[index].Rotation)
	camera:SetViewport(Rect(0, 0, out.width, out.height))
	-- exposed = luminance * 0.18 * 8 / 2^ev, see ExposureLock in the colorchecker harness
	local scale = 0.18 * 8 / 2 ^ ev
	local source = post_source.GetSceneSourceTexture({name = "blit_compute"}):Download()
	local pre_exposure = post_source.GetExposureTexture():Download():GetPixelFloat(0, 0) / post_source.PRE_EXPOSURE_HEADROOM
	if os.getenv("DEBUG_POS") then
		for _, xy in ipairs{{100, 100}, {662, 540}, {1257, 540}} do
			print("    pixel", xy[1], xy[2], "blit out", out:GetPixelFloat(xy[1], xy[2]), "screenshot", texture:GetPixel(xy[1], xy[2]))
		end
	end

	print(string.format("EV %g (exposed = cd/m2 * %.3e)", ev, scale))

	for _, p in ipairs(plates) do
		local pos = camera:WorldPositionToScreen(p.pos + Vec3(0, 0.05, 0), out.width, out.height, true)
		local sum = {0, 0, 0}
		local n = 0

		if os.getenv("DEBUG_POS") then print("    pos", p[1], pos.x, pos.y, out.width, out.height) end

		for dy = -6, 6 do
			for dx = -6, 6 do
				local r, g, b = out:GetPixelFloat(math.floor(pos.x) + dx, math.floor(pos.y) + dy)
				sum[1], sum[2], sum[3], n = sum[1] + r, sum[2] + g, sum[3] + b, n + 1
			end
		end

		local shown = {sum[1] / n, sum[2] / n, sum[3] / n}
		local nits

		if mode == "scrgb" then
			nits = {shown[1] * 80, shown[2] * 80, shown[3] * 80}
		else
			-- PQ encoded BT.2020, back to linear BT.2020 and to BT.709
			local l2020 = {pq_decode(shown[1]), pq_decode(shown[2]), pq_decode(shown[3])}
			nits = {
				1.6605 * l2020[1] - 0.5876 * l2020[2] - 0.0728 * l2020[3],
				-0.1246 * l2020[1] + 1.1329 * l2020[2] - 0.0083 * l2020[3],
				-0.0182 * l2020[1] - 0.1006 * l2020[2] + 1.1187 * l2020[3],
			}
		end

		local sum_scene = {0, 0, 0}

		for dy = -6, 6 do
			for dx = -6, 6 do
				local r, g, b = source:GetPixelFloat(math.floor(pos.x) + dx, math.floor(pos.y) + dy)
				sum_scene[1], sum_scene[2], sum_scene[3] = sum_scene[1] + r, sum_scene[2] + g, sum_scene[3] + b
			end
		end

		-- the scene colour before exposure is absolute cd/m2 times the pre exposure; exposed is what the tonemapper gets
		local exposed = {}

		for c = 1, 3 do
			exposed[c] = sum_scene[c] / n / pre_exposure * scale
		end

		local expected = neutral(exposed, peak)
		print(string.format("  %-7s shown %7.1f %7.1f %7.1f nits   exposed %.3f %.3f %.3f   neutral() -> %7.1f %7.1f %7.1f nits   shown / expected %.3f %.3f %.3f", p[1], nits[1], nits[2], nits[3], exposed[1], exposed[2], exposed[3], expected[1] * paper, expected[2] * paper, expected[3] * paper, nits[1] / (expected[1] * paper), nits[2] / (expected[2] * paper), nits[3] / (expected[3] * paper)))
	end
	if os.getenv("DEBUG_POS") and index == 1 then texture:SaveWithoutAlpha("tmp/hdr_view.png") end
end, {settle = 5}, function()
	system.ShutDown(0)
end)
