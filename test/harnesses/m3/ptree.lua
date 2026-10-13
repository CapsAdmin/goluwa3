-- usage: PT_FILE=storage/logs/jit_profile_x.glwp [PT_STATE=G] [PT_CALLERS=pattern] [PT_TOP=40] luajit glw --cli lua "import('test/harnesses/m3/ptree.lua')"
local Profiler = import("goluwa/jit/profiler.lua")
local file = os.getenv("PT_FILE")
local want_state = os.getenv("PT_STATE")
local callers_of = os.getenv("PT_CALLERS")
local under = os.getenv("PT_UNDER")
local top = tonumber(os.getenv("PT_TOP") or "40")
local data = Profiler.Load(file)
local total, selected = 0, 0
local self_counts, incl_counts, caller_counts, state_counts = {}, {}, {}, {}
for _, ev in ipairs(data.events) do
	if ev.type == "sample" and ev.stack then
		total = total + 1
		state_counts[ev.vm_state or "?"] = (state_counts[ev.vm_state or "?"] or 0) + 1
		if (not want_state or ev.vm_state == want_state) and (not under or ev.stack:find(under, 1, true)) then
			selected = selected + 1
			local lines = {}
			for line in ev.stack:gmatch("[^\n]+") do lines[#lines + 1] = line end
			self_counts[lines[1]] = (self_counts[lines[1]] or 0) + 1
			local seen = {}
			for i, line in ipairs(lines) do
				if not seen[line] then seen[line] = true incl_counts[line] = (incl_counts[line] or 0) + 1 end
				if callers_of and line:find(callers_of, 1, true) and not caller_counts[ev] then
					caller_counts[ev] = true
					local up = lines[i + 1] or "<none>"
					local up2 = lines[i + 2] or "<none>"
					local key = up .. "  <-  " .. up2
					self_counts["CALLER " .. key] = (self_counts["CALLER " .. key] or 0) + 1
				end
			end
		end
	end
end
local function dump(title, tbl, filter)
	local rows = {}
	for k, v in pairs(tbl) do if not filter or filter(k) then rows[#rows + 1] = {k, v} end end
	table.sort(rows, function(a, b) return a[2] > b[2] end)
	print("== " .. title)
	for i = 1, math.min(top, #rows) do print(string.format("%6.2f%% %6d  %s", rows[i][2] / selected * 100, rows[i][2], rows[i][1])) end
end
print(string.format("samples total %d selected %d state=%s", total, selected, tostring(want_state)))
for k, v in pairs(state_counts) do print("state", k, v, string.format("%.1f%%", v / total * 100)) end
if callers_of then
	dump("callers of " .. callers_of, self_counts, function(k) return k:sub(1, 7) == "CALLER " end)
else
	dump("self", self_counts, function(k) return k:sub(1, 7) ~= "CALLER " end)
	dump("inclusive", incl_counts)
end
os.exit(0)
