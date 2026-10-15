-- local lights against their photometric definition. Matte white plates in a dark night scene (no sun, black ground, no
-- ddgi, reflections or ambient occlusion), lit by one light; the plates' luminance read from the scene before exposure
-- (absolute cd/m2) against albedo / pi * the illuminance the light's definition gives (scene_lights.lua, light.lua):
--   point: E = lumen / (4 pi) * cos(incidence) * window(d / range)^2 / (source radius^2 + constant + linear d + quadratic d^2)
--   spot:  the same with lumen / (2 pi (1 - cos outer cone)) and smoothstep(cos outer, cos inner, cos angle off the axis)
-- luajit glw --3d --background --validate lua "import('test/harnesses/lights/point.lua')"
-- KIND=point|spot H=2 (light height over the plates' top) LUMEN=3000 RANGE=0 (0 is the effective range) RADIUS=0 (source radius)
-- QUAD=1 LINEAR=0 CONSTANT=0 INNER=10 OUTER=20 OFFSETS=0,1,2,3 (plate positions along x) EV=8
local test_scene = import("goluwa/render3d/test_scene.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local Shot = import("goluwa/render3d/shot.lua")
local Entity = import("goluwa/entities/entity.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local pvars = import("goluwa/cli/pvars.lua")
local kind = os.getenv("KIND") or "point"
local height = test_scene.GetNumber("H", 2)
local lumen = test_scene.GetNumber("LUMEN", 3000)
local range = test_scene.GetNumber("RANGE", 0)
local radius = test_scene.GetNumber("RADIUS", 0)
local quadratic = test_scene.GetNumber("QUAD", 1)
local linear = test_scene.GetNumber("LINEAR", 0)
local constant = test_scene.GetNumber("CONSTANT", 0)
local inner = test_scene.GetNumber("INNER", 10)
local outer = test_scene.GetNumber("OUTER", 20)
local ev = test_scene.GetNumber("EV", 8)
local ALBEDO = 0.9
local PLATE_TOP = 0.1
local offsets = {}

for v in (os.getenv("OFFSETS") or "0,1,2,3"):gmatch("[^,]+") do
	offsets[#offsets + 1] = tonumber(v)
end

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

test_scene.Reset{sun = {elevation = -30, azimuth = 0}, clouds = {}, ground_fog_visibility = math.huge}
test_scene.Ground{size = 400, material = test_scene.Matte(0.0)}
local plates = {}

for i, x in ipairs(offsets) do
	local material = test_scene.Matte(Color(ALBEDO, ALBEDO, ALBEDO, 1), 1)
	material:SetSpecularMultiplier(0)
	plates[i] = {x = x}
	test_scene.Box{name = "plate" .. i, pos = Vec3(x, PLATE_TOP / 2, 0), size = Vec3(0.3, PLATE_TOP, 0.3), material = material}
end

local entity = Entity.New{Name = "measured_light"}
entity:AddComponent("transform")
entity.transform:SetPosition(Vec3(0, PLATE_TOP + height, 0))
local light

if kind == "spot" then
	entity.transform:SetRotation(QuatDeg3(-90, 0, 0))
	light = entity:AddComponent("light_spot")
	light:SetInnerCone(inner)
	light:SetOuterCone(outer)
else
	light = entity:AddComponent("light_point")
end

local cr, cg, cb = (os.getenv("COLOR") or "1,1,1"):match("([^,]+),([^,]+),([^,]+)")
light:SetColor(Color(tonumber(cr), tonumber(cg), tonumber(cb), 1))
light:SetLumen(lumen)
light:SetOcclusionMap(false)
light:SetSourceRadius(radius)
light:SetQuadraticFalloff(quadratic)
light:SetLinearFalloff(linear)
light:SetConstantFalloff(constant)

if range > 0 then light:SetRange(range) end

local effective_range = light:GetEffectiveRange()
local solid_angle = light:GetEmissionSolidAngle()
local intensity = lumen / solid_angle

local function smoothstep(a, b, x)
	local t = math.min(math.max((x - a) / (b - a), 0), 1)
	return t * t * (3 - 2 * t)
end

-- the lumens the lamp really emits: the intensity over the sphere, with the cone's falloff
if kind == "spot" then
	local flux, n = 0, 20000

	for i = 0, n - 1 do
		local theta = (i + 0.5) / n * math.pi
		local cone = smoothstep(math.cos(math.rad(outer)), math.cos(math.rad(inner)), math.cos(theta))
		flux = flux + intensity * cone * math.sin(theta) * 2 * math.pi * math.pi / n
	end

	print(string.format("spot cone %g..%g: the lamp emits %.0f lm of its %g (%.3f)", inner, outer, flux, lumen, flux / lumen))
end

local function expected_illuminance(x)
	local d2 = x * x + height * height
	local d = math.sqrt(d2)
	local cos_incidence = height / d
	local ratio = d / effective_range
	local window = math.max(1 - ratio ^ 4, 0)
	local falloff = math.max(radius * radius + constant + linear * d + quadratic * d2, 0.0025)
	local cone = 1

	if kind == "spot" then cone = smoothstep(math.cos(math.rad(outer)), math.cos(math.rad(inner)), cos_incidence) end

	return intensity * cone * cos_incidence * window * window / falloff, intensity * cos_incidence / d2
end

local view = {Position = Vec3(1.5, 9, 4), Rotation = QuatDeg3(-62, 0, 0), FOV = math.rad(50), ExposureLock = ev, LocalExposure = 0}
print(string.format("%s light, %g lm, %g m over the plates, range %.1f m, solid angle %.4f sr, intensity %.1f cd, source radius %g, falloff %g + %g d + %g d^2", kind, lumen, height, effective_range, solid_angle, intensity, radius, constant, linear, quadratic))
Shot.Capture(view, function(texture)
	local source = post_source.GetSceneSourceTexture({name = "blit_compute"}):Download()
	local pre_exposure = post_source.GetExposureTexture():Download():GetPixelFloat(0, 0) / post_source.PRE_EXPOSURE_HEADROOM
	local camera = import("goluwa/render3d/camera3d.lua").New()
	camera:SetFOV(view.FOV)
	camera:SetPosition(view.Position)
	camera:SetRotation(view.Rotation)
	camera:SetViewport(Rect(0, 0, source.width, source.height))
	print("   x      angle   measured lux (L pi / albedo)   expected lux   measured / expected   inverse square only")

	for _, plate in ipairs(plates) do
		local pos = camera:WorldPositionToScreen(Vec3(plate.x, PLATE_TOP, 0), source.width, source.height, true)
		local sum, n = {0, 0, 0}, 0

		for dy = -5, 5 do
			for dx = -5, 5 do
				local r, g, b = source:GetPixelFloat(math.floor(pos.x) + dx, math.floor(pos.y) + dy)
				sum[1], sum[2], sum[3], n = sum[1] + r, sum[2] + g, sum[3] + b, n + 1
			end
		end

		local luminance = (0.2126 * sum[1] + 0.7152 * sum[2] + 0.0722 * sum[3]) / n / pre_exposure
		local measured = luminance * math.pi / ALBEDO
		if os.getenv("COLOR") then print(string.format("      plate rgb / luminance: %.3f %.3f %.3f", sum[1] / n / pre_exposure / luminance, sum[2] / n / pre_exposure / luminance, sum[3] / n / pre_exposure / luminance)) end

		local expected, plain = expected_illuminance(plate.x)
		print(string.format("  %4.2f    %5.1f   %12.2f                %10.2f      %.3f               %10.2f", plate.x, math.deg(math.atan(plate.x / height)), measured, expected, measured / expected, plain))
	end

	system.ShutDown(0)
end, {settle = 6})
