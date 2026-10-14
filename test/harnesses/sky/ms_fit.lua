-- least squares fit of the multiple scattering gain (get_multi_scatter_gain in atmosphere.lua) to the rows lut.lua
-- appends to tmp/ms_rows.txt with MSFIT=1: u = 1 - sin(view elevation), x = sin(sun elevation), a = ln(aerosol extinction / 0.0568),
-- ln of the path traced multiple scattering over the engine's. Run it after
-- rm tmp/ms_rows.txt; for av in 6000 10000 20000 55000 150000; do AEROSOL_VIS=$av MSFIT=1 QUIET=1 MC=40000 SUN_ELEVS=75,60,45,35,25,15,10,6 luajit glw --2d --background --validate lua "import('test/harnesses/sky/lut.lua')"; done
-- luajit glw --cli lua "import('test/harnesses/sky/ms_fit.lua')"
local rows = {}

for line in io.lines("tmp/ms_rows.txt") do
	local u, x, a, y = line:match("(%S+) (%S+) (%S+) (%S+)")
	if tonumber(a) < tonumber(os.getenv("MAX_A") or "99") then rows[#rows + 1] = {tonumber(u), tonumber(x), tonumber(a), tonumber(y)} end
end

local base_names = {"1", "u", "u * u", "x", "x * u", "x * x", "x * x * u", "u * u * x"}
local function base(u, x)
	return {1, u, u * u, x, x * u, x * x, x * x * u, u * u * x}
end

local function feats(u, x, a)
	local b = base(u, x)
	local out = {}

	for _, g in ipairs{1, a, a * a} do
		for i = 1, #b do
			out[#out + 1] = b[i] * g
		end
	end

	return out
end

local n = #feats(0, 0, 0)
local A, b = {}, {}

for i = 1, n do
	A[i], b[i] = {}, 0

	for j = 1, n do
		A[i][j] = 0
	end
end

for _, row in ipairs(rows) do
	local f = feats(row[1], row[2], row[3])

	for i = 1, n do
		b[i] = b[i] + f[i] * row[4]

		for j = 1, n do
			A[i][j] = A[i][j] + f[i] * f[j]
		end
	end
end

for i = 1, n do
	A[i][i] = A[i][i] + 1e-6
end

for i = 1, n do
	local p = i

	for r = i + 1, n do
		if math.abs(A[r][i]) > math.abs(A[p][i]) then p = r end
	end

	A[i], A[p], b[i], b[p] = A[p], A[i], b[p], b[i]

	for r = i + 1, n do
		local factor = A[r][i] / A[i][i]

		for c = i, n do
			A[r][c] = A[r][c] - factor * A[i][c]
		end

		b[r] = b[r] - factor * b[i]
	end
end

local c = {}

for i = n, 1, -1 do
	local sum = b[i]

	for j = i + 1, n do
		sum = sum - A[i][j] * c[j]
	end

	c[i] = sum / A[i][i]
end

local before, after = 0, 0

for _, row in ipairs(rows) do
	local f = feats(row[1], row[2], row[3])
	local pred = 0

	for i = 1, n do
		pred = pred + c[i] * f[i]
	end

	before = before + row[4] ^ 2
	after = after + (row[4] - pred) ^ 2
end

local groups = {}

for _, row in ipairs(rows) do
	local f = feats(row[1], row[2], row[3])
	local pred = 0

	for i = 1, n do
		pred = pred + c[i] * f[i]
	end

	local key = string.format("%.2f", row[3])
	groups[key] = groups[key] or {0, 0}
	groups[key][1] = groups[key][1] + 1
	groups[key][2] = groups[key][2] + (row[4] - pred) ^ 2
end

for key, g in pairs(groups) do
	print(string.format("a = %s: rms ln error after %.3f", key, math.sqrt(g[2] / g[1])))
end

print(string.format("%d rows, rms ln error of the multiple scattering %.3f before, %.3f after", #rows, math.sqrt(before / #rows), math.sqrt(after / #rows)))

for j, gname in ipairs{"", " * a", " * a * a"} do
	local terms = {}

	for i = 1, #base_names do
		terms[#terms + 1] = string.format("%.4f * %s", c[(j - 1) * #base_names + i], base_names[i])
	end

	print("poly" .. (j - 1) .. " = " .. table.concat(terms, " + "):gsub("%+ %-", "- ") .. ";")
end

os.exit(0)
