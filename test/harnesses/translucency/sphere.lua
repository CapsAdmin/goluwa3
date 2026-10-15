-- A glass ball in front of a wall of emissive stripes, the stripe's index encoded in its colour, against an exact ray trace of the
-- same ball (refracting in, through the inside, out; reflections and total internal reflection followed to a few bounces).
-- Each pixel of the ball's row names the stripe the engine shows and the stripe the exact trace arrives at; the difference in
-- meters on the wall is the error of the pass's refraction (screen space march, the sphere approximated from the surface's
-- curvature). luajit glw --3d --background --validate lua "import('test/harnesses/translucency/sphere.lua')"
-- TINT_R/G/B=1 ATTENUATION=0 (the glass's color, reached after ATTENUATION meters of it, 0 is the color taken once; the transmitted brightness line then checks the blue channel)
-- NOPROBE=1 turns the environment probes off (what the pass falls back to when the screen does not hold the ray's target), FOVDEG=24 WIDE=1 (score rays that land off screen but on the wall)
-- IOR=1.5 RADIUS=1 THICKNESS=<diameter, the pass's solid model; 0 is a thin wall> DIST=4 WALL=9 ROW=0 (a fraction of the image height from the centre) EV=8
local test_scene = import("goluwa/render3d/test_scene.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local pvars = import("goluwa/cli/pvars.lua")
local ior = test_scene.GetNumber("IOR", 1.5)
local radius = test_scene.GetNumber("RADIUS", 1)
local thickness = test_scene.GetNumber("THICKNESS", 2 * radius)
local dist = test_scene.GetNumber("DIST", 4)
local wall_z = -test_scene.GetNumber("WALL", 9)
local row = test_scene.GetNumber("ROW", 0)
local ev = test_scene.GetNumber("EV", 8)
local fov = math.rad(test_scene.GetNumber("FOVDEG", 40))
local STRIPE, STRIPES = 0.2, 80
local ALBEDO = 0.03

for key, value in pairs{r_dither = false, r_eye = false, r_bloom_strength = 0, r_camera_white_balance = 6500} do
	pvars.SetSession(key, value)
end

for pair in (os.getenv("PVARS") or ""):gmatch("[^,]+") do
	local k, v = pair:match("^([^=]+)=(.*)$")

	if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end

	pvars.SetSession(k, v)
end

if os.getenv("NOPROBE") then import("goluwa/render3d/envprobe.lua").SetEnabled(false) end
test_scene.Reset{sun = {elevation = -40, azimuth = 0}, clouds = {}, ground_fog_visibility = math.huge}
local centre = Vec3(test_scene.GetNumber("XOFF", 0), 0, -dist)

for i = 0, STRIPES - 1 do
	-- red is the index within 8, green the index over 8, both 0 to 1; blue is 0.1 so a black pixel is not a stripe
	local r, g = (i % 8) / 7, math.floor(i / 8) / 9
	test_scene.Box{
		name = "stripe" .. i,
		pos = Vec3((i + 0.5) * STRIPE - STRIPES * STRIPE / 2, 0, wall_z),
		size = Vec3(STRIPE, 12, 0.1),
		material = shapes.Material{
			Color = Color(math.max(r, 0.02) * ALBEDO, math.max(g, 0.02) * ALBEDO, 0.1 * ALBEDO, 1),
			Roughness = 1,
			Metallic = 0,
			AlbedoAlphaIsEmissive = true,
			EmissiveMultiplier = Color(1, 1, 1, 1 / ALBEDO),
		},
	}
end

test_scene.Sphere = nil
local ball = shapes.Sphere{
	Position = centre,
	Radius = radius,
	Material = shapes.Material{
		Refraction = 1,
		IndexOfRefraction = ior,
		RefractionThickness = thickness,
		AttenuationDistance = test_scene.GetNumber("ATTENUATION", 0),
		Roughness = 0.001,
		Metallic = 0,
		ColorMultiplier = Color(test_scene.GetNumber("TINT_R", 1), test_scene.GetNumber("TINT_G", 1), test_scene.GetNumber("TINT_B", 1), 1),
	},
	Collision = false,
	RigidBody = false,
}
test_scene.GetRoot():AddChild(ball)

-- the exact trace: a ray leaves the origin through (x_ndc, y_ndc); returns the x on the wall plane or nil
local function refract(d, n, eta)
	local cos_i = -d:GetDot(n)
	local k = 1 - eta * eta * (1 - cos_i * cos_i)

	if k < 0 then return nil end

	return d * eta + n * (eta * cos_i - math.sqrt(k))
end

local function sphere_hit(o, d)
	local oc = o - centre
	local b = oc:GetDot(d)
	local c = oc:GetDot(oc) - radius * radius
	local disc = b * b - c

	if disc < 0 then return nil end

	local s = math.sqrt(disc)

	return -b - s, -b + s
end

local function fresnel(cos_i, n1, n2)
	local sin_t = n1 / n2 * math.sqrt(math.max(1 - cos_i * cos_i, 0))
	if sin_t >= 1 then return 1 end
	local cos_t = math.sqrt(1 - sin_t * sin_t)
	local rs = (n1 * cos_i - n2 * cos_t) / (n1 * cos_i + n2 * cos_t)
	local rp = (n1 * cos_t - n2 * cos_i) / (n1 * cos_t + n2 * cos_i)
	return 0.5 * (rs * rs + rp * rp)
end

local ATTENUATION = test_scene.GetNumber("ATTENUATION", 0)
local TINT = {test_scene.GetNumber("TINT_R", 1), test_scene.GetNumber("TINT_G", 1), test_scene.GetNumber("TINT_B", 1)}

local function trace(x_ndc, y_ndc, half_w, half_h)
	local o = Vec3(0, 0, 0)
	local d = Vec3(x_ndc * half_w, y_ndc * half_h, -1):GetNormalized()
	local t_in = sphere_hit(o, d)

	if not t_in then return nil end

	local p = o + d * t_in
	local n = (p - centre):GetNormalized()
	local inside = refract(d, n, 1 / ior)
	-- the light that gets through: the front surface, the glass (absorbing along the chord), the exit surface
	local weight = 1 - fresnel(-d:GetDot(n), 1, ior)
	local chord = 0
	d, o = inside, p

	for bounce = 1, 4 do
		local _, t_out = sphere_hit(o, d)
		o = o + d * t_out
		chord = chord + t_out
		local n_out = (centre - o):GetNormalized()
		local out = refract(d, n_out, ior)

		if out then
			weight = weight * (1 - fresnel(-d:GetDot(n_out), ior, 1))
			d = out
			break
		end

		-- total internal reflection
		d = d - n_out * (2 * d:GetDot(n_out))
		if bounce == 4 then return nil end
	end

	if d.z >= 0 then return nil end

	local t = (wall_z - o.z) / d.z

	return o.x + d.x * t, weight, chord
end

test_scene.WhenReady(function()
	local Shot = import("goluwa/render3d/shot.lua")
	Shot.Capture({Position = Vec3(0, 0, 0), Rotation = QuatDeg3(0, 0, 0), FOV = fov, ExposureLock = ev, LocalExposure = 0}, function(texture, info)
		local source = post_source.GetSceneSourceTexture({name = "blit_compute"}):Download()
		local pre = post_source.GetExposureTexture():Download():GetPixelFloat(0, 0) / post_source.PRE_EXPOSURE_HEADROOM
		local w, h = source.width, source.height
		local half_h = math.tan(fov / 2)
		local half_w = half_h * w / h
		local py = math.floor(h / 2 - row * h)
		local ref = render3d.EMISSIVE_REFERENCE_LUMINANCE
		local ndc_y = -(py / h * 2 - 1) * -1
		ndc_y = (1 - 2 * (py + 0.5) / h)
		local errors, count, worst, worst_px = 0, 0, 0, 0
		local within, far, first_px, last_px, edge_first, edge_last = 0, 0, nil, nil, nil, nil
		local half_within, half_count = {0, 0}, {0, 0}
		local dark = 0
		local bright_sum, bright_sq, bright_n = 0, 0, 0
		local centre_px = math.floor(w * (0.5 + centre.x / (-centre.z) / (2 * half_w)))
		local lines = {}
		local sphere_pixels = 0

		for px = 0, w - 1 do
			local x_ndc = 2 * (px + 0.5) / w - 1
			local exact, weight, chord = trace(x_ndc, ndc_y, half_w, half_h)

			-- a ray that lands beyond the visible part of the wall (5.5 m at 9 m) has no stripe to compare with
			if exact and math.abs(exact) < (os.getenv("WIDE") and 7.8 or 5.5) then
				sphere_pixels = sphere_pixels + 1
				local r, g, b = source:GetPixelFloat(px, py)
				r, g, b = r / pre / ref, g / pre / ref, b / pre / ref
				-- what comes through is scaled (the Fresnel factor, a tint): the stripes' blue is a constant 0.1, so it is the scale
				local scale = math.max(b / 0.1, 1e-6)
				local tint_r = ATTENUATION > 0 and TINT[1] ^ (chord / ATTENUATION) or TINT[1]
				local tint_g = ATTENUATION > 0 and TINT[2] ^ (chord / ATTENUATION) or TINT[2]
				local tint_b = ATTENUATION > 0 and TINT[3] ^ (chord / ATTENUATION) or TINT[3]
				-- the glass takes its own share of each channel, which the exact trace knows
				r, g = r / scale * tint_b / tint_r, g / scale * tint_b / tint_g
				local i_r, i_g = math.floor(r * 7 + 0.5), math.floor(g * 9 + 0.5)
				local index = i_g * 8 + i_r
				local engine_x = (index + 0.5) * STRIPE - STRIPES * STRIPE / 2
				if b > 0.03 and weight then
					-- the scale is read off the blue channel
					local tint = ATTENUATION > 0 and TINT[3] ^ (chord / ATTENUATION) or TINT[3]
					local ratio = scale / (weight * tint)
					bright_sum, bright_sq, bright_n = bright_sum + ratio, bright_sq + ratio * ratio, bright_n + 1
				end

				local looks_like_stripe = b > 0.03 and b < 0.12 and r > -0.2 and r < 1.2 and g > -0.2 and g < 1.2
				local err = looks_like_stripe and (engine_x - exact) or nil

				if not looks_like_stripe then dark = dark + 1 end

				first_px, last_px = first_px or px, px

				if err then
					errors, count = errors + err * err, count + 1

					local side = px < centre_px and 1 or 2
					half_count[side] = half_count[side] + 1

					if math.abs(err) <= 0.15 then within = within + 1 half_within[side] = half_within[side] + 1 end

					if math.abs(err) > 0.5 then
						far = far + 1
						edge_first = edge_first or px
						edge_last = px
					end

					if math.abs(err) > worst then worst, worst_px = math.abs(err), px end
				end

				if px % 12 == 0 then
					lines[#lines + 1] = string.format("    px %4d  exact wall x %7.3f  engine %s", px, exact, err and string.format("%7.3f (error %+.3f)", engine_x, err) or string.format("not a stripe (rgb %.2f %.2f %.2f)", r, g, b))
				end
			end
		end

		print(string.format("SPHERE ior %.2f radius %.1f thickness %.1f dist %.1f wall %.0f: %d ball pixels, %d read as stripes, rms error %.3f m on the wall (the stripes are %.2f m), worst %.3f m at px %d", ior, radius, thickness, dist, -wall_z, sphere_pixels, count, count > 0 and math.sqrt(errors / count) or 0, STRIPE, worst, worst_px))

		if bright_n > 0 then
			local mean = bright_sum / bright_n
			print(string.format("SPHERE   transmitted brightness over the exact Fresnel and absorption: mean %.4f, rms spread %.4f over %d pixels", mean, math.sqrt(math.max(bright_sq / bright_n - mean * mean, 0)), bright_n))
		end

		print(string.format("SPHERE   of all %d ball pixels that land on the wall: %.1f percent within 0.15 m, %.1f percent wrong by more than 0.5 m, %.1f percent not a stripe at all (dark, a black edge)", sphere_pixels, 100 * within / math.max(sphere_pixels, 1), 100 * far / math.max(sphere_pixels, 1), 100 * dark / math.max(sphere_pixels, 1)))
		print(string.format("SPHERE   %.1f percent of the ball's pixels within 0.15 m of the exact trace, %.1f percent more than 0.5 m off; the ball spans px %d to %d, the large errors px %s to %s", 100 * within / math.max(count, 1), 100 * far / math.max(count, 1), first_px or 0, last_px or 0, tostring(edge_first), tostring(edge_last)))

		print(string.format("SPHERE   left of the axis %.1f percent within, right of it %.1f percent", 100 * half_within[1] / math.max(half_count[1], 1), 100 * half_within[2] / math.max(half_count[2], 1)))

		if os.getenv("LINES") then print(table.concat(lines, "\n")) end

		texture:SaveWithoutAlpha("tmp/translucency_sphere.png")
		system.ShutDown(0)
	end, {settle = 3, max_settle = 6})
end)
