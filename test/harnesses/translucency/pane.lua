-- A glass pane against emissive walls, read in absolute radiance. The camera looks along -z at a pane tilted by ANGLE degrees
-- that covers the left half of the view; an emissive wall behind the pane (the transmitted light) and one behind the
-- camera (the reflected light) of the same luminance L, each switched on alone, and the right half of the view is the
-- bare front wall. Transmission is the pane's pixel over the bare wall's, reflection the pixel over L (the reflecting wall is
-- seen mirrored, which needs the traced reflection). Compared with the exact Fresnel equations, one interface (what the pass
-- computes) and two (a pane). luajit glw --3d --background --validate lua "import('test/harnesses/translucency/pane.lua')"
-- ANGLE=0 (degrees, one per process) WALLS=front|back|both IOR=1.5 ROUGHNESS=0.001 EV=8 PVARS=k=v,...
-- for a in 0 40 60 75; do for w in front back; do ANGLE=$a WALLS=$w luajit glw --3d --background --validate lua "import('test/harnesses/translucency/pane.lua')" 2>&1 | grep PANE; done; done
local test_scene = import("goluwa/render3d/test_scene.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local pvars = import("goluwa/cli/pvars.lua")
local angle = test_scene.GetNumber("ANGLE", 0)
local ior = test_scene.GetNumber("IOR", 1.5)
local roughness = test_scene.GetNumber("ROUGHNESS", 0.001)
local ev = test_scene.GetNumber("EV", 8)
local fov = math.rad(40)
local PANE_Z, FRONT_Z, BACK_Z = -3, -7, 3
-- the sampled pixel looks left of the axis by this much of the half width, the pane is centred where its ray arrives
local PIXEL = 0.35
local half_width = math.tan(fov / 2) * (16 / 9)
local hit_x = (PIXEL * 2 - 1) * half_width * math.abs(PANE_Z)

for key, value in pairs{r_dither = false, r_eye = false, r_bloom_strength = 0, r_camera_white_balance = 6500} do
	pvars.SetSession(key, value)
end

for pair in (os.getenv("PVARS") or ""):gmatch("[^,]+") do
	local k, v = pair:match("^([^=]+)=(.*)$")

	if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end

	pvars.SetSession(k, v)
end

test_scene.Reset{sun = {elevation = -40, azimuth = 0}, clouds = {}, ground_fog_visibility = math.huge}
-- nearly black reflectors with a strong emission, so they emit L and bounce almost nothing onto each other
local WALL_ALBEDO = 0.03
local function emitter(strength)
	return shapes.Material{
		Color = Color(WALL_ALBEDO, WALL_ALBEDO, WALL_ALBEDO, 1),
		Roughness = 1,
		Metallic = 0,
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 1, 1, strength / WALL_ALBEDO),
	}
end

local function fresnel(cos_i, n)
	local sin_t = math.sqrt(math.max(1 - cos_i * cos_i, 0)) / n
	local cos_t = math.sqrt(1 - sin_t * sin_t)
	local rs = ((cos_i - n * cos_t) / (cos_i + n * cos_t)) ^ 2
	local rp = ((cos_t - n * cos_i) / (cos_t + n * cos_i)) ^ 2
	return 0.5 * (rs + rp)
end

local f0 = ((ior - 1) / (ior + 1)) ^ 2
local L = render3d.EMISSIVE_REFERENCE_LUMINANCE
local walls = os.getenv("WALLS") or "both"
local front_strength = (walls == "front" or walls == "both") and 1 or 0
local back_strength = (walls == "back" or walls == "both") and 1 or 0
-- shapes.Box is axis aligned along its Size; the wall behind the camera faces +z, the one in front faces -z
test_scene.Box{name = "front", pos = Vec3(0, 0, FRONT_Z), size = Vec3(40, 40, 0.1), material = emitter(front_strength)}
-- the surround, a room round the pane without its front wall, is what the pane reflects
for i, wall in ipairs{
	{Vec3(0, 0, BACK_Z), Vec3(30, 30, 0.1)},
	{Vec3(-8, 0, -3), Vec3(0.1, 30, 30)},
	{Vec3(8, 0, -3), Vec3(0.1, 30, 30)},
	{Vec3(0, -4, -3), Vec3(30, 0.1, 30)},
	{Vec3(0, 4, -3), Vec3(30, 0.1, 30)},
} do
	test_scene.Box{name = "surround" .. i, pos = wall[1], size = wall[2], material = emitter(back_strength)}
end

-- the pane is centred where the sampled ray arrives, tilted about y
test_scene.Box{
	name = "pane",
	pos = Vec3(hit_x, 0, PANE_Z),
	rotation = QuatDeg3(0, angle, 0),
	size = Vec3(1.2, 4, 0.01),
	material = shapes.Material{Refraction = 1, IndexOfRefraction = ior, Roughness = roughness, Metallic = 0, ColorMultiplier = Color(1, 1, 1, 1)},
}

test_scene.WhenReady(function()
	local Shot = import("goluwa/render3d/shot.lua")
	Shot.Capture({Position = Vec3(0, 0, 0), Rotation = QuatDeg3(0, 0, 0), FOV = fov, ExposureLock = ev, LocalExposure = 0}, function(texture, info)
		local source = post_source.GetSceneSourceTexture({name = "blit_compute"}):Download()
		local pre = post_source.GetExposureTexture():Download():GetPixelFloat(0, 0) / post_source.PRE_EXPOSURE_HEADROOM
		local w, h = source.width, source.height
		local function mean(x0)
			local sum, n = 0, 0

			for dy = -6, 6 do
				for dx = -6, 6 do
					local r, g, b = source:GetPixelFloat(math.floor(x0 * w) + dx, math.floor(h / 2) + dy)
					sum, n = sum + (0.2126 * r + 0.7152 * g + 0.0722 * b) / pre, n + 1
				end
			end

			return sum / n
		end

		-- the pixel at 35 percent of the width looks left of the axis, the bare wall is at 65 percent
		local half = math.tan(fov / 2) * w / h
		local dir = Vec3((0.35 * 2 - 1) * half, 0, -1):GetNormalized()
		local normal = Vec3(math.sin(math.rad(angle)), 0, math.cos(math.rad(angle)))
		local cos_i = math.abs(dir:GetDot(normal))
		local left, right = mean(0.35), mean(0.65)
		local f = fresnel(cos_i, ior)
		local schlick = f0 + (1 - f0) * (1 - cos_i) ^ 5
		local pane_t, pane_r = (1 - f) ^ 2 / (1 - f * f), f + (1 - f) ^ 2 * f / (1 - f * f)
		print(string.format(
			"PANE walls %s angle %2d incidence %4.1f deg: pixel %8.0f bare wall %8.0f | pixel/L %.4f, pixel/bare %.4f | one interface T %.4f R %.4f (schlick %.4f) two interfaces T %.4f R %.4f exact F %.4f",
			walls, angle, math.deg(math.acos(cos_i)), left, right, left / L, left / math.max(right, 1e-9), 1 - schlick, schlick, schlick, pane_t, pane_r, f
		))
		system.ShutDown(0)
	end, {settle = 3, max_settle = 6})
end)
