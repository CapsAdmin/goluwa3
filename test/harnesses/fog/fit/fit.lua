-- The path tracer's reference (tmp/fogref/sun<elevation>_vis<visibility>.txt, written by reference.sh: elevation azimuth
-- engine_Y reference_Y per line) and the model's score against it: rms of the log of model over reference, the rows
-- looking at the sun excluded. SKY holds the numbers the fog's light depends on, read off the engine at each sun:
-- the sun's illuminance perpendicular to it, the sky's irradiance (test/harnesses/colorchecker/run.lua prints both),
-- the sky_light of get_ground_fog_sky_ambient.
local model = dofile("test/harnesses/fog/fit/model.lua")
local SKY = {[60] = {sun_el = 60, e_perp = 97246, amb = 7352, e_sky = 17129}, [25] = {sun_el = 25, e_perp = 73765, amb = 5225, e_sky = 12504}}

local function load(sun, vis)
	local rows = {}
	local f = io.open(string.format("tmp/fogref/sun%d_vis%d.txt", sun, vis))
	if not f then return nil end
	for line in f:lines() do
		local e, a, eng, mc = line:match("(%S+) (%S+) (%S+) (%S+)")
		if e then rows[#rows + 1] = {e = tonumber(e), a = tonumber(a), engine = tonumber(eng), mc = tonumber(mc)} end
	end
	f:close()
	return #rows > 0 and rows or nil
end

local function dataset(suns, viss)
	local data = {}
	for _, sun in ipairs(suns) do
		local clear = load(sun, 0)
		for _, vis in ipairs(viss) do
			local rows = load(sun, vis)
			if rows and clear then
				for i, r in ipairs(rows) do
					if not (r.e >= sun - 3 and r.a == 0) then
						data[#data + 1] = {sun = sun, vis = vis, e = r.e, a = r.a, mc = r.mc, engine = r.engine, clear = clear[i].mc}
					end
				end
			end
		end
	end
	return data
end

local function score(p, data, against)
	local s, n = 0, 0
	for _, d in ipairs(data) do
		local y = model.radiance(SKY[d.sun], p, d.vis, d.e, d.a, d.clear)
		local r = math.log(y / d[against or "mc"])
		s, n = s + r * r, n + 1
	end
	return math.sqrt(s / n)
end

return {model = model, SKY = SKY, load = load, dataset = dataset, score = score}
