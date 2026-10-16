-- what the wind does at each beaufort force, from the formulas of model_pipeline.lua
local function bending(v) local x = (v / 22) ^ 1.6 return 7 * x / (1 + x) end
local function amplitude(s) return s < 0.5 and s * 2 or math.sqrt(s * 2) end
local function rate(v) return math.sqrt(math.max(v, 4) / 4) end
local forces = {{"2 light breeze", 2.5}, {"3 gentle", 4.4}, {"4 moderate", 6.7}, {"5 fresh", 9.4}, {"6 strong", 12.3}, {"7 near gale", 15.5}, {"8 gale", 19}, {"10 storm", 26}, {"12 hurricane", 35}}
local mats = {
	-- name, frequency, leaf amp, branch amp, grass height (nil for leaves mode)
	{"foliage leaves", tonumber(os.getenv("LEAF_F") or "") or 0.3, 0.08, 0.2},
	{"foliage grass 0.5m", tonumber(os.getenv("GRASS_F") or "") or 1, 0.05, 0.03, 0.5},
	{"crysis palm leaf", 0.5, 0.2, 0.2},
	{"crysis jungle leafs", 0.3, 0.5, 0.2},
	{"crysis twisted leaves", 0.2, 0.08, 0.2},
	{"crysis palmbush", 0.3, 0.2, 0.2},
}
print(("%-16s %5s  %6s  %5s"):format("force", "m/s", "lean%", "rate"))
for _, f in ipairs(forces) do
	local v = f[2]
	local line = ("%-16s %5.1f  %5.1f%%  %4.2fx"):format(f[1], v, bending(v) * 4.5, rate(v))
	print(line)
	for _, m in ipairs(mats) do
		local M = tonumber(os.getenv("M") or "") or 2 local w = 0.25 * v local s = 0.3 * w * M / (M + w) * m[2] * (m[5] or 1)
		local a = amplitude(s)
		-- edge-on flutter peak to peak (2 * a * leaf), face-on push (up to 2a), branch bob peak to peak
		print(("      %-22s s %.2f  amp %.2f  flutter +-%4.1f cm  push %4.1f cm  branch +-%4.1f cm"):format(m[1], s, a, a * m[3] * 100, a * m[3] * 100, a * m[4] * 100))
	end
end
