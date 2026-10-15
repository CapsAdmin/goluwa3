-- renders the chart (flat on the ground, or standing up) in the sun and compares what the pipeline shows with what a matte surface
-- should show: L = albedo / pi * (direct + sky + ground irradiance). Run with
-- luajit glw --3d --background --validate lua "import('test/harnesses/colorchecker/run.lua')"
-- GROUND=0.18 (the ground's albedo) ORIENT=flat|vertical FACING=<degrees, the way a standing chart faces, the sun's azimuth by default> CAMERA=<degrees, where the camera stands, FACING by default; the sun's shadow cascades are fitted to the camera, a shade cube behind it can be clipped> PVARS=k=v,k=v SUN=60 AZIMUTH=30 FOG=1 FOG_VIS=<ground fog visibility m, the default when unset> PREFOG=1 (read the scene before the fog pass) EV=16 SPECULAR=0 BLOOM=0 SHADE=0 SHADE_DISTANCE=200 SETTLE=8 TONEMAP=neutral WB=6500 TINT=0 VERBOSE=1 (a table per patch)
local chart = import("test/harnesses/colorchecker/chart.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Shot = import("goluwa/render3d/shot.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local pvars = import("goluwa/cli/pvars.lua")
local sun_elevation = test_scene.GetNumber("SUN", 60)
local ev = test_scene.GetNumber("EV", 16)
local specular = test_scene.GetNumber("SPECULAR", 0)
local settle = test_scene.GetNumber("SETTLE", 8)
pvars.SetSession("r_dither", false)

-- PVARS="r_pass_ddgi=false,ddgi_strength=0" sets any pvar for the run
for pair in (os.getenv("PVARS") or ""):gmatch("[^,]+") do
	local key, value = pair:match("^([^=]+)=(.*)$")

	if value == "true" then value = true elseif value == "false" then value = false else value = tonumber(value) or value end

	pvars.SetSession(key, value)
end

pvars.SetSession("r_eye", false)
pvars.SetSession("r_bloom_strength", test_scene.GetNumber("BLOOM", 0))

if os.getenv("TINT") then pvars.SetSession("r_camera_white_balance_tint", tonumber(os.getenv("TINT"))) end

if os.getenv("WB") then pvars.SetSession("r_camera_white_balance", tonumber(os.getenv("WB"))) end

if os.getenv("TONEMAP") then pvars.SetSession("r_tonemapper", os.getenv("TONEMAP")) end
local azimuth = test_scene.GetNumber("AZIMUTH", 30)
test_scene.Reset{
	sun = {elevation = sun_elevation, azimuth = azimuth},
	clouds = {},
	ground_fog_visibility = test_scene.GetNumber("FOG", 1) == 0 and math.huge or test_scene.GetNumber("FOG_VIS", 0) > 0 and test_scene.GetNumber("FOG_VIS", 0) or nil,
}
local GROUND_ALBEDO = test_scene.GetNumber("GROUND", 0.18)
test_scene.Ground{size = 400, material = test_scene.Matte(GROUND_ALBEDO)}
-- the way the chart faces: up for the flat chart, a horizontal direction for the one standing up (the sun's azimuth by default,
-- the same convention as test_scene.Reset)
local orient = os.getenv("ORIENT") or "flat"
local facing = test_scene.GetNumber("FACING", azimuth)

local function horizontal(degrees)
	return Vec3(-math.sin(math.rad(degrees)), 0, -math.cos(math.rad(degrees)))
end

local vertical = orient == "vertical"
local normal = vertical and horizontal(facing) or Vec3(0, 1, 0)
-- what is to the right and what is up on the chart, seen from the front
local right_axis = vertical and Vec3(normal.z, 0, -normal.x) or Vec3(1, 0, 0)
local up_axis = vertical and Vec3(0, 1, 0) or Vec3(0, 0, -1)
local frame_width = chart.COLUMNS * (chart.SIZE + chart.GAP) + chart.GAP
local frame_depth = chart.ROWS * (chart.SIZE + chart.GAP) + chart.GAP
local center = vertical and Vec3(0, frame_depth / 2 + 0.1, 0) or Vec3(0, 0, 0)
local rotation = vertical and QuatFromAxis(math.atan2(normal.x, normal.z), Vec3(0, 1, 0)) or nil

local function get_patch_position(i, lift)
	local x, z = chart.GetCenter(i)
	-- chart.GetCenter's z grows away from the camera of the flat chart, the first row is the top row
	return center + right_axis * x + up_axis * (-z) + normal * lift
end

-- the black of the chart's frame is the darkest patch
test_scene.Box{
	name = "frame",
	pos = center + normal * 0.005,
	size = vertical and Vec3(frame_width, frame_depth, 0.01) or Vec3(frame_width, 0.01, frame_depth),
	rotation = rotation,
	material = test_scene.Matte(chart.SRGBToLinear(52)),
}

for i = 1, #chart.patches do
	local r, g, b = chart.GetAlbedo(i)
	local material = test_scene.Matte(Color(r, g, b, 1), 1)
	material:SetSpecularMultiplier(specular)
	test_scene.Box{
		name = chart.patches[i][1],
		pos = get_patch_position(i, 0.015),
		size = vertical and Vec3(chart.SIZE, chart.SIZE, 0.01) or Vec3(chart.SIZE, 0.01, chart.SIZE),
		rotation = rotation,
		material = material,
	}
end

-- SHADE=1 puts a cube in front of the sun so only the sky lights the chart
local shade = test_scene.GetNumber("SHADE", 0) == 1

if shade then
	local se = math.rad(sun_elevation)
	local to_sun = Vec3(-math.sin(math.rad(azimuth)) * math.cos(se), math.sin(se), -math.cos(math.rad(azimuth)) * math.cos(se))
	-- far and big enough to shade the whole chart (and the ground it sees) while covering only 3 degrees of the sky, the sun's
	-- aureole is part of the sky a standing chart facing the sun gets light from
	local distance = test_scene.GetNumber("SHADE_DISTANCE", 200)
	local side = distance * 0.05
	test_scene.Box{name = "shade", pos = to_sun * distance, size = Vec3(side, side, side), material = test_scene.Matte(0.1)}
end

-- the light on a patch: the sun through the air, the clear sky above the horizon (the sky view LUT, weighted by the angle to the
-- chart's normal) and for a standing chart the ground's light (a flat ground of this albedo, lit by the sun and the sky)
local function get_irradiance()
	local se = math.rad(sun_elevation)
	-- the scene's sun, see test_scene.Reset
	local sun = Vec3(-math.sin(math.rad(azimuth)) * math.cos(se), math.sin(se), -math.cos(math.rad(azimuth)) * math.cos(se))
	local t = atmosphere.GetTransmittance(sun, Vec3(0, 0, 0))
	local E = atmosphere.GetSunIlluminance()
	-- the sun's colour, the sky lookup table has it in already
	local tint = {atmosphere.SUN_COLOR.x, atmosphere.SUN_COLOR.y, atmosphere.SUN_COLOR.z}
	-- the ground fog layer above the chart takes its share of the beam too
	local fog = atmosphere.GetGroundFogSunTransmittance(math.sin(se), 0)
	local perpendicular = {E * t.x * tint[1] * fog, E * t.y * tint[2] * fog, E * t.z * tint[3] * fog}
	local img = atmosphere.GetSkyViewTexture(Vec3(0, 0, 0), sun):Download()
	local w, h = img.width, img.height
	-- the LUT's azimuth is measured from the sun, forward is the sun's horizontal direction and right is forward x up
	local forward = horizontal(azimuth)
	local right = Vec3(-forward.z, 0, forward.x)

	local function sky_irradiance(n)
		local sky = {0, 0, 0}
		local az_n, el_n = 180, 90

		for j = 0, el_n - 1 do
			local el = (j + 0.5) / el_n * math.pi / 2
			local v = math.sqrt(el / math.pi + 0.5)
			local py = math.min(h - 1, math.floor(v * h))

			for i = 0, az_n - 1 do
				local az = (i + 0.5) / az_n * 2 * math.pi - math.pi
				local px = math.min(w - 1, math.floor((az / (2 * math.pi) + 0.5) * w))
				local direction = (forward * math.cos(az) + right * math.sin(az)) * math.cos(el) + Vec3(0, math.sin(el), 0)
				local cos_n = direction:GetDot(n)

				if cos_n > 0 then
					local r, g, b = img:GetPixelFloat(px, py)
					local weight = cos_n * math.cos(el) * (math.pi / 2 / el_n) * (2 * math.pi / az_n)
					sky[1], sky[2], sky[3] = sky[1] + r * weight, sky[2] + g * weight, sky[3] + b * weight
				end
			end
		end

		return sky
	end

	local direct = {0, 0, 0}
	local no_l = math.max(normal:GetDot(sun), 0)

	if not shade then
		for c = 1, 3 do
			direct[c] = perpendicular[c] * no_l
		end
	end

	local sky = sky_irradiance(normal)
	local ground = {0, 0, 0}

	if vertical then
		-- the lower half of what a standing surface sees is the ground, uniform radiance albedo / pi * its irradiance, so half
		-- of that irradiance times the albedo reaches the surface
		local horizontal_sky = sky_irradiance(Vec3(0, 1, 0))

		for c = 1, 3 do
			local ground_irradiance = (shade and 0 or perpendicular[c] * sun.y) + horizontal_sky[c]
			ground[c] = GROUND_ALBEDO * ground_irradiance / 2
		end
	end

	return direct, sky, ground, perpendicular
end

local function lin(v)
	return chart.SRGBToLinear(v)
end

local post_source = import("goluwa/render3d/post_source.lua")
local view = {Position = Vec3(0, 9, 4.5), Rotation = QuatDeg3(-65, 0, 0), FOV = math.rad(50), ExposureLock = ev, LocalExposure = 0}

if vertical then
	-- in front of the chart, level with its middle, looking at it
	local toward_camera = horizontal(test_scene.GetNumber("CAMERA", facing))
	view.Position = center + toward_camera * 14
	view.Rotation = QuatDeg3(0, math.deg(math.atan2(toward_camera.x, toward_camera.z)), 0)
end

-- the mean of a patch's pixels as luminance (cd/m2) per channel. get_pixel returns linear values, scale turns them into cd/m2
local function measure(camera, width, height, get_pixel, scale)
	local rows = {}

	for i, p in ipairs(chart.patches) do
		local world = get_patch_position(i, 0.02)
		local pos = camera:WorldPositionToScreen(world, width, height, true)
		local sum = {0, 0, 0}
		local n = 0
		local half = 8

		for dy = -half, half do
			for dx = -half, half do
				local r, g, b = get_pixel(math.floor(pos.x) + dx, math.floor(pos.y) + dy)
				sum[1], sum[2], sum[3] = sum[1] + r, sum[2] + g, sum[3] + b
				n = n + 1
			end
		end

		rows[i] = {name = p[1], world = world, a = {chart.GetAlbedo(i)}, measured = {sum[1] / n / scale, sum[2] / n / scale, sum[3] / n / scale}}
	end

	return rows
end

-- the direct diffuse is EON's (a rough, energy preserving Oren-Nayar, perceptual roughness 1 here) times (1 - E(n.v)) (1 - F(n.l)) /
-- (1 - average F) (surface_lighting.lua, the specular coat takes E of the light and what enters is divided by the average of
-- what it lets in). With SPECULAR=0 the patches have no coat, F0 is 0 and the last factor is 1. The ambient diffuse is Lambert's
local function pow5(x)
	local x2 = x * x
	return x2 * x2 * x
end

-- E(n.v) of a rough (alpha 1) dielectric, the directional albedo of the specular with Schlick's F
local function specular_albedo(alpha, nov, f0)
	local N = 20000
	local vx, vz = math.sqrt(1 - nov * nov), nov
	local sum = 0

	for i = 0, N - 1 do
		local xi1 = (i + 0.5) / N
		local bits = i
		bits = bit.bor(bit.lshift(bits, 16), bit.rshift(bits, 16))
		bits = bit.bor(bit.lshift(bit.band(bits, 0x55555555), 1), bit.rshift(bit.band(bits, 0xAAAAAAAA), 1))
		bits = bit.bor(bit.lshift(bit.band(bits, 0x33333333), 2), bit.rshift(bit.band(bits, 0xCCCCCCCC), 2))
		bits = bit.bor(bit.lshift(bit.band(bits, 0x0F0F0F0F), 4), bit.rshift(bit.band(bits, 0xF0F0F0F0), 4))
		bits = bit.bor(bit.lshift(bit.band(bits, 0x00FF00FF), 8), bit.rshift(bit.band(bits, 0xFF00FF00), 8))
		local xi2 = (bits % 4294967296) * 2.3283064365386963e-10
		local cos_t = math.sqrt((1 - xi2) / (1 + (alpha * alpha - 1) * xi2))
		local sin_t = math.sqrt(1 - cos_t * cos_t)
		local phi = 2 * math.pi * xi1
		local hx, hz = math.cos(phi) * sin_t, cos_t
		local voh = vx * hx + vz * hz

		if voh > 0 then
			local nol = 2 * voh * hz - vz

			if nol > 0 then
				local a2 = math.max(alpha * alpha, 1e-3)
				local lv = nol * math.sqrt((nov - a2 * nov) * nov + a2)
				local ll = nov * math.sqrt((nol - a2 * nol) * nol + a2)
				sum = sum + 0.5 / (lv + ll) * (f0 + (1 - f0) * pow5(1 - voh)) * nol * 4 * voh / hz
			end
		end
	end

	return sum / N
end

local function eon(albedo, rough, nol, nov, lov)
	local A = 1 / (1 + (0.5 - 2 / (3 * math.pi)) * rough)
	local B = rough * A
	local s_term = lov - nol * nov
	local t = s_term > 0 and math.max(nol, nov) or 1
	local mean = A * (1 + (2 / 3 - 28 / (15 * math.pi)) * rough)

	local function E(mu)
		local x = 1 - mu
		return A + B * x * (0.0571085289 + x * (0.491881867 + x * (-0.332181442 + x * 0.0714429953)))
	end

	return (albedo * (A + B * s_term / t) + albedo * albedo * (mean / (1 - albedo * (1 - mean))) * ((1 - E(nol)) * (1 - E(nov)) / math.max(1 - mean, 1e-4))) / math.pi
end

local function get_diffuse_factor(row)
	local f0 = 0.04 * specular
	local se = math.rad(sun_elevation)
	local V = (view.Position - row.world):GetNormalized()
	local L = Vec3(-math.sin(math.rad(azimuth)) * math.cos(se), math.sin(se), -math.cos(math.rad(azimuth)) * math.cos(se))
	local nol = math.max(normal:GetDot(L), 0)
	local nov = normal:GetDot(V)
	-- per channel: the EON diffuse for the albedo, over the Lambert one it replaces (albedo / pi)
	local per_channel = {}

	for c = 1, 3 do
		per_channel[c] = eon(row.a[c], 1, nol, nov, L:GetDot(V)) * math.pi / row.a[c]
	end

	if f0 == 0 then return per_channel end
	local f90 = math.min(f0 * 50 * 0.33, 1)
	local e_view = specular_albedo(1, nov, f0) * (1 + f0 * (1 / specular_albedo(1, nov, 1) - 1))
	local average = f0 + (f90 - f0) / 21
	local coupling = math.max(1 - e_view, 0) * (1 - (f0 + (f90 - f0) * pow5(1 - nol))) / (1 - average)

	for c = 1, 3 do
		per_channel[c] = per_channel[c] * coupling
	end

	return per_channel
end

local function report(title, rows, direct, sky, ground, verbose)
	local white

	for i, row in ipairs(rows) do
		row.expected = {}
		local diffuse_factor = get_diffuse_factor(row)

		for c = 1, 3 do
			row.expected[c] = row.a[c] / math.pi * (direct[c] * diffuse_factor[c] + sky[c] + ground[c])
		end

		if i == 19 then white = row end
	end

	print("--- " .. title)

	if verbose then print("patch            albedo (lin)         measured/expected rgb       ratio to white (measured/expected)") end

	local sum_sq, sum_n, worst, worst_name = 0, 0, 0, ""

	for i, row in ipairs(rows) do
		local parts, rel = {}, {}

		for c = 1, 3 do
			parts[c] = string.format("%.3f", row.measured[c] / row.expected[c])
			rel[c] = string.format("%.3f", (row.measured[c] / white.measured[c]) / (row.expected[c] / white.expected[c]))
		end

		if verbose then
			print(string.format("%-14s %.3f %.3f %.3f     %s %s %s       %s %s %s    irradiance %.0f %.0f %.0f lux", row.name, row.a[1], row.a[2], row.a[3], parts[1], parts[2], parts[3], rel[1], rel[2], rel[3], row.measured[1] * math.pi / row.a[1], row.measured[2] * math.pi / row.a[2], row.measured[3] * math.pi / row.a[3]))
		end

		if i ~= 19 then
			for c = 1, 3 do
				if row.expected[c] / white.expected[c] > 0.01 then
					local err = math.log((row.measured[c] / white.measured[c]) / (row.expected[c] / white.expected[c]))
					sum_sq, sum_n = sum_sq + err * err, sum_n + 1

					if math.abs(err) > worst then worst, worst_name = math.abs(err), row.name end
				end
			end
		end
	end

	print(
		string.format(
			"white patch measured/expected %.3f %.3f %.3f (a perfect pipeline is 1 1 1), the others against the white: rms error %.1f percent, worst %.1f percent (%s)",
			white.measured[1] / white.expected[1],
			white.measured[2] / white.expected[2],
			white.measured[3] / white.expected[3],
			math.sqrt(sum_sq / sum_n) * 100,
			worst * 100,
			worst_name
		)
	)
	print(string.format("white patch as measured, R/G %.3f and B/G %.3f (1 and 1 is a neutral white)", white.measured[1] / white.measured[2], white.measured[3] / white.measured[2]))
end

Shot.Capture(view, function(texture, info)
	local direct, sky, ground, perpendicular = get_irradiance()
	-- ExposureLock in camera terms: 18 percent grey KEY 0.18, K = 12.5
	local scale = 0.18 * 8 / 2 ^ ev
	print(string.format("sun %g degrees, EV %g (display pixel = luminance * %.3e), irradiance on the chart (%s): direct %.0f %.0f %.0f sky %.0f %.0f %.0f ground %.0f %.0f %.0f lux (sun perpendicular %.0f %.0f %.0f)", sun_elevation, ev, scale, vertical and ("standing, facing " .. facing .. " degrees") or "flat", direct[1], direct[2], direct[3], sky[1], sky[2], sky[3], ground[1], ground[2], ground[3], perpendicular[1], perpendicular[2], perpendicular[3]))

	local function make_camera(width, height)
		-- the view is gone by now, a camera with the same settings projects the patch centers
		local camera = import("goluwa/render3d/camera3d.lua").New()
		camera:SetFOV(view.FOV)
		camera:SetPosition(view.Position)
		camera:SetRotation(view.Rotation)
		camera:SetViewport(Rect(0, 0, width, height))
		return camera
	end

	-- the scene colour before the exposure, the white balance and the tonemapper: absolute luminance times the
	-- pre exposure (the exposure of the frame before over 32), fp16, no 8 bit quantisation and no shoulder
	-- PREFOG=1: the lighting pass's output, before the volumetric fog pass puts the air in front of the chart
	local source = (os.getenv("PREFOG") and render3d.pipelines.lighting:GetFramebuffer(1):GetAttachment(1) or post_source.GetSceneSourceTexture({name = "blit_compute"})):Download()
	local exposure = post_source.GetExposureTexture():Download():GetPixelFloat(0, 0)
	local pre_exposure = exposure / post_source.PRE_EXPOSURE_HEADROOM
	report(
		string.format("scene before exposure and tonemapping (%dx%d, pre exposure %.3e)", source.width, source.height, pre_exposure),
		measure(make_camera(source.width, source.height), source.width, source.height, function(x, y)
			local r, g, b = source:GetPixelFloat(x, y)
			return r, g, b
		end, pre_exposure),
		direct,
		sky,
		ground,
		os.getenv("VERBOSE") ~= nil
	)
	report(
		"display (8 bit sRGB after exposure, white balance and tonemapper)",
		measure(make_camera(texture.width, texture.height), texture.width, texture.height, function(x, y)
			local r, g, b = texture:GetPixel(x, y)
			return lin(r), lin(g), lin(b)
		end, scale),
		direct,
		sky,
		ground,
		os.getenv("VERBOSE") ~= nil
	)
	texture:SaveWithoutAlpha("tmp/colorchecker.png")
	system.ShutDown(0)
end, {settle = settle})
