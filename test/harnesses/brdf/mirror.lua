-- a smooth silver wall seen at its middle against F * the environment texture in the mirror direction, the wall turned about the vertical axis in steps:
-- no sphere mesh, no pointing error, the reflection of the sky alone (the shade cube takes the sun's light away). The camera is below the middle of the wall looking up, so the mirror direction is 37 degrees above the horizon
-- luajit glw --3d --background --validate lua "import('test/harnesses/brdf/mirror.lua')"   ROUGH=0.02 PVARS=k=v,...
local test_scene = import("goluwa/render3d/test_scene.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Shot = import("goluwa/render3d/shot.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local pvars = import("goluwa/cli/pvars.lua")
local ROUGH = tonumber(os.getenv("ROUGH") or "0.02")
for k, v in pairs{r_dither = false, r_bloom_strength = 0, r_eye = false} do pvars.SetSession(k, v) end
for pair in (os.getenv("PVARS") or ""):gmatch("[^,]+") do
	local k, v = pair:match("^([^=]+)=(.*)$")
	if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end
	pvars.SetSession(k, v)
end
test_scene.Reset{sun = {elevation = 35, azimuth = 30}, clouds = {}, ground_fog_visibility = math.huge}
local se, az = math.rad(35), math.rad(30)
local to_sun = Vec3(-math.sin(az) * math.cos(se), math.sin(se), -math.cos(az) * math.cos(se))
local f0 = {0.972, 0.960, 0.915}
local P = Vec3(500, 120, 500)
test_scene.Box{name = "shade", pos = P + to_sun * 100, size = Vec3(12, 12, 12), material = test_scene.Matte(0.1)}
local yaws = {}
for a = 0, 150, 15 do yaws[#yaws + 1] = a end
local views, extra = {}, {}
local DOWN = 37
-- the wall faces +z turned by yaw; the camera sits in front of it, above, looking at the middle
for i, yaw in ipairs(yaws) do
	local wall_pos = P + Vec3(i * 40, 0, 0)
	local rot = QuatDeg3(0, yaw, 0)
	local normal = rot:GetBackward()
	test_scene.Box{name = "wall" .. i, pos = wall_pos, rotation = rot, size = Vec3(8, 8, 0.05), material = shapes.Material{Color = Color(f0[1], f0[2], f0[3], 1), Roughness = ROUGH, Metallic = 1}}
	local cam = wall_pos + (normal * math.cos(math.rad(DOWN)) - Vec3(0, math.sin(math.rad(DOWN)), 0)) * 14
	local forward = (wall_pos - cam):GetNormalized()
	local pitch = math.deg(math.asin(forward.y))
	local yaw_cam = math.deg(math.atan2(-forward.x, -forward.z))
	views[i] = {Position = cam, Rotation = QuatDeg3(pitch, yaw_cam, 0), FOV = math.rad(8), ExposureLock = 14, LocalExposure = 0}
	extra[i] = {normal = normal, forward = forward}
end
local results = {}
Shot.Sequence(views, function(texture, info, i)
	local source = post_source.GetSceneSourceTexture({name = "blit_compute"})
	local pre = post_source.GetExposureTexture():Download():GetPixelFloat(0, 0) / post_source.PRE_EXPOSURE_HEADROOM
	local img = source:Download()
	local sum, n = {0, 0, 0}, 0
	for dy = -3, 3 do for dx = -3, 3 do
		local r, g, b = img:GetPixelFloat(math.floor(img.width / 2) + dx, math.floor(img.height / 2) + dy)
		sum[1], sum[2], sum[3], n = sum[1] + r, sum[2] + g, sum[3] + b, n + 1
	end end
	results[i] = {sum[1] / n / pre, sum[2] / n / pre, sum[3] / n / pre}
end, {settle = 2}, function()
	local env = render3d.GetEnvironmentTexture():Download()
	print("yaw  n.v   mirror direction (elev, azimuth from +z)   engine (rgb)      F * environment (rgb)     engine / expected")
	for i, yaw in ipairs(yaws) do
		local v = -extra[i].forward
		local n = extra[i].normal
		local nov = n:GetDot(v)
		local r = n * (2 * nov) - v
		local phi = math.atan2(r.z, -r.x)
		local u = phi / (2 * math.pi) + 0.5
		local vv = math.asin(r.y) / math.pi + 0.5
		local e = {0, 0, 0}
		local cnt = 0
		for dy = -2, 2 do for dx = -2, 2 do
			local pr, pg, pb = env:GetPixelFloat(math.floor(u * env.width) + dx, math.floor(vv * env.height) + dy)
			e[1], e[2], e[3], cnt = e[1] + pr, e[2] + pg, e[3] + pb, cnt + 1
		end end
		local out = {}
		for c = 1, 3 do
			local F = f0[c] + (1 - f0[c]) * (1 - nov) ^ 5
			out[c] = F * e[c] / cnt
		end
		local s = results[i]
		print(string.format("%3d  %.2f   %3.0f %4.0f   %7.0f %7.0f %7.0f   %7.0f %7.0f %7.0f   %.3f %.3f %.3f", yaw, nov, math.deg(math.asin(r.y)), math.deg(math.atan2(r.x, r.z)), s[1], s[2], s[3], out[1], out[2], out[3], s[1] / out[1], s[2] / out[2], s[3] / out[3]))
	end
	system.ShutDown(0)
end)
