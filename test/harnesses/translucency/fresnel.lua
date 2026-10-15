-- The dielectric the translucent pass models against the exact unpolarised Fresnel equations. The pass reflects
-- F_Schlick(F0 = ((n - 1) / (n + 1))^2) and transmits 1 - F, one interface. What a thin pane really does (two surfaces,
-- the light bouncing between them) and what a solid does when the ray leaves it (total internal reflection) is printed
-- next to it. luajit test/harnesses/translucency/fresnel.lua
local function fresnel(cos_i, n1, n2)
	local sin_t = n1 / n2 * math.sqrt(math.max(1 - cos_i * cos_i, 0))
	if sin_t >= 1 then return 1 end
	local cos_t = math.sqrt(1 - sin_t * sin_t)
	local rs = ((n1 * cos_i - n2 * cos_t) / (n1 * cos_i + n2 * cos_t)) ^ 2
	local rp = ((n1 * cos_t - n2 * cos_i) / (n1 * cos_t + n2 * cos_i)) ^ 2
	return 0.5 * (rs + rp)
end

local function schlick(f0, mu) return f0 + (1 - f0) * (1 - mu) ^ 5 end

for _, n in ipairs{1.33, 1.5, 1.7, 2.4} do
	local f0 = ((n - 1) / (n + 1)) ^ 2
	print(string.format("\nn = %.2f, F0 = %.4f; angle  exact  schlick  | pane: R exact, R engine, T exact, T engine | solid exit: exact F, schlick", n, f0))
	local worst, worst_angle = 0, 0

	for _, deg in ipairs{0, 20, 40, 55, 65, 75, 82, 86, 89} do
		local mu = math.cos(math.rad(deg))
		local f = fresnel(mu, 1, n)
		local s = schlick(f0, mu)
		-- a pane: both surfaces reflect F, the light bounces between them (incoherent sum)
		local r_pane = f + (1 - f) ^ 2 * f / (1 - f * f)
		local t_pane = (1 - f) ^ 2 / (1 - f * f)
		-- inside the glass the ray meets the exit surface at the angle it refracted to
		local sin_t = math.sqrt(1 - mu * mu) / n
		local mu_t = math.sqrt(1 - sin_t * sin_t)
		local f_exit = fresnel(mu_t, n, 1)
		local s_exit = schlick(f0, mu_t)
		worst = math.max(worst, math.abs(s - f))
		if math.abs(s - f) >= worst then worst_angle = deg end
		print(string.format("  %2d  %.4f  %.4f   |  %.4f  %.4f  %.4f  %.4f  |  %.4f  %.4f", deg, f, s, r_pane, s, t_pane, 1 - s, f_exit, s_exit))
	end

	print(string.format("  critical angle from inside %.1f degrees, schlick's worst error against the exact curve %.4f (at %d)", math.deg(math.asin(1 / n)), worst, worst_angle))
end
