-- Hosek-Wilkie clear sky (CIE XYZ version, ArHosekSkyModel.cc v1.4a, BSD licensed) ported to lua.
-- It reads the coefficient tables from tmp/hosek/ArHosekSkyModelData_CIEXYZ.h, fetched with
-- curl from https://raw.githubusercontent.com/ebruneton/clear-sky-models/master/atmosphere/model/hosek/
-- Output is luminance in cd/m2 (the model's Y is W / (m2 sr), times 683 lm / W).
local hosek = {}
local path = "tmp/hosek/ArHosekSkyModelData_CIEXYZ.h"
local datasets = {}

do
	local f = assert(io.open(path, "rb"), "missing " .. path)
	local text = f:read("*a"):gsub("//[^\n]*", "")
	f:close()

	local function parse(name)
		local body = text:match("double " .. name .. "%[%]%s*=%s*{(.-)}")
		local t = {}

		for n in body:gmatch("[-+]?%d+%.%d+e[-+]%d+") do
			t[#t + 1] = tonumber(n)
		end

		return t
	end

	for i = 1, 3 do
		datasets[i] = {coef = parse("datasetXYZ" .. i), rad = parse("datasetXYZRad" .. i)}
	end

	assert(#datasets[1].coef == 1080, #datasets[1].coef)
	assert(#datasets[1].rad == 120, #datasets[1].rad)
end

local function bezier5(t, a)
	local s = 1 - t
	return s ^ 5 * a[1] + 5 * s ^ 4 * t * a[2] + 10 * s ^ 3 * t ^ 2 * a[3] + 10 * s ^ 2 * t ^ 3 * a[4] + 5 * s * t ^ 4 * a[5] + t ^ 5 * a[6]
end

-- the dataset is [albedo 2][turbidity 10][elevation control point 6][width]
local function cook(data, width, turbidity, albedo, elevation)
	local t = (elevation / (math.pi / 2)) ^ (1 / 3)
	local int_t = math.floor(turbidity)
	local rem = turbidity - int_t
	local out = {}

	for i = 1, width do
		out[i] = 0
	end

	local function add(alb_index, turb_index, weight)
		local base = alb_index * 10 * 6 * width + (turb_index - 1) * 6 * width

		for i = 1, width do
			local pts = {}

			for k = 0, 5 do
				pts[k + 1] = data[base + k * width + i]
			end

			out[i] = out[i] + weight * bezier5(t, pts)
		end
	end

	add(0, int_t, (1 - albedo) * (1 - rem))
	add(1, int_t, albedo * (1 - rem))

	if int_t < 10 then
		add(0, int_t + 1, (1 - albedo) * rem)
		add(1, int_t + 1, albedo * rem)
	end

	return out
end

function hosek.New(turbidity, albedo, elevation)
	local state = {configs = {}, radiances = {}}

	for c = 1, 3 do
		state.configs[c] = cook(datasets[c].coef, 9, turbidity, albedo, elevation)
		state.radiances[c] = cook(datasets[c].rad, 1, turbidity, albedo, elevation)[1]
	end

	return state
end

-- theta is the view's zenith angle, gamma the angle to the sun. returns X, Y, Z in cd/m2
function hosek.Radiance(state, theta, gamma)
	local out = {}

	for c = 1, 3 do
		local k = state.configs[c]
		local cg = math.cos(gamma)
		local exp_m = math.exp(k[5] * gamma)
		local ray_m = cg * cg
		local mie_m = (1 + cg * cg) / (1 + k[9] * k[9] - 2 * k[9] * cg) ^ 1.5
		local zenith = math.sqrt(math.cos(theta))
		out[c] = (1 + k[1] * math.exp(k[2] / (math.cos(theta) + 0.01))) * (k[3] + k[4] * exp_m + k[6] * ray_m + k[7] * mie_m + k[8] * zenith) * state.radiances[c] * 683
	end

	return out[1], out[2], out[3]
end

return hosek
