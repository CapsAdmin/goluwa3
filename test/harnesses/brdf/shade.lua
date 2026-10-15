-- renders rows of flat plates (a white metal and a white dielectric at several roughnesses) lit by the sun and compares
-- what the lighting pass shows with the same BRDF evaluated in lua (GGX, height correlated Smith, Schlick, the Kulla-Conty
-- energy compensation of the direct specular, a Fresnel coupled EON diffuse). The ambient light is not wanted, so the plates are rendered
-- twice, in the sun and with a cube in front of the sun, and the difference is the direct light alone.
-- luajit glw --3d --background --validate lua "import('test/harnesses/brdf/shade.lua')"
-- OUT=tmp/brdf_shade.png SUN=50 AZIMUTH=30 COMP=1 (compare against the compensated specular) SETTLE=6
local test_scene = import("goluwa/render3d/test_scene.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local Shot = import("goluwa/render3d/shot.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local pvars = import("goluwa/cli/pvars.lua")
local sun_elevation = test_scene.GetNumber("SUN", 50)
local azimuth = test_scene.GetNumber("AZIMUTH", 30)
local compensated = test_scene.GetNumber("COMP", 1) == 1
local settle = test_scene.GetNumber("SETTLE", 6)
local PI = math.pi
pvars.SetSession("r_dither", false)
pvars.SetSession("r_bloom_strength", 0)
pvars.SetSession("r_eye", false)
pvars.SetSession("ddgi_strength", 0)
pvars.SetSession("r_pass_reflections", false)
pvars.SetSession("r_pass_ambient_occlusion", false)
test_scene.Reset{sun = {elevation = sun_elevation, azimuth = azimuth}, clouds = {}, ground_fog_visibility = math.huge}
test_scene.Ground{size = 400, material = test_scene.Matte(0.0)}
local roughnesses = {0.3, 0.5, 0.7, 0.85, 1.0}
local rows = {{name = "white metal", metallic = 1, albedo = 1}, {name = "white dielectric", metallic = 0, albedo = 1}}
local spacing = 1.6
local plates = {}

for ri, row in ipairs(rows) do
	for ci, rough in ipairs(roughnesses) do
		local x = (ci - (#roughnesses + 1) / 2) * spacing
		local z = (ri - 1.5) * spacing
		local material = import("goluwa/render3d/shapes.lua").Material{Color = Color(row.albedo, row.albedo, row.albedo, 1), Roughness = rough, Metallic = row.metallic}
		test_scene.Box{name = row.name .. rough, pos = Vec3(x, 0.05, z), size = Vec3(1.4, 0.1, 1.4), material = material}
		plates[#plates + 1] = {x = x, z = z, roughness = rough, row = row}
	end
end

local se = math.rad(sun_elevation)
local to_sun = Vec3(-math.sin(math.rad(azimuth)) * math.cos(se), math.sin(se), -math.cos(math.rad(azimuth)) * math.cos(se))
local view = {Position = Vec3(0, 7, 6), Rotation = QuatDeg3(-48, 0, 0), FOV = math.rad(60), ExposureLock = 14, LocalExposure = 0}

local function pow5(x)
	local x2 = x * x
	return x2 * x2 * x
end

-- the BRDF as the lighting pass evaluates it, for one channel (white albedo or F0)
local function brdf(plate, V, L, energy, view_albedo)
	local H = (V + L):GetNormalized()
	local nol, nov, noh, loh = L.y, V.y, H.y, L:GetDot(H)
	local rough = plate.roughness
	local alpha = rough * rough
	local a2 = alpha * alpha
	local d = noh * noh * (a2 - 1) + 1
	local D = a2 / (PI * d * d)
	local va2 = math.max(a2, 1e-3)
	local lv = nol * math.sqrt((nov - va2 * nov) * nov + va2)
	local ll = nov * math.sqrt((nol - va2 * nol) * nol + va2)
	local Vis = 0.5 / (lv + ll)
	local f0 = plate.row.metallic == 1 and plate.row.albedo or 0.04
	local F = f0 + (1 - f0) * pow5(1 - loh)
	local spec = D * Vis * F * (compensated and energy or 1)
	-- the diffuse is EON's (rough, energy preserving Oren-Nayar) times what the view's specular does not take, entering
	-- through 1 - F(n.l), divided by the average of that
	local average = f0 + (1 - f0) / 21
	local lov = L:GetDot(V)
	local A = 1 / (1 + (0.5 - 2 / (3 * PI)) * rough)
	local B = rough * A
	local s_term = lov - nol * nov
	local t = s_term > 0 and math.max(nol, nov) or 1
	local mean = A * (1 + (2 / 3 - 28 / (15 * PI)) * rough)

	local function E(mu)
		local x = 1 - mu
		return A + B * x * (0.0571085289 + x * (0.491881867 + x * (-0.332181442 + x * 0.0714429953)))
	end

	local rho = plate.row.albedo
	local eon = (rho * (A + B * s_term / t) + rho * rho * (mean / (1 - rho * (1 - mean))) * ((1 - E(nol)) * (1 - E(nov)) / math.max(1 - mean, 1e-4))) / PI
	local diffuse = (1 - plate.row.metallic) * eon * math.max(1 - view_albedo, 0) * (1 - (f0 + (1 - f0) * pow5(1 - nol))) / math.max(1 - average, 0.001)
	return spec, diffuse
end

-- the directional albedo of the specular with F = 1 (the brdf lut's two channels added), for the compensation 1 + F0 (1 / E - 1)
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
		local phi = 2 * PI * xi1
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

local results = {}

local function measure(texture_source, camera, width, height, pre_exposure)
	local img = texture_source:Download()
	local out = {}

	for i, plate in ipairs(plates) do
		local pos = camera:WorldPositionToScreen(Vec3(plate.x, 0.1, plate.z), img.width, img.height, true)
		local sum = {0, 0, 0}
		local n = 0

		for dy = -6, 6 do
			for dx = -6, 6 do
				local r, g, b = img:GetPixelFloat(math.floor(pos.x) + dx, math.floor(pos.y) + dy)
				sum[1], sum[2], sum[3] = sum[1] + r, sum[2] + g, sum[3] + b
				n = n + 1
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
	results[i] = measure(source, camera, 1920, 1080, exposure / post_source.PRE_EXPOSURE_HEADROOM)

	if i == 1 then
		texture:SaveWithoutAlpha(os.getenv("OUT") or "tmp/brdf_shade.png")
		-- the cube that takes the sun away for the second picture, big enough to cover all the plates
		test_scene.Box{name = "shade", pos = to_sun * 40, size = Vec3(14, 14, 14), material = test_scene.Matte(0.1)}
	end
end, {settle = settle}, function()
	local t = atmosphere.GetTransmittance(to_sun, Vec3(0, 0, 0))
	local color = atmosphere.SUN_COLOR
	local E = atmosphere.GetSunIlluminance()
	local sun = {E * t.x * color.x, E * t.y * color.y, E * t.z * color.z}
	print(string.format("sun %g degrees, direct light (perpendicular) %.0f %.0f %.0f lux, the specular is %s", sun_elevation, sun[1], sun[2], sun[3], compensated and "compensated (Kulla Conty)" or "not compensated"))
	print("plate                    rough   measured (direct, cd/m2)    expected    measured/expected (rgb)")

	for i, plate in ipairs(plates) do
		local V = (view.Position - Vec3(plate.x, 0.1, plate.z)):GetNormalized()
		local alpha = plate.roughness * plate.roughness
		local f0 = plate.row.metallic == 1 and plate.row.albedo or 0.04
		local energy = 1 + f0 * (1 / specular_albedo(alpha, V.y, 1) - 1)
		local spec, diffuse = brdf(plate, V, to_sun, energy, specular_albedo(alpha, V.y, f0) * energy)
		local parts = {}
		local measured = {}

		for c = 1, 3 do
			measured[c] = results[1][i][c] - results[2][i][c]
			local expected = (spec + diffuse) * to_sun.y * sun[c]
			parts[c] = string.format("%.3f", measured[c] / expected)
		end

		local expected_g = (spec + diffuse) * to_sun.y * sun[2]
		print(string.format("%-24s %.2f   %9.0f %9.0f %9.0f   %9.0f   %s %s %s", plate.row.name, plate.roughness, measured[1], measured[2], measured[3], expected_g, parts[1], parts[2], parts[3]))
	end

	system.ShutDown(0)
end)
