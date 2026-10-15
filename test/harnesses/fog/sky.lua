-- the ground fog against a path tracer. The camera stands at the atmosphere's eye height (1.75 m) in an empty scene and
-- looks at the sky at elevations and azimuths from the sun; the composited scene colour there (the sky seen through the
-- fog layer, absolute cd/m2 before exposure) against spectral.lua's Monte Carlo of the same air plus a layer of grey fog
-- (extinction ext0 exp(-h / H) with the engine's top fade, Henyey-Greenstein g 0.6, single scattering albedo 1), every
-- order of scattering.
-- luajit glw --3d --background --validate lua "import('test/harnesses/fog/sky.lua')"
-- FOG=<visibility m, 140000 is the default, 0 no fog layer> SUN=60 MC=6000 ELEVS=2,5,10,25,60 AZ=0,90,180 EV=14
-- ORDERS=1,2 also prints the reference limited to that many scatterings
local test_scene = import("goluwa/render3d/test_scene.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local weather = import("goluwa/render3d/weather.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local Shot = import("goluwa/render3d/shot.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local pvars = import("goluwa/cli/pvars.lua")
local spectral = import("test/harnesses/sky/spectral.lua")
local sun_elevation = test_scene.GetNumber("SUN", 60)
local fog_visibility = test_scene.GetNumber("FOG", 140000)
local paths = math.floor(test_scene.GetNumber("MC", 6000))
local ev = test_scene.GetNumber("EV", 14)
local elevations, azimuths, orders = {}, {}, {}

for v in (os.getenv("ORDERS") or ""):gmatch("[^,]+") do
	orders[#orders + 1] = tonumber(v)
end

for v in (os.getenv("ELEVS") or "2,5,10,25,60"):gmatch("[^,]+") do
	elevations[#elevations + 1] = tonumber(v)
end

for v in (os.getenv("AZ") or "0,90,180"):gmatch("[^,]+") do
	azimuths[#azimuths + 1] = tonumber(v)
end

pvars.SetSession("r_dither", false)
pvars.SetSession("r_eye", false)
pvars.SetSession("r_bloom_strength", 0)
pvars.SetSession("r_camera_white_balance", 6500)
for pair in (os.getenv("PVARS") or ""):gmatch("[^,]+") do local k, v = pair:match("^([^=]+)=(.*)$") if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end pvars.SetSession(k, v) end
test_scene.Reset{sun = {elevation = sun_elevation, azimuth = 0}, clouds = {}, ground_fog_visibility = fog_visibility == 0 and math.huge or fog_visibility}
local ext0 = atmosphere.GetGroundFogExtinction()
local aerosol_ext = math.max(-math.log(0.02) / (atmosphere.GetAerosolVisibility() / 1000) - 0.0135, 0)
local aerosol = {
	aod = aerosol_ext * (1.2 + 0.07 * 8),
	alpha = 1.3,
	ssa = 0.95,
	g = 0.7,
	h = 1.2,
	fog = ext0 > 0 and {ext = ext0, h = 0.28, top = 1.1, soft = 0.3, g = 0.6} or nil,
}
local views, directions = {}, {}

for _, e in ipairs(elevations) do
	for _, a in ipairs(azimuths) do
		directions[#directions + 1] = {e, a}
		views[#views + 1] = {Position = Vec3(0, 0, 0), Rotation = QuatDeg3(e, a, 0), FOV = math.rad(8), ExposureLock = ev, LocalExposure = 0}
	end
end

print(string.format("sun %g degrees, ground fog visibility %s (extinction %.4g /km at the ground), aerosol visibility %g m, %d paths per wavelength", sun_elevation, fog_visibility == 0 and "none" or tostring(fog_visibility), ext0, atmosphere.GetAerosolVisibility(), paths))
print(" elev  az    engine Y    MC Y     engine / MC     engine rgb / Y         MC rgb / Y")
Shot.Sequence(views, function(texture, info, index)
	local view = {e = directions[index][1], a = directions[index][2]}
	local source = post_source.GetSceneSourceTexture({name = "blit_compute"}):Download()
	local pre = post_source.GetExposureTexture():Download():GetPixelFloat(0, 0) / post_source.PRE_EXPOSURE_HEADROOM
	local sum, n = {0, 0, 0}, 0

	for dy = -10, 10 do
		for dx = -10, 10 do
			local r, g, b = source:GetPixelFloat(math.floor(source.width / 2) + dx, math.floor(source.height / 2) + dy)
			sum[1], sum[2], sum[3], n = sum[1] + r, sum[2] + g, sum[3] + b, n + 1
		end
	end

	local er, eg, eb = sum[1] / n / pre, sum[2] / n / pre, sum[3] / n / pre
	local se = math.rad(sun_elevation)
	local el, az = math.rad(view.e), math.rad(view.a)
	local sun = {math.cos(se), math.sin(se), 0}
	local dir = {math.cos(el) * math.cos(az), math.sin(el), math.cos(el) * math.sin(az)}
	local r, g, b = spectral.Radiance(sun, dir, aerosol, paths, 0.27, atmosphere.GetSunIlluminance(), 100)
	local c = atmosphere.SUN_COLOR
	r, g, b = r * c.x, g * c.y, b * c.z
	local ey = 0.2126 * er + 0.7152 * eg + 0.0722 * eb
	local my = 0.2126 * r + 0.7152 * g + 0.0722 * b
	local by_order = ""

	for _, order in ipairs(orders) do
		local lr, lg, lb = spectral.Radiance(sun, dir, aerosol, paths, 0.27, atmosphere.GetSunIlluminance(), order)
		by_order = by_order .. string.format("  order<=%d %7.0f", order, 0.2126 * lr * c.x + 0.7152 * lg * c.y + 0.0722 * lb * c.z)
	end

	print(string.format("  %3g  %3g   %8.0f  %8.0f      %.3f        %.3f %.3f %.3f     %.3f %.3f %.3f%s", view.e, view.a, ey, my, ey / my, er / ey, eg / ey, eb / ey, r / my, g / my, b / my, by_order))
end, {settle = 3}, function()
	system.ShutDown(0)
end)
