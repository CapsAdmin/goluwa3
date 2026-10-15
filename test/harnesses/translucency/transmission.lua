-- the diffuse transmission of thin sheets (leaves, cloth) against what the model says it is: a sheet lit from behind by the sun
-- shows T * tint * albedo * phase(V, L, scattering) * cos * E to a camera in front of it, and the sheet lit from the front gives the
-- diffuse the opaque sheet would have, scaled by 1 - T. The ambient light is not wanted, so everything is rendered twice, in the
-- sun and with a cube in front of the sun, and the difference is the direct light alone (as brdf/shade.lua).
-- luajit glw --3d --background --validate lua "import('test/harnesses/translucency/transmission.lua')"
-- AZIMUTH=0 (0 sun behind the sheets, 180 in front) SUN=35 ALBEDO=0.6 SETTLE=6 OUT=tmp/transmission.png
-- the phase function's energy (a lobe must send as much light out of the far side as the lambert one does, whatever the angle it arrives
-- at) is checked on the cpu first
local test_scene = import("goluwa/render3d/test_scene.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Shot = import("goluwa/render3d/shot.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local pvars = import("goluwa/cli/pvars.lua")
local sun_elevation = test_scene.GetNumber("SUN", 35)
local azimuth = test_scene.GetNumber("AZIMUTH", 0)
local albedo = test_scene.GetNumber("ALBEDO", 0.6)
local settle = test_scene.GetNumber("SETTLE", 6)
local PI = math.pi
local G = 0.6
local NORMALISED = test_scene.GetNumber("NORMALISED", 1) == 1

-- the lobe as the feature evaluates it: divided by its own flux, a quartic in the cosine of the incidence
local function phase(v_dot_l, scattering, cos_incidence)
	local denominator = 1 + G * G + 2 * G * v_dot_l
	local hg = (1 - G * G) / (4 * PI * denominator * math.sqrt(denominator))
	local c = math.min(math.max(cos_incidence, 0), 1)
	local lobe_flux = 0.37707 + c * (0.58701 + c * (0.57085 + c * (-0.29538 + c * 0.06498)))
	return (1 - scattering) / PI + scattering * 2 * hg / (NORMALISED and lobe_flux or 1)
end

-- the flux a sheet sends out of its far side per unit of light arriving at it, over the hemisphere the camera sees it from
local function flux(incidence, scattering)
	local L = Vec3(math.sin(incidence), 0, -math.cos(incidence))
	local sum, steps = 0, 400
	local d_theta, d_phi = (PI / 2) / steps, 2 * PI / steps

	for i = 0, steps - 1 do
		local theta = (i + 0.5) * d_theta

		for j = 0, steps - 1 do
			local phi = (j + 0.5) * d_phi
			local V = Vec3(math.sin(theta) * math.cos(phi), math.sin(theta) * math.sin(phi), math.cos(theta))
			sum = sum + phase(V:GetDot(L), scattering, math.cos(incidence)) * math.cos(theta) * math.sin(theta) * d_theta * d_phi
		end
	end

	return sum
end

print("flux out of the far side (lambert is 1), by incidence angle")

for _, s in ipairs{0.4, 1} do
	local row = {}

	for _, deg in ipairs{0, 30, 60, 80} do
		row[#row + 1] = string.format("%2d deg %.3f", deg, flux(math.rad(deg), s))
	end

	print(string.format("  scattering %.1f: %s", s, table.concat(row, "   ")))
end

pvars.SetSession("r_dither", false)
pvars.SetSession("r_bloom_strength", 0)
pvars.SetSession("r_eye", false)
pvars.SetSession("ddgi_strength", 0)
pvars.SetSession("r_pass_reflections", false)
pvars.SetSession("r_pass_ambient_occlusion", false)
test_scene.Reset{sun = {elevation = sun_elevation, azimuth = azimuth}, clouds = {}, ground_fog_visibility = math.huge}
test_scene.Ground{size = 400, material = test_scene.Matte(0.0)}
local sheets = {
	{t = 0, s = 0, tint = {1, 1, 1}},
	{t = 0.25, s = 0, tint = {1, 1, 1}},
	{t = 0.5, s = 0, tint = {1, 1, 1}},
	{t = 1, s = 0, tint = {1, 1, 1}},
	{t = 0.5, s = 0.4, tint = {1, 1, 1}},
	{t = 0.5, s = 1, tint = {1, 1, 1}},
	{t = 0.5, s = 0, tint = {1, 0.6, 0.25}},
}
local spacing = 1.5

for i, sheet in ipairs(sheets) do
	sheet.x = (i - (#sheets + 1) / 2) * spacing
	sheet.y = 0.8
	-- one double sided quad, like a leaf: a box has a thickness that shadows its own far face
	local sheet_entity = shapes.Polygon{
		Name = "sheet" .. i,
		Position = Vec3(sheet.x, sheet.y, 0),
		Polygon = function(poly)
			local w, h = 0.6, 0.6
			local p = {Vec3(-w, -h, 0), Vec3(w, -h, 0), Vec3(w, h, 0), Vec3(-w, h, 0)}
			local uv = {Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)}

			for _, tri in ipairs{{1, 3, 2}, {1, 4, 3}} do
				for _, k in ipairs(tri) do
					poly:AddVertex{pos = p[k], uv = uv[k], normal = Vec3(0, 0, 1)}
				end
			end
		end,
		RigidBody = false,
		Collision = false,
		Material = shapes.Material{
			Color = Color(albedo, albedo, albedo, 1),
			Roughness = 1,
			Metallic = 0,
			DoubleSided = true,
			DiffuseTransmission = sheet.t,
			TransmissionScattering = sheet.s,
			TransmissionColor = Color(sheet.tint[1], sheet.tint[2], sheet.tint[3], 1),
		},
	}
	test_scene.GetRoot():AddChild(sheet_entity)
end

local se = math.rad(sun_elevation)
local to_sun = Vec3(-math.sin(math.rad(azimuth)) * math.cos(se), math.sin(se), -math.cos(math.rad(azimuth)) * math.cos(se))
local view = {Position = Vec3(0, 0.8, 7), Rotation = QuatDeg3(0, 0, 0), FOV = math.rad(60), ExposureLock = 14, LocalExposure = 0}
local results = {}

local function measure(source, camera, pre_exposure)
	local img = source:Download()
	local out = {}

	for i, sheet in ipairs(sheets) do
		local pos = camera:WorldPositionToScreen(Vec3(sheet.x, sheet.y, 0), img.width, img.height, true)
		local sum, n = {0, 0, 0}, 0

		for dy = -6, 6 do
			for dx = -6, 6 do
				local r, g, b = img:GetPixelFloat(math.floor(pos.x) + dx, math.floor(pos.y) + dy)
				sum[1], sum[2], sum[3], n = sum[1] + r, sum[2] + g, sum[3] + b, n + 1
			end
		end

		out[i] = {sum[1] / n / pre_exposure, sum[2] / n / pre_exposure, sum[3] / n / pre_exposure}
	end

	return out
end

Shot.Sequence({view, view}, function(texture, info, i)
	local camera = import("goluwa/render3d/camera3d.lua").New()
	camera:SetFOV(view.FOV)
	camera:SetPosition(view.Position)
	camera:SetRotation(view.Rotation)
	camera:SetViewport(Rect(0, 0, 1920, 1080))
	local source = post_source.GetSceneSourceTexture({name = "blit_compute"})
	local exposure = post_source.GetExposureTexture():Download():GetPixelFloat(0, 0)
	results[i] = measure(source, camera, exposure / post_source.PRE_EXPOSURE_HEADROOM)

	if i == 1 then
		texture:SaveWithoutAlpha(os.getenv("OUT") or "tmp/transmission.png")
		test_scene.Box{name = "shade", pos = to_sun * 40, size = Vec3(14, 14, 14), material = test_scene.Matte(0.1)}
	end
end, {settle = settle}, function()
	local t = atmosphere.GetTransmittance(to_sun, Vec3(0, 0, 0))
	local color = atmosphere.SUN_COLOR
	local E = atmosphere.GetSunIlluminance()
	local sun = {E * t.x * color.x, E * t.y * color.y, E * t.z * color.z}
	local behind = to_sun.z < 0
	print(string.format("\nsun %g deg, azimuth %g (%s), direct light %.0f %.0f %.0f lux", sun_elevation, azimuth, behind and "behind the sheets" or "in front of the sheets", sun[1], sun[2], sun[3]))
	print("sheet   T    scat  tint              measured (direct, cd/m2)    expected   measured/expected (rgb)")
	local lum = function(c) return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3] end

	for i, sheet in ipairs(sheets) do
		local V = (view.Position - Vec3(sheet.x, sheet.y, 0)):GetNormalized()
		local cos_n = math.abs(to_sun.z)
		local measured, ratios, expected = {}, {}, {}
		-- the tint's luminance is 1, its hue is what is left
		local tint_luma = lum(sheet.tint)

		for c = 1, 3 do
			measured[c] = results[1][i][c] - results[2][i][c]

			if behind then
				expected[c] = sheet.t * (sheet.tint[c] / tint_luma) * albedo * phase(V:GetDot(to_sun), sheet.s, cos_n) * cos_n * sun[c]
			else
				-- the opaque sheet's diffuse (lambert at roughness 1, a little less than EON's) scaled by what is not transmitted
				expected[c] = (1 - sheet.t) * albedo / PI * cos_n * sun[c]
			end

			ratios[c] = expected[c] > 1 and string.format("%.3f", measured[c] / expected[c]) or "  -  "
		end

		print(string.format("%d    %.2f  %.1f  %.2f %.2f %.2f   %9.0f %9.0f %9.0f   %9.0f   %s %s %s", i, sheet.t, sheet.s, sheet.tint[1], sheet.tint[2], sheet.tint[3], measured[1], measured[2], measured[3], expected[2], ratios[1], ratios[2], ratios[3]))
	end

	system.ShutDown(0)
end)
