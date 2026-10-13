local m3 = import("test/harnesses/m3/harness.lua")
local census = import("test/harnesses/ab_browser/census.lua")
local n = 0
m3.Run(function(view, now)
	n = n + 1
	if n == 120 then
		collectgarbage("collect") collectgarbage("collect")
		print(string.format("HEAP after full gc: %.0f MB", collectgarbage("count") / 1024))
		local c = census.take()
		local rows = {}
		for sig, st in pairs(c.shapes) do rows[#rows + 1] = {sig, st.count, st.entries} end
		table.sort(rows, function(a, b) return a[2] * 56 + a[3] * 16 > b[2] * 56 + b[3] * 16 end)
		for i = 1, 25 do print(string.format("CENSUS %9d tables %10d entries  %s", rows[i][2], rows[i][3], rows[i][1]:sub(1, 150))) end
		local crow = {}
		for ct, st in pairs(c.cdata) do crow[#crow + 1] = {ct, st.count, st.bytes} end
		table.sort(crow, function(a, b) return a[3] > b[3] end)
		for i = 1, 12 do print(string.format("CDATA %9d x %12d bytes  %s", crow[i][2], crow[i][3], crow[i][1]:sub(1, 120))) end
		print(string.format("CENSUS strings %.0f MB", c.strings / 1048576))
		return false
	end
end)
