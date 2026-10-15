-- metal spheres lit by the environment alone against a multiple scattering reference. The reference is Heitz's random walk on the
-- Smith height field (Heitz, Hanika, d'Eon, Dachsbacher 2016, GGX conductor, uniform heights, visible normal sampling), which has no
-- split sum, no prefiltering and no energy compensation: each walk's exit direction reads the full resolution environment
-- (render3d.GetEnvironmentTexture, level 0) weighted by the Fresnel reflectances of its bounces. The spheres have no ground and the sun's light is
-- taken away with a cube in front of it, so what the lighting pass shows is the ambient specular alone.
-- luajit glw --3d --background --validate lua "import('test/harnesses/brdf/environment.lua')"
-- PVARS=k=v,... SUN=35 AZIMUTH=30 WALKS=30000 RT=1 (0 turns the ray traced reflection off) EV=14 SETTLE=6 ANGLES=0,40,65 (degrees off the view direction on the sphere)
local test_scene = import("goluwa/render3d/test_scene.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Shot = import("goluwa/render3d/shot.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local pvars = import("goluwa/cli/pvars.lua")
local sun_elevation = test_scene.GetNumber("SUN", 35)
local azimuth = test_scene.GetNumber("AZIMUTH", 30)
local walks = test_scene.GetNumber("WALKS", 4000)
local settle = test_scene.GetNumber("SETTLE", 6)
local ev = test_scene.GetNumber("EV", 14)
local SUN_EXCLUDE = test_scene.GetNumber("SUN_EXCLUDE", 25)
local PI = math.pi
local angles = {}

for v in (os.getenv("ANGLES") or "0,40,65"):gmatch("[^,]+") do
	angles[#angles + 1] = tonumber(v)
end

for key, value in pairs{
	r_dither = false,
	r_bloom_strength = 0,
	r_eye = false,
	r_pass_ambient_occlusion = false,
	reflection_ray_query = test_scene.GetNumber("RT", 1) == 1,
} do
	pvars.SetSession(key, value)
end

for pair in (os.getenv("PVARS") or ""):gmatch("[^,]+") do
	local k, v = pair:match("^([^=]+)=(.*)$")

	if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end

	pvars.SetSession(k, v)
end

test_scene.Reset{sun = {elevation = sun_elevation, azimuth = azimuth}, clouds = {}, ground_fog_visibility = math.huge}
local metals = {
	{name = "silver", f0 = {0.972, 0.960, 0.915}},
	{name = "gold", f0 = {1.000, 0.766, 0.336}},
	{name = "iron", f0 = {0.562, 0.565, 0.578}},
}
local roughnesses = {0.05, 0.15, 0.3, 0.5, 0.7, 1.0}
local RADIUS, SPACING = 0.45, 3.0
-- away from the default scene's props
local ORIGIN = Vec3(400, 120, 400)
-- seen from above, so the reflection of the view at the middle of a sphere goes back up into the sky and not along the horizon, where the
-- environment changes from the sky to the ground within a texel
local CAMERA_HEIGHT, CAMERA_DISTANCE = test_scene.GetNumber("HEIGHT", 15), test_scene.GetNumber("DISTANCE", 20)
local spheres = {}

for ri, metal in ipairs(metals) do
	for ci, rough in ipairs(roughnesses) do
		local center = ORIGIN + Vec3((ci - (#roughnesses + 1) / 2) * SPACING, (2 - ri) * SPACING, 0)
		spheres[#spheres + 1] = {center = center, metal = metal, roughness = rough}
		test_scene.GetRoot():AddChild(
			shapes.Sphere{
				Name = metal.name .. rough,
				Position = center,
				Radius = RADIUS,
				Material = shapes.Material{Color = Color(metal.f0[1], metal.f0[2], metal.f0[3], 1), Roughness = rough, Metallic = 1},
				Collision = false,
				RigidBody = false,
			}
		)
	end
end

local se = math.rad(sun_elevation)
local to_sun = Vec3(-math.sin(math.rad(azimuth)) * math.cos(se), math.sin(se), -math.cos(math.rad(azimuth)) * math.cos(se))
test_scene.Box{name = "shade", pos = ORIGIN + to_sun * test_scene.GetNumber("SHADE_DISTANCE", 100), size = Vec3(12, 12, 12), material = test_scene.Matte(0.1)}
local view = {Position = ORIGIN + Vec3(0, CAMERA_HEIGHT, CAMERA_DISTANCE), Rotation = QuatDeg3(-math.deg(math.atan2(CAMERA_HEIGHT, CAMERA_DISTANCE)), 0, 0), FOV = math.rad(30), ExposureLock = ev, LocalExposure = 0}

-- the random walk -------------------------------------------------------------------------------------------------
local sqrt, abs, max, min = math.sqrt, math.abs, math.max, math.min
local random = math.random

local function lambda(mu, alpha)
	mu = abs(mu)

	if mu > 0.99999 then return 0 end

	local tan2 = (1 - mu * mu) / (mu * mu)
	return 0.5 * (-1 + sqrt(1 + alpha * alpha * tan2))
end

-- gaussian heights (a uniform field has a floor, where the probability of a ray going on is 0 and the sampling divides by it)
local function erfinv(x)
	local w = -math.log((1 - x) * (1 + x))
	local p

	if w < 5 then
		w = w - 2.5
		p = 2.81022636e-08
		p = 3.43273939e-07 + p * w
		p = -3.5233877e-06 + p * w
		p = -4.39150654e-06 + p * w
		p = 0.00021858087 + p * w
		p = -0.00125372503 + p * w
		p = -0.00417768164 + p * w
		p = 0.246640727 + p * w
		p = 1.50140941 + p * w
	else
		w = sqrt(w) - 3
		p = -0.000200214257
		p = 0.000100950558 + p * w
		p = 0.00134934322 + p * w
		p = -0.00367342844 + p * w
		p = 0.00573950773 + p * w
		p = -0.0076224613 + p * w
		p = 0.00943887047 + p * w
		p = 1.00167406 + p * w
		p = 2.83297682 + p * w
	end

	return p * x
end

local function erf(x)
	local t = 1 / (1 + 0.3275911 * abs(x))
	local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-x * x)
	return x >= 0 and y or -y
end

local function C1(h) return 0.5 * (1 + erf(h)) end

local function invC1(u) return erfinv(2 * min(max(u, 1e-12), 1 - 1e-12) - 1) end

local function sample_height(wz, hr, alpha)
	local u = random()

	if wz > 0.9999 then return math.huge end

	if wz < -0.9999 then return invC1(u * C1(hr)) end

	if abs(wz) < 0.0001 then return hr end

	local lam = lambda(wz, alpha)

	if wz > 0 then
		local g1 = C1(hr) ^ lam

		if u > 1 - g1 then return math.huge end

		return invC1(C1(hr) / (1 - u) ^ (1 / lam))
	end

	return invC1(C1(hr) * u ^ (1 / (1 + lam)))
end

-- a visible normal for the view direction (vx, vy, vz) with vz > 0 (Heitz 2018)
local function sample_vndf(vx, vy, vz, alpha)
	local hx, hy, hz = alpha * vx, alpha * vy, vz
	local len = sqrt(hx * hx + hy * hy + hz * hz)
	hx, hy, hz = hx / len, hy / len, hz / len
	local lensq = hx * hx + hy * hy
	local t1x, t1y, t1z

	if lensq > 0 then
		local inv = 1 / sqrt(lensq)
		t1x, t1y, t1z = -hy * inv, hx * inv, 0
	else
		t1x, t1y, t1z = 1, 0, 0
	end

	local t2x, t2y, t2z = hy * t1z - hz * t1y, hz * t1x - hx * t1z, hx * t1y - hy * t1x
	local r = sqrt(random())
	local phi = 2 * PI * random()
	local t1 = r * math.cos(phi)
	local t2 = r * math.sin(phi)
	local s = 0.5 * (1 + hz)
	t2 = (1 - s) * sqrt(max(1 - t1 * t1, 0)) + s * t2
	local t3 = sqrt(max(1 - t1 * t1 - t2 * t2, 0))
	local nx, ny, nz = t1 * t1x + t2 * t2x + t3 * hx, t1 * t1y + t2 * t2y + t3 * hy, t1 * t1z + t2 * t2z + t3 * hz
	nx, ny, nz = alpha * nx, alpha * ny, max(nz, 0)
	local nlen = sqrt(nx * nx + ny * ny + nz * nz)
	return nx / nlen, ny / nlen, nz / nlen
end

-- one walk from the view direction wi (pointing away from the surface); returns the exit direction and the weight per channel,
-- or nil when the energy was lost
local function walk(wix, wiy, wiz, alpha, f0)
	local wx, wy, wz = -wix, -wiy, -wiz
	local h = 1 + invC1(0.999)
	local er, eg, eb = 1, 1, 1

	for _ = 1, 100 do
		h = sample_height(wz, h, alpha)

		if h == math.huge then return wx, wy, wz, er, eg, eb end

		-- the surface sees the ray coming from -w
		local vx, vy, vz = -wx, -wy, -wz
		local flip = vz < 0

		if flip then vx, vy, vz = -vx, -vy, -vz end

		local mx, my, mz = sample_vndf(vx, vy, vz, alpha)

		if flip then mx, my, mz = -mx, -my, -mz end

		local d = wx * mx + wy * my + wz * mz
		local cos_i = abs(d)
		local p = (1 - cos_i) ^ 5
		er, eg, eb = er * (f0[1] + (1 - f0[1]) * p), eg * (f0[2] + (1 - f0[2]) * p), eb * (f0[3] + (1 - f0[3]) * p)
		wx, wy, wz = wx - 2 * d * mx, wy - 2 * d * my, wz - 2 * d * mz
	end
end

local env_image
local env_flip = false

local function environment(dx, dy, dz)
	local phi = math.atan2(dz, -dx)
	local u = phi / (2 * PI) + 0.5
	local v = math.asin(min(max(dy, -1), 1)) / PI + 0.5

	if env_flip then v = 1 - v end

	local px = min(env_image.width - 1, math.floor(u * env_image.width))
	local py = min(env_image.height - 1, math.floor(v * env_image.height))
	return env_image:GetPixelFloat(px, py)
end

-- the radiance the surface at normal n sends to the viewer along v: the walks' exit directions read the environment
local function reference(n, v, roughness, f0)
	local alpha = roughness * roughness
	local nov = n:GetDot(v)
	local tx = (v - n * nov)
	tx = tx:GetNormalized()
	local ty = n:GetCross(tx)
	local wix, wiy, wiz = v:GetDot(tx), v:GetDot(ty), nov
	local sum = {0, 0, 0}
	local albedo = 0

	for _ = 1, walks do
		local wx, wy, wz, er, eg, eb = walk(wix, wiy, wiz, alpha, f0)

		if wx then
			local dir = tx * wx + ty * wy + n * wz
			local r, g, b = environment(dir.x, dir.y, dir.z)
			sum[1], sum[2], sum[3] = sum[1] + er * r, sum[2] + eg * g, sum[3] + eb * b
			albedo = albedo + (er + eg + eb) / 3
		end
	end

	return sum[1] / walks, sum[2] / walks, sum[3] / walks, albedo / walks
end

-- the picture ---------------------------------------------------------------------------------------------------
local points = {}

for _, sphere in ipairs(spheres) do
	local to_camera = (view.Position - sphere.center):GetNormalized()

	for _, angle in ipairs(angles) do
		-- the normal tilted off the direction to the camera, sideways, so the reflection stays at the same height in the sky
		local side = to_camera:GetCross(Vec3(0, 1, 0)):GetNormalized()
		local tilt = side
		local n = (to_camera * math.cos(math.rad(angle)) + tilt * math.sin(math.rad(angle))):GetNormalized()
		points[#points + 1] = {sphere = sphere, angle = angle, normal = n, position = sphere.center + n * RADIUS}
	end
end

Shot.Capture(view, function(texture, info)
	local camera = import("goluwa/render3d/camera3d.lua").New()
	camera:SetFOV(view.FOV)
	camera:SetPosition(view.Position)
	camera:SetRotation(view.Rotation)
	camera:SetViewport(Rect(0, 0, 1920, 1080))
	local source = post_source.GetSceneSourceTexture({name = "blit_compute"})
	local pre = post_source.GetExposureTexture():Download():GetPixelFloat(0, 0) / post_source.PRE_EXPOSURE_HEADROOM
	local img = source:Download()
	texture:SaveWithoutAlpha(os.getenv("OUT") or "tmp/brdf_environment.png")
	env_image = render3d.GetEnvironmentTexture():Download()
	-- which way the rows run: the brightest texel is the sun's, at the sun's elevation
	local best, best_row, best_col = -1, 0, 0

	for y = 0, env_image.height - 1, 2 do
		for x = 0, env_image.width - 1, 4 do
			local r, g, b = env_image:GetPixelFloat(x, y)

			if r + g + b > best then best, best_row, best_col = r + g + b, y, x end
		end
	end

	env_flip = math.abs((best_row + 0.5) / env_image.height - (0.5 + se / PI)) > math.abs(1 - (best_row + 0.5) / env_image.height - (0.5 + se / PI))
	print(string.format("environment %dx%d, brightest texel (%.0f summed) at row %d column %d (the sun is at elevation %g), rows %s", env_image.width, env_image.height, best, best_row, best_col, sun_elevation, env_flip and "flipped" or "as is"))
	local summary = {}
	print("metal   rough  off-axis  n.v  from sun    engine (cd/m2)           reference               engine / reference (rgb)    reference albedo")

	local forward = view.Rotation:GetForward()
	local right = view.Rotation:GetRight()
	local up = view.Rotation:GetUp()
	local half_height = math.tan(view.FOV / 2)
	local half_width = half_height * img.width / img.height

	for _, point in ipairs(points) do
		local v = (view.Position - point.position):GetNormalized()
		local pos = camera:WorldPositionToScreen(point.position, img.width, img.height, true)
		local sum, ref, count = {0, 0, 0}, {0, 0, 0}, 0
		local albedo = 0

		-- every pixel of the 3 by 3 is a ray through the sphere, with its own normal and view direction: the reference is
		-- taken over exactly the pixels that are measured, the sky changes within a few degrees
		for dy = -1, 1 do
			for dx = -1, 1 do
				local px, py = math.floor(pos.x) + dx, math.floor(pos.y) + dy
				local ndc_x, ndc_y = 2 * (px + 0.5) / img.width - 1, 1 - 2 * (py + 0.5) / img.height
				local dir = (forward + right * (ndc_x * half_width) + up * (ndc_y * half_height)):GetNormalized()
				local oc = view.Position - point.sphere.center
				local b = oc:GetDot(dir)
				local disc = b * b - (oc:GetDot(oc) - RADIUS * RADIUS)

				if disc > 0 then
					local hit = view.Position + dir * (-b - math.sqrt(disc))
					local normal = (hit - point.sphere.center):GetNormalized()
					local r, g, b2, a = reference(normal, -dir, point.sphere.roughness, point.sphere.metal.f0)
					local pr, pg, pb = img:GetPixelFloat(px, py)
					sum[1], sum[2], sum[3] = sum[1] + pr, sum[2] + pg, sum[3] + pb
					ref[1], ref[2], ref[3] = ref[1] + r, ref[2] + g, ref[3] + b2
					albedo = albedo + a
					count = count + 1
				end
			end
		end

		local measured = {sum[1] / count / pre, sum[2] / count / pre, sum[3] / count / pre}
		local r, g, b, albedo_mean = ref[1] / count, ref[2] / count, ref[3] / count, albedo / count
		albedo = albedo_mean
		-- the shade cube and the sun's own highlight are in this direction, not what is being measured
		local mirror = (point.normal * (2 * point.normal:GetDot(v)) - v)
		local from_sun = math.deg(math.acos(math.min(math.max(mirror:GetDot(to_sun), -1), 1)))
		local key = point.sphere.roughness .. " " .. point.angle
		summary[key] = summary[key] or {0, 0, 0}

		if from_sun > SUN_EXCLUDE then
			summary[key][1] = summary[key][1] + math.log(measured[2] / g)
			summary[key][2] = summary[key][2] + 1
		end

		print(string.format(
			"%-7s %.2f   %3d deg   %.2f  %4.0f deg   %7.0f %7.0f %7.0f   %7.0f %7.0f %7.0f   %.3f %.3f %.3f   %.3f",
			point.sphere.metal.name, point.sphere.roughness, point.angle, point.normal:GetDot(v), from_sun,
			measured[1], measured[2], measured[3], r, g, b, measured[1] / r, measured[2] / g, measured[3] / b, albedo
		))
	end

	print("engine / reference, green, geometric mean over the metals (points further than SUN_EXCLUDE degrees from the sun)")
	local keys = {}

	for _, rough in ipairs(roughnesses) do
		local row = {}

		for _, angle in ipairs(angles) do
			local entry = summary[rough .. " " .. angle]
			row[#row + 1] = entry[2] > 0 and string.format("%3d deg %.3f (%d)", angle, math.exp(entry[1] / entry[2]), entry[2]) or string.format("%3d deg  -", angle)
		end

		print(string.format("  roughness %.2f: %s", rough, table.concat(row, "   ")))
	end

	system.ShutDown(0)
end, {settle = settle})
