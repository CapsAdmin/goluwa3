-- emissive surfaces. 1) the units: an emissive plate seen directly shows `strength * albedo * EMISSIVE_REFERENCE_LUMINANCE`
-- cd/m2. 2) what an emitter does to its surroundings, which is DDGI alone (an emissive surface is not a light): white
-- plates under a flat emitter of known luminance in a night scene (no sun, black ground), their luminance against
-- albedo / pi * E with E = L_e * integral of cos cos / d^2 over the emitter (numerically), the mean over frames and
-- the frame to frame noise, with the emitter samples (the default) or without (PVARS=ddgi_emitters=false, the
-- rays then carry the emission).
-- luajit glw --3d --background --validate lua "import('test/harnesses/lights/emissive.lua')"
-- COUNT=1 (emitters, the first over x = 0) SPACING=1.5 (m between the others) SHAPE=thin|wide|tiny (thin: 3 m x 0.04 m, wide: 2 m x 2 m, tiny: 5 cm x 5 cm) STRENGTH=1 HEIGHT=1.5 OFFSETS=0,1.5,3 PVARS=k=v,k=v FRAMES=24 GAP=6 SETTLE=10 EV=8
local test_scene = import("goluwa/render3d/test_scene.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local View = import("goluwa/render3d/view.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local pvars = import("goluwa/cli/pvars.lua")
local shape = os.getenv("SHAPE") or "thin"
local strength = test_scene.GetNumber("STRENGTH", 1)
local height = test_scene.GetNumber("HEIGHT", 1.5)
local frames = test_scene.GetNumber("FRAMES", 24)
local gap = test_scene.GetNumber("GAP", 6)
local ev = test_scene.GetNumber("EV", 8)
local ALBEDO = 0.9
local PLATE_TOP = 0.1
local size_x, size_z = 3, 0.04

if shape == "wide" then size_x, size_z = 2, 2 elseif shape == "tiny" then size_x, size_z = 0.05, 0.05 end

local offsets = {}

for v in (os.getenv("OFFSETS") or "0,1.5,3"):gmatch("[^,]+") do
	offsets[#offsets + 1] = tonumber(v)
end

for key, value in pairs{r_dither = false, r_eye = false, r_bloom_strength = 0, r_camera_white_balance = 6500} do
	pvars.SetSession(key, value)
end

for pair in (os.getenv("PVARS") or ""):gmatch("[^,]+") do
	local k, v = pair:match("^([^=]+)=(.*)$")

	if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end

	pvars.SetSession(k, v)
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

-- the emitter faces down, a thin box whose bottom face is the emitting side, centred over x = 0
local emitter = shapes.Material{
	Color = Color(1, 1, 1, 1),
	Roughness = 1,
	Metallic = 0,
	AlbedoAlphaIsEmissive = true,
	EmissiveMultiplier = Color(1, 1, 1, strength),
}
local emitter_y = PLATE_TOP + height
-- COUNT emitters (the first over x = 0, the rest on a grid around it) for the sampler's grid and candidates
local count_emitters = math.floor(test_scene.GetNumber("COUNT", 1))
local emitter_positions = {}

for k = 1, count_emitters do
	local x, z = 0, 0

	if k > 1 then
		local spacing = test_scene.GetNumber("SPACING", 1.5)
		x, z = (((k - 2) % 8) - 3.5) * spacing, (math.floor((k - 2) / 8) - 1.5) * spacing
	end

	emitter_positions[k] = {x, z}
	test_scene.Box{name = "emitter" .. k, pos = Vec3(x, emitter_y + 0.01, z), size = Vec3(size_x, 0.02, size_z), material = emitter}
end

local LUMINANCE = strength * 1.0 * render3d.EMISSIVE_REFERENCE_LUMINANCE

-- illuminance at (x, PLATE_TOP, 0) facing up from the emitter's lower face, a grid over the emitter
local function illuminance(x)
	local n = count_emitters > 1 and 24 or 200
	local sum = 0
	local da = size_x * size_z / (n * n)

	for _, e in ipairs(emitter_positions) do
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				local px = e[1] - size_x / 2 + (i + 0.5) / n * size_x
				local pz = e[2] - size_z / 2 + (j + 0.5) / n * size_z
				local dx, dz = px - x, pz
				local d2 = dx * dx + dz * dz + height * height
				local cos = height / math.sqrt(d2)
				sum = sum + cos * cos / d2 * da
			end
		end
	end

	return LUMINANCE * sum
end

local view = {Position = Vec3(1.5, 4.5 + 1.5 * height, 3 + height), Rotation = QuatDeg3(-50, 0, 0), FOV = math.rad(55), ExposureLock = ev, LocalExposure = 0}
print(string.format("%s emitter %gx%g m, strength %g (%.0f cd/m2) at %g m over the plates", shape, size_x, size_z, strength, LUMINANCE, height))
do
	View.New{Priority = 100, Position = view.Position, Rotation = view.Rotation, FOV = view.FOV, ExposureLock = ev, LocalExposure = 0}:Activate()
	local settle_frames = math.floor(test_scene.GetNumber("SETTLE", 10) * 60)
	local camera = import("goluwa/render3d/camera3d.lua").New()
	camera:SetFOV(view.FOV)
	camera:SetPosition(view.Position)
	camera:SetRotation(view.Rotation)
	local samples = {}

	for i = 1, #plates do
		samples[i] = {}
	end

	local function read()
		local source = post_source.GetSceneSourceTexture({name = "blit_compute"}):Download()
		local pre = post_source.GetExposureTexture():Download():GetPixelFloat(0, 0) / post_source.PRE_EXPOSURE_HEADROOM
		camera:SetViewport(Rect(0, 0, source.width, source.height))

		for i, plate in ipairs(plates) do
			local pos = camera:WorldPositionToScreen(Vec3(plate.x, PLATE_TOP, 0), source.width, source.height, true)
			local sum, n = 0, 0

			for dy = -5, 5 do
				for dx = -5, 5 do
					local r, g, b = source:GetPixelFloat(math.floor(pos.x) + dx, math.floor(pos.y) + dy)
					sum, n = sum + 0.2126 * r + 0.7152 * g + 0.0722 * b, n + 1
				end
			end

			samples[i][#samples[i] + 1] = sum / n / pre
		end

		-- the first emitter seen directly, its own pixels
		local pos = camera:WorldPositionToScreen(Vec3(0, emitter_y + 0.02, 0), source.width, source.height, true)
		local r, g, b = source:GetPixelFloat(math.floor(pos.x), math.floor(pos.y))
		samples.emitter = samples.emitter or {}
		samples.emitter[#samples.emitter + 1] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / pre
	end

	local count, frame = 0, 0
	event.AddListener("FrameEnd", "emissive_harness", function()
		frame = frame + 1

		if frame < settle_frames or frame % gap ~= 0 then return end

		read()
		count = count + 1

		if count < frames then return end

		event.RemoveListener("FrameEnd", "emissive_harness")

		local function stats(list)
			local sum, sq = 0, 0

			for _, v in ipairs(list) do
				sum = sum + v
			end

			local mean = sum / #list

			for _, v in ipairs(list) do
				sq = sq + (v - mean) ^ 2
			end

			local peak = 0

			for _, v in ipairs(list) do
				peak = math.max(peak, math.abs(v - mean))
			end

			return mean, math.sqrt(sq / #list), peak / mean
		end

		local mean_e = stats(samples.emitter)
		print(string.format("emitter seen directly: %.0f cd/m2 against %.0f expected", mean_e, LUMINANCE))
		print("   x     mean lux (L pi / albedo)   expected lux   mean / expected   frame to frame noise (std / mean), worst frame")

		for i, plate in ipairs(plates) do
			local mean, std, worst = stats(samples[i])
			local expected = illuminance(plate.x)
			print(string.format("  %4.2f   %12.2f              %10.2f      %.3f             %.1f%%   %.0f%%", plate.x, mean * math.pi / ALBEDO, expected, mean * math.pi / ALBEDO / expected, std / mean * 100, worst * 100))
		end

		system.ShutDown(0)
	end)
end
