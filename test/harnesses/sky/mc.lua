-- Monte Carlo reference for the clear sky: delta tracked volumetric path tracing through a spherical shell
-- atmosphere (Rayleigh, Mie with the engine's Cornette Shanks phase, ozone absorption, Lambertian ground), every
-- scatter event also samples the sun. All orders of scattering. One call is one wavelength (or channel), with
-- its coefficients k = {rayleigh, ozone, mie_ext, mie_sca, albedo, g, h} at sea level in 1 / km (h in km).
-- The result is the radiance for a sun of the given illuminance (cd/m2 when the illuminance is luminous).
local mc = {}
local R_PLANET, R_ATMOSPHERE = 6371.0, 6471.0
local EYE = 1.75 * 0.001
local PI = math.pi
local sqrt, exp, log, cos, sin, random = math.sqrt, math.exp, math.log, math.cos, math.sin, math.random
local k_rayleigh, k_ozone, k_mie_ext, k_mie_sca, k_h, k_g, gg = 0, 0, 0, 0, 1.2, 0.758, 0.758 ^ 2

local function densities(radius)
	local alt = radius - R_PLANET

	if alt < 0 then alt = 0 end

	local ozone = 1 - math.abs(radius - R_PLANET - 25) / 15

	if ozone < 0 then ozone = 0 end

	return exp(-alt / 8), exp(-alt / k_h) + 0.07 * exp(-alt / 8), ozone
end

-- distances along (px, py, pz) + t (dx, dy, dz) to a sphere around the origin, nil on a miss
local function sphere(px, py, pz, dx, dy, dz, radius)
	local b = px * dx + py * dy + pz * dz
	local c = px * px + py * py + pz * pz - radius * radius
	local disc = b * b - c

	if disc < 0 then return nil end

	local s = sqrt(disc)
	return -b - s, -b + s
end

local function sun_transmittance(px, py, pz, dx, dy, dz)
	local near = sphere(px, py, pz, dx, dy, dz, R_PLANET)

	if near and near > 0 then return 0 end

	local _, top = sphere(px, py, pz, dx, dy, dz, R_ATMOSPHERE)
	local n = 32
	local ds = top / n
	local tau = 0

	for i = 0, n - 1 do
		local t = (i + 0.5) * ds
		local x, y, z = px + dx * t, py + dy * t, pz + dz * t
		local dr, dm, do_ = densities(sqrt(x * x + y * y + z * z))
		tau = tau + (k_rayleigh * dr + k_mie_ext * dm + k_ozone * do_) * ds
	end

	return exp(-tau)
end

local function rayleigh_phase(mu)
	return 3 / (16 * PI) * (1 + mu * mu)
end

local function cs_phase(mu)
	return 3 * (1 - gg) * (1 + mu * mu) / (8 * PI * (2 + gg) * (1 + gg - 2 * k_g * mu) ^ 1.5)
end

local function hg_phase(mu)
	return (1 - gg) / (4 * PI * (1 + gg - 2 * k_g * mu) ^ 1.5)
end

local function rotate(dx, dy, dz, cos_t, phi)
	local ax, ay, az = 0, 1, 0

	if math.abs(dy) > 0.99 then ax, ay, az = 1, 0, 0 end

	local tx, ty, tz = dy * az - dz * ay, dz * ax - dx * az, dx * ay - dy * ax
	local l = sqrt(tx * tx + ty * ty + tz * tz)
	tx, ty, tz = tx / l, ty / l, tz / l
	local bx, by, bz = dy * tz - dz * ty, dz * tx - dx * tz, dx * ty - dy * tx
	local sin_t = sqrt(math.max(0, 1 - cos_t * cos_t))
	local c, s = cos(phi), sin(phi)
	return (tx * c + bx * s) * sin_t + dx * cos_t, (ty * c + by * s) * sin_t + dy * cos_t, (tz * c + bz * s) * sin_t + dz * cos_t
end

-- the camera is on the vertical axis EYE above the surface, sun and view are unit vectors with y up
function mc.Radiance(k, sx, sy, sz, vx, vy, vz, paths, max_order, sun_illuminance)
	k_rayleigh, k_ozone, k_mie_ext, k_mie_sca, k_h, k_g = k.rayleigh, k.ozone, k.mie_ext, k.mie_sca, k.h or 1.2, k.g or 0.758
	gg = k_g * k_g
	local sigma_max = k_rayleigh + k_mie_ext * 1.07 + k_ozone
	local albedo = k.albedo or 0
	local total = 0

	for _ = 1, paths do
		local px, py, pz = 0, R_PLANET + EYE, 0
		local dx, dy, dz = vx, vy, vz
		local weight = 1
		local order = 0

		while true do
			local t = -log(1 - random()) / sigma_max
			local gnear = sphere(px, py, pz, dx, dy, dz, R_PLANET)

			if gnear and gnear > 0 and gnear < t then
				px, py, pz = px + dx * gnear, py + dy * gnear, pz + dz * gnear
				order = order + 1

				if order > max_order or albedo == 0 then break end

				local l = sqrt(px * px + py * py + pz * pz)
				local ux, uy, uz = px / l, py / l, pz / l
				local cos_s = ux * sx + uy * sy + uz * sz

				if cos_s > 0 then
					total = total + weight * albedo / PI * cos_s * sun_transmittance(px + ux * 1e-6, py + uy * 1e-6, pz + uz * 1e-6, sx, sy, sz) * sun_illuminance
				end

				weight = weight * albedo
				dx, dy, dz = rotate(ux, uy, uz, sqrt(random()), 2 * PI * random())
				px, py, pz = px + ux * 1e-6, py + uy * 1e-6, pz + uz * 1e-6
			else
				px, py, pz = px + dx * t, py + dy * t, pz + dz * t
				local radius = sqrt(px * px + py * py + pz * pz)

				if radius > R_ATMOSPHERE then break end

				local dr, dm, do_ = densities(radius)
				local s_r = k_rayleigh * dr
				local s_m = k_mie_sca * dm
				local s_t = s_r + k_mie_ext * dm + k_ozone * do_

				if random() * sigma_max < s_t then
					if random() * s_t > s_r + s_m then break end

					order = order + 1
					local s_s = s_r + s_m
					local mu_s = dx * sx + dy * sy + dz * sz
					total = total + weight * (s_r * rayleigh_phase(mu_s) + s_m * cs_phase(mu_s)) / s_s * sun_transmittance(px, py, pz, sx, sy, sz) * sun_illuminance

					if order >= max_order then break end

					if random() * s_s < s_r then
						local cos_t

						repeat
							cos_t = 2 * random() - 1
						until random() * 2 < 1 + cos_t * cos_t

						dx, dy, dz = rotate(dx, dy, dz, cos_t, 2 * PI * random())
					else
						local u = random()
						local cos_t = (1 + gg - ((1 - gg) / (1 - k_g + 2 * k_g * u)) ^ 2) / (2 * k_g)
						weight = weight * cs_phase(cos_t) / hg_phase(cos_t)
						dx, dy, dz = rotate(dx, dy, dz, cos_t, 2 * PI * random())
					end
				end
			end
		end
	end

	return total / paths
end

return mc
