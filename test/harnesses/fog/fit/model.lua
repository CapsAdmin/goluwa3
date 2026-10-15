-- An offline model of the fog layer's light along a sky ray, luminance only, the same formulas as atmosphere.lua's
-- get_ground_fog_sun, get_ground_fog_sky_ambient and the froxel integration (it reproduces the engine within 1 percent
-- for the model it held, which is what makes fitting it worth it: a parameter set costs milliseconds, not a minute of GPU).
-- Parameters p: n octaves, a b c octave weights, multi_k thickness weight of the octaves, d2 kd the thickness weighted
-- irradiance term, m_amb how much of the sky's mean radiance the thickness takes away. Run fit.lua / opt.lua from the
-- repository root.
local M = {}
local H, TOP, SOFT, G = 0.28, 1.1, 0.3, 0.6
local EYE_FALLOFF = math.exp(-0.00175 / H)

local function smoothstep(a, b, x)
	if x <= a then return 0 end
	if x >= b then return 1 end
	local t = (x - a) / (b - a)
	return t * t * (3 - 2 * t)
end

function M.ext0(vis) return 3.912 / (vis / 1000) / EYE_FALLOFF end

local function ext_at(ext0, h)
	if h >= TOP then return 0 end
	h = math.max(h, 0)
	return ext0 * math.exp(-h / H) * (1 - smoothstep(math.max(TOP - SOFT, 0), TOP, h))
end

local function hg(mu, g)
	local gg = g * g
	return (1 - gg) / (4 * math.pi * math.max(1 + gg - 2 * g * mu, 1e-4) ^ 1.5)
end

-- closed form of the layer's optical depth above altitude h along the sun's slant
local function sun_t(h, sun_up, ext0, scale)
	if h >= TOP then return 1 end
	h = math.max(h, 0)
	local od = ext0 * scale * H * (math.exp(-h / H) - math.exp(-TOP / H))
	return math.exp(-od / math.max(sun_up, 0.05))
end

-- sky = {sun_el (deg), e_perp (Y of the sun's irradiance perpendicular), amb (Y of sky_light)}
-- p = parameters: {n, a, b, c, diff, diff_shape, amb_scale, multi_k}
function M.radiance(sky, p, vis, elev, az, clear)
	local ext0 = M.ext0(vis)
	local s, e, a = math.rad(sky.sun_el), math.rad(elev), math.rad(az)
	local sun_up = math.sin(s)
	local mu = math.cos(e) * math.cos(a) * math.cos(s) + math.sin(e) * math.sin(s)
	local layer_od = ext0 * H * (1 - math.exp(-TOP / H))
	local t_layer = math.exp(-layer_od / math.max(sun_up, 0.05))
	local m_thick = 1 - math.exp(-layer_od)
	local scattered, trans = 0, 1
	local t_max = TOP / math.max(math.sin(e), 0.01)
	local steps = 400
	local prev = 0

	for i = 1, steps do
		-- geometric steps from 1 m
		local t = 0.001 * ((t_max / 0.001) ^ (i / steps))
		local mid = 0.5 * (prev + t)
		local dt = t - prev
		prev = t
		local h = mid * math.sin(e) + 0.00175
		local ext = ext_at(ext0, h)

		if ext > 0 then
			-- the sun's term
			local sun = 0
			local aw, bw, cw = 1, 1, 1

			for n = 0, p.n - 1 do
				local w = n == 0 and 1 or (p.multi_k > 0 and m_thick ^ p.multi_k or 1)
				sun = sun + aw * w * sun_t(h, sun_up, ext0, bw) * hg(mu, G * cw)
				aw, bw, cw = aw * p.a, bw * p.b, cw * p.c
			end

			local diffuse
			local tau_above = ext0 * H * (math.exp(-math.max(h, 0) / H) - math.exp(-TOP / H))
			if p.diff_shape == 2 then
				diffuse = p.diff * sky.e_perp * sun_up * (1 - t_layer) / math.pi / (1 + p.kappa * tau_above)
			elseif p.diff_shape == 3 then
				diffuse = p.diff * sky.e_perp * sun_up * m_thick / math.pi / (1 + p.kappa * tau_above)
			elseif p.diff_shape == 6 then
				diffuse = p.diff * sky.e_perp * sun_up * (1 - sun_t(h, sun_up, ext0, 1)) / math.pi
					+ p.d2 * m_thick ^ p.kd * (sky.e_sky + sky.e_perp * sun_up) / math.pi / (1 + p.kappa * tau_above)
			elseif p.diff_shape == 5 then
				diffuse = p.diff * sky.e_perp * sun_up * (1 - sun_t(h, sun_up, ext0, 1)) / math.pi / (1 + p.kappa * tau_above)
			elseif p.diff_shape == 4 then
				diffuse = p.diff * sky.e_perp * sun_up * (1 - sun_t(h, sun_up, ext0, 1)) / math.pi + p.diff2 * sky.e_perp * sun_up * m_thick / math.pi / (1 + p.kappa * tau_above)
			elseif p.diff_shape == 0 then
				diffuse = p.diff * sky.e_perp * sun_up * (1 - sun_t(h, sun_up, ext0, 1)) / math.pi
			else
				diffuse = p.diff * sky.e_perp * sun_up * (1 - t_layer) / math.pi
			end

			local lit = p.amb_scale * sky.amb * (1 - (p.m_amb or 0) * m_thick) / (1 + (p.kappa_amb or 0) * tau_above) + sky.e_perp * sun + diffuse
			local step_t = math.exp(-ext * dt)
			scattered = scattered + trans * lit * (1 - step_t)
			trans = trans * step_t
		end
	end

	return scattered + trans * clear
end

return M
