-- prints the clear sky the engine bakes (sky view LUT, absolute cd/m2 before exposure and tonemapping)
-- next to the Hosek-Wilkie model (test/harnesses/sky/hosek.lua) and a few analytic checks.
-- SUN_ELEVS=60,30,10 TURBIDITY=2 ALBEDO=0.26 luajit glw --2d --one-frame --background lua "import('test/harnesses/sky/lut.lua')"
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local sun_elevs = {}

for v in (os.getenv("SUN_ELEVS") or "60,30,10"):gmatch("[^,]+") do
	sun_elevs[#sun_elevs + 1] = tonumber(v)
end

QUIET = os.getenv('QUIET') ~= nil
local turbidity = tonumber(os.getenv("TURBIDITY") or "2")
local rad = math.rad
local SAMPLES = {
	{90, 0},
	{75, 90},
	{75, 180},
	{60, 0},
	{60, 90},
	{60, 180},
	{45, 0},
	{45, 90},
	{45, 180},
	{30, 0},
	{30, 90},
	{30, 180},
	{15, 0},
	{15, 90},
	{15, 180},
	{5, 0},
	{5, 90},
	{5, 180},
	{1, 90},
	{1, 180},
}

local function rgb_to_xyY(r, g, b)
	local X = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
	local Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
	local Z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
	local sum = X + Y + Z
	return sum > 0 and X / sum or 0, sum > 0 and Y / sum or 0, Y
end

local hosek = import("test/harnesses/sky/hosek.lua")
local albedo = tonumber(os.getenv("ALBEDO") or "0.26")

-- theta_s is the sun's zenith angle, theta the view's, gamma the angle between them
local function reference(T, theta_s, theta, gamma)
	local X, Y, Z = hosek.Radiance(hosek.New(T, albedo, math.pi / 2 - theta_s), theta, gamma)
	local sum = X + Y + Z
	return X / sum, Y / sum, Y
end


-- independent single scattering integrator with the engine's constants (km, planet centered)
local R_PLANET, R_ATMOSPHERE = 6371.0, 6471.0
local EYE = 1.75 * 0.001
local RAYLEIGH_BETA = {0.0058, 0.0135, 0.0331}
local OZONE = {0.00065, 0.00188, 0.000085}
if os.getenv("AEROSOL_VIS") then atmosphere.SetAerosolVisibility(tonumber(os.getenv("AEROSOL_VIS"))) end

local ANGSTROM, ALBEDO, MIE_G = 1.3, 0.95, 0.7
local EXT_550 = math.max(-math.log(0.02) / (atmosphere.GetAerosolVisibility() / 1000) - 0.0135, 0)
local MIE_EXT = {EXT_550 * (680 / 550) ^ -ANGSTROM, EXT_550, EXT_550 * (440 / 550) ^ -ANGSTROM}
local MIE_SCA = {MIE_EXT[1] * ALBEDO, MIE_EXT[2] * ALBEDO, MIE_EXT[3] * ALBEDO}
local MIE_H = 1.2

local function densities(radius)
	local alt = math.max(radius - R_PLANET, 0)
	local mie = math.exp(-alt / MIE_H) + 0.07 * math.exp(-alt / 8)
	local ozone = math.max(0, 1 - math.abs(radius - R_PLANET - 25) / 15)
	return math.exp(-alt / 8), mie, ozone
end

local function sphere_far(ox, oy, oz, dx, dy, dz, radius)
	local b = ox * dx + oy * dy + oz * dz
	local c = ox * ox + oy * oy + oz * oz - radius * radius
	local disc = b * b - c

	if disc < 0 then return nil end

	return -b - math.sqrt(disc), -b + math.sqrt(disc)
end

-- optical depth per channel from (x, y) along (dx, dy) to the top of the atmosphere, nil when the planet blocks it
local function light_depth(x, y, dx, dy, dz)
	local near, far = sphere_far(x, y, 0, dx, dy, dz, R_PLANET)

	if near and far > 0 and near > 0 then return nil end

	local _, top = sphere_far(x, y, 0, dx, dy, dz, R_ATMOSPHERE)
	local n = 48
	local ds = top / n
	local r_od, m_od, o_od = 0, 0, 0

	for i = 0, n - 1 do
		local t = (i + 0.5) * ds
		local dr, dm, do_ = densities(math.sqrt((x + dx * t) ^ 2 + (y + dy * t) ^ 2 + (dz * t) ^ 2))
		r_od, m_od, o_od = r_od + dr * ds, m_od + dm * ds, o_od + do_ * ds
	end

	return r_od, m_od, o_od
end

-- sun in the plane: azimuth is folded, only the angle to the sun and the elevations matter, so the sun is placed
-- in the x-y plane and the view direction is rotated around the vertical by the azimuth
local function ss_reference(sun_elev, view_elev, az)
	local sun = {math.cos(sun_elev), math.sin(sun_elev), 0}
	local dir = {math.cos(view_elev) * math.cos(az), math.sin(view_elev), math.cos(view_elev) * math.sin(az)}
	local mu = sun[1] * dir[1] + sun[2] * dir[2] + sun[3] * dir[3]
	local rayleigh_phase = 3 / (16 * math.pi) * (1 + mu * mu)
	local gg = MIE_G * MIE_G
	local mie_phase = 3 * (1 - gg) * (1 + mu * mu) / (8 * math.pi * (2 + gg) * (1 + gg - 2 * MIE_G * mu) ^ 1.5)
	-- the sample point moves in the plane spanned by up and the view direction's horizontal part, the
	-- radius and the angle to the vertical fully describe its position for the light ray
	local steps = 400
	local _, top = sphere_far(math.sqrt(dir[1] ^ 2 + dir[3] ^ 2) * 0, R_PLANET + EYE, 0, math.sqrt(dir[1] ^ 2 + dir[3] ^ 2), dir[2], 0, R_ATMOSPHERE)
	local out = {0, 0, 0}
	local r_od, m_od, o_od = 0, 0, 0

	for i = 0, steps - 1 do
		local s0, s1 = i / steps, (i + 1) / steps
		local t0, t1 = top * s0 * s0, top * s1 * s1
		local t, ds = (t0 + t1) / 2, t1 - t0
		local horiz = math.sqrt(dir[1] ^ 2 + dir[3] ^ 2)
		-- position in the view plane (x = horizontal distance, y = height), planet centered
		local px, py = horiz * t, R_PLANET + EYE + dir[2] * t
		local radius = math.sqrt(px * px + py * py)
		local dr, dm, do_ = densities(radius)
		r_od, m_od, o_od = r_od + dr * ds, m_od + dm * ds, o_od + do_ * ds
		-- the light direction in the plane's (x, y) basis: x is along the horizontal view direction
		local hx = (dir[1] * sun[1] + dir[3] * sun[3]) / horiz
		local hz = (-dir[3] * sun[1] + dir[1] * sun[3]) / horiz
		local lr, lm, lo = light_depth(px, py, hx, sun[2], hz)

		if lr then
			for c = 1, 3 do
				local tau_v = RAYLEIGH_BETA[c] * r_od + MIE_EXT[c] * m_od + OZONE[c] * o_od
				local tau_l = RAYLEIGH_BETA[c] * lr + MIE_EXT[c] * lm + OZONE[c] * lo
				out[c] = out[c] + (RAYLEIGH_BETA[c] * dr * rayleigh_phase + MIE_SCA[c] * dm * mie_phase) * math.exp(-tau_v - tau_l) * ds
			end
		end
	end

	local E = atmosphere.GetSunIlluminance()
	return out[1] * E, out[2] * E, out[3] * E
end

ENGINE = {
	rayleigh = {0.0058, 0.0135, 0.0331},
	ozone = {0.00065, 0.00188, 0.000085},
	mie_ext = MIE_EXT,
	mie_sca = MIE_SCA,
	ground = {0.30, 0.27, 0.22},
	g = MIE_G,
}
MS_ROWS = {}
local frame = 0
event.AddListener("Update", "sky_lut_harness", function()
	frame = frame + 1

	if frame < 3 then return end

	for _, sun_elev in ipairs(sun_elevs) do
		local se = rad(sun_elev)
		local sun = Vec3(math.cos(se), math.sin(se), 0)
		local tex = atmosphere.GetSkyViewTexture(Vec3(0, 0, 0), sun)
		local img = tex:Download()
		local w, h = img.width, img.height
		local trans = atmosphere.GetTransmittance(sun, Vec3(0, 0, 0))
		print(
			string.format(
				"\n=== sun elevation %g deg, hosek turbidity %g, albedo %g, direct sun transmittance %.3f %.3f %.3f, direct horizontal %.0f lux",
				sun_elev,
				turbidity,
				albedo,
				trans.x,
				trans.y,
				trans.z,
				atmosphere.GetSunIlluminance() * trans.y * math.sin(se)
			)
		)
		-- illuminance the clear sky puts on a horizontal surface, integrated over the dome in the LUT
		local e_sky, zenith_sum = 0, 0
		local az_n, el_n = 120, 90

		for j = 0, el_n - 1 do
			local el = (j + 0.5) / el_n * math.pi / 2
			local v = math.sqrt(el / math.pi + 0.5)
			local py = math.min(h - 1, math.floor(v * h))

			for i = 0, az_n - 1 do
				local az = (i + 0.5) / az_n * 2 * math.pi - math.pi
				local u = az / (2 * math.pi) + 0.5
				local r, g, b = img:GetPixelFloat(math.min(w - 1, math.floor(u * w)), py)
				local Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
				e_sky = e_sky + Y * math.cos(math.pi / 2 - el) * math.cos(el) * (math.pi / 2 / el_n) * (2 * math.pi / az_n)
			end
		end

		local e_pre = 0

		for j = 0, el_n - 1 do
			local el = (j + 0.5) / el_n * math.pi / 2

			for i = 0, az_n - 1 do
				local az = (i + 0.5) / az_n * 2 * math.pi - math.pi
				local dir = Vec3(math.cos(el) * math.cos(az), math.sin(el), math.cos(el) * math.sin(az))
				local gamma = math.acos(math.max(-1, math.min(1, dir:Dot(sun))))
				local _, _, Y = reference(turbidity, math.pi / 2 - se, math.pi / 2 - el, gamma)
				e_pre = e_pre + Y * math.sin(el) * math.cos(el) * (math.pi / 2 / el_n) * (2 * math.pi / az_n)
			end
		end

		print(string.format("  hosek sky illuminance on the same surface: %.0f lux", e_pre))
		local e_direct = atmosphere.GetSunIlluminance() * (0.2126729 * trans.x + 0.7151522 * trans.y + 0.0721750 * trans.z) * math.sin(se)
		print(
			string.format(
				"  horizontal illuminance: direct %.0f lux, sky %.0f lux, global %.0f lux, diffuse fraction %.2f",
				e_direct,
				e_sky,
				e_direct + e_sky,
				e_sky / (e_direct + e_sky)
			)
		)
		print("  elev az(from sun)   engine Y cd/m2   x      y     |  hosek Y      x      y     | Y ratio  dx     dy")

		local n, sum_log, sum_far, n_far, sum_xy = 0, 0, 0, 0, 0
		mc_n, mc_sum, mc_bias = 0, 0, 0

		for _, s in ipairs(SAMPLES) do
			local el, az = rad(s[1]), rad(s[2])
			local dir = Vec3(
				math.cos(el) * math.cos(az),
				math.sin(el),
				math.cos(el) * math.sin(az)
			)
			-- the LUT: u = azimuth from the sun / 2pi + 0.5, v = sqrt(elevation / pi + 0.5)
			local u = az / (2 * math.pi) + 0.5
			local v = math.sqrt(el / math.pi + 0.5)
			local px = math.min(w - 1, math.floor(u * w))
			local py = math.min(h - 1, math.floor((v) * h))
			local r, g, b = img:GetPixelFloat(px, py)
			local ex, ey, eY = rgb_to_xyY(r, g, b)
			local gamma = math.acos(math.max(-1, math.min(1, dir:Dot(sun))))
			local px_, py_, pY = reference(turbidity, math.pi / 2 - se, math.pi / 2 - el, gamma)
			if os.getenv("MC") then
				local mc = import("test/harnesses/sky/mc.lua")
				local N = tonumber(os.getenv("MC"))
				local rgb, rgb1 = {}, {}

				for c = 1, 3 do
					local k = {
						rayleigh = ENGINE.rayleigh[c],
						ozone = ENGINE.ozone[c],
						mie_ext = ENGINE.mie_ext[c],
						mie_sca = ENGINE.mie_sca[c],
						albedo = ENGINE.ground[c],
						g = ENGINE.g,
						h = 1.2,
					}
					rgb[c] = mc.Radiance(k, sun.x, sun.y, sun.z, dir.x, dir.y, dir.z, N, 100, atmosphere.GetSunIlluminance())
					rgb1[c] = mc.Radiance(k, sun.x, sun.y, sun.z, dir.x, dir.y, dir.z, N, 1, atmosphere.GetSunIlluminance())
				end

				local mx, my, mY = rgb_to_xyY(rgb[1], rgb[2], rgb[3])
				local _, _, mY1 = rgb_to_xyY(rgb1[1], rgb1[2], rgb1[3])

				if math.deg(gamma) > 20 then
					mc_n = mc_n + 1
					mc_sum = mc_sum + math.log(eY / mY) ^ 2
					mc_bias = mc_bias + math.log(eY / mY)
				end

				if os.getenv("MSFIT") and (s[2] == 90 or s[2] == 180) then
					local sr, sg, sb = ss_reference(se, el, az)
					local engine_multi = eY - (0.2126729 * sr + 0.7151522 * sg + 0.0721750 * sb)

					if engine_multi > 50 and mY - mY1 > 50 then
						MS_ROWS[#MS_ROWS + 1] = {1 - math.sin(el), math.sin(se), math.log(math.max(MIE_EXT[2], 1e-4) / 0.0568), math.log((mY - mY1) / engine_multi)}
					end
				end

				if os.getenv("MS") then
					local sr, sg, sb = ss_reference(se, el, az)
					local ssY = 0.2126729 * sr + 0.7151522 * sg + 0.0721750 * sb
					print(string.format("    el %2g az %3g  MC: single %6.0f multi %6.0f | engine: multi %6.0f  (engine/MC multi %.2f, engine single/MC single %.3f)", s[1], s[2], mY1, mY - mY1, eY - ssY, (eY - ssY) / (mY - mY1), ssY / mY1))
				end

				if not QUIET then
					print(string.format("    MC all orders Y %8.0f x %.4f y %.4f | MC single Y %8.0f | engine/MC %.3f dx %+.4f dy %+.4f", mY, mx, my, mY1, eY / mY, ex - mx, ey - my))
				end
			end

			if os.getenv("SS") then
				local sr, sg, sb = ss_reference(se, el, az)
				print(string.format("    luaSS Y %8.0f engine Y %8.0f ratio %.3f", 0.2126729 * sr + 0.7151522 * sg + 0.0721750 * sb, eY, eY / (0.2126729 * sr + 0.7151522 * sg + 0.0721750 * sb)))
			end

			n = n + 1
			sum_log = sum_log + math.log(eY / pY) ^ 2
			sum_xy = sum_xy + (ex - px_) ^ 2 + (ey - py_) ^ 2

			if math.deg(gamma) > 40 then
				n_far = n_far + 1
				sum_far = sum_far + math.log(eY / pY) ^ 2
			end

			if not QUIET then
			print(
				string.format(
					"  %4g  %4g        %10.0f    %.4f %.4f |  %10.0f   %.4f %.4f | %5.2f  %+.4f %+.4f",
					s[1],
					s[2],
					eY,
					ex,
					ey,
					pY,
					px_,
					py_,
					eY / pY,
					ex - px_,
					ey - py_
				)
			)
			end
		end

		if mc_n > 0 then
			print(string.format("  MCSCORE sun %g: rms log2 engine/MC %.3f, bias %+.3f stops", sun_elev, math.sqrt(mc_sum / mc_n) / math.log(2), mc_bias / mc_n / math.log(2)))
		end

		print(
			string.format(
				"  SCORE sun %g: rms log2 Y %.3f (away from the sun %.3f), rms xy %.4f",
				sun_elev,
				math.sqrt(sum_log / n) / math.log(2),
				math.sqrt(sum_far / n_far) / math.log(2),
				math.sqrt(sum_xy / n)
			)
		)
	end

	if #MS_ROWS > 0 then
		local f = assert(io.open("tmp/ms_rows.txt", "ab"))

		for _, row in ipairs(MS_ROWS) do
			f:write(string.format("%.6f %.6f %.6f %.6f\n", row[1], row[2], row[3], row[4]))
		end

		f:close()
	end

	system.ShutDown(0)
end)
