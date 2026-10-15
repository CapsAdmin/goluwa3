-- Nelder-Mead fit of the model's parameters. luajit test/harnesses/fog/fit/opt.lua <octaves> <diffuse shape, 6> <iterations> "<fixed>"
-- with fixed as name=value pairs that pin a parameter, FITSUNS=60,25 picks the suns to fit on (the score is reported on all)
-- The fit used: luajit test/harnesses/fog/fit/opt.lua 3 6 1500 "amb_scale=1,diff=0,kappa_amb=0,kappa=0"
local fit = dofile("test/harnesses/fog/fit/fit.lua")
local viss = {300, 1000, 2000, 5000, 20000}
local fit_suns = {}
for v in (os.getenv("FITSUNS") or "60,25"):gmatch("%d+") do fit_suns[#fit_suns + 1] = tonumber(v) end
local data = fit.dataset(fit_suns, viss)
local test_data = fit.dataset({60, 25}, viss)
print("rows", #data)
local names = {"diff", "d2", "kd", "m_amb", "kappa", "a", "b", "c", "amb_scale", "multi_k", "kappa_amb"}
local lo = {diff = 0, d2 = 0, kd = 0, m_amb = 0, kappa = 0, a = 0, b = 0.15, c = 0.2, amb_scale = 0.2, multi_k = 0, kappa_amb = 0}
local hi = {diff = 3, d2 = 3, kd = 3, m_amb = 1, kappa = 4, a = 0.95, b = 1, c = 1, amb_scale = 1.5, multi_k = 3, kappa_amb = 4}
local fixed = {n = tonumber(arg[1] or "3"), diff_shape = tonumber(arg[2] or "6")}
for pair in (arg[4] or ""):gmatch("[^,]+") do
	local k, v = pair:match("^([^=]+)=(.*)$")
	lo[k], hi[k] = tonumber(v), tonumber(v)
end
local x0 = {0.2, 0.3, 1.0, 0.3, 0.3, 0.6, 0.35, 0.7, 0.8, 0.6, 0.1}
local function params(v)
	local p = {n = fixed.n, diff_shape = fixed.diff_shape}
	for i, k in ipairs(names) do p[k] = math.max(lo[k], math.min(hi[k], v[i])) end
	return p
end
local function f(v) return fit.score(params(v), data) end
local n = #x0
local simplex = {x0}
for i = 1, n do local v = {table.unpack(x0)} v[i] = v[i] * 1.3 + 0.1 simplex[#simplex + 1] = v end
local vals = {}
for i, v in ipairs(simplex) do vals[i] = f(v) end
for iter = 1, tonumber(arg[3] or "900") do
	local order = {}
	for i = 1, #simplex do order[i] = i end
	table.sort(order, function(a, b) return vals[a] < vals[b] end)
	local s2, v2 = {}, {}
	for i, o in ipairs(order) do s2[i], v2[i] = simplex[o], vals[o] end
	simplex, vals = s2, v2
	local c = {}
	for j = 1, n do c[j] = 0 for i = 1, n do c[j] = c[j] + simplex[i][j] / n end end
	local function pt(t) local r = {} for j = 1, n do r[j] = c[j] + t * (simplex[n + 1][j] - c[j]) end return r end
	local r = pt(-1)
	local fr = f(r)
	if fr < vals[1] then
		local e = pt(-2)
		local fe = f(e)
		if fe < fr then simplex[n + 1], vals[n + 1] = e, fe else simplex[n + 1], vals[n + 1] = r, fr end
	elseif fr < vals[n] then
		simplex[n + 1], vals[n + 1] = r, fr
	else
		local ct = pt(0.5)
		local fc = f(ct)
		if fc < vals[n + 1] then simplex[n + 1], vals[n + 1] = ct, fc
		else for i = 2, n + 1 do for j = 1, n do simplex[i][j] = simplex[1][j] + 0.5 * (simplex[i][j] - simplex[1][j]) end vals[i] = f(simplex[i]) end end
	end
end
local best = params(simplex[1])
print(string.format("best rms %.4f on the fit data, %.4f on all (n=%d shape=%d)", vals[1], fit.score(params(simplex[1]), test_data), fixed.n, fixed.diff_shape))
for _, k in ipairs(names) do io.write(string.format("%s=%.3f ", k, best[k])) end
print()
for _, sun in ipairs{60, 25} do
	for _, vis in ipairs(viss) do
		local line = {}
		for _, d in ipairs(data) do
			if d.sun == sun and d.vis == vis then
				local y = fit.model.radiance(fit.SKY[d.sun], best, d.vis, d.e, d.a, d.clear)
				line[#line + 1] = string.format("%d/%d %.2f", d.e, d.a, y / d.mc)
			end
		end
		print(string.format("sun %d vis %d: %s", sun, vis, table.concat(line, "  ")))
	end
end
