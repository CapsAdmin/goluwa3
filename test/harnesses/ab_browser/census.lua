local ffi = require("ffi")
local census = {}
function census.take()
	local visited = {}
	local shapes = {}
	local cdata_stats = {}
	local strings_bytes = 0
	local stack = {}
	local sp = 0
	local function push(v) sp = sp + 1 stack[sp] = v end
	local function visit_value(v, weak)
		local t = type(v)
		if t == "table" or t == "function" then
			if not weak then push(v) end
		elseif t == "string" then
			if not visited[v] then visited[v] = true strings_bytes = strings_bytes + #v + 24 end
		elseif t == "cdata" then
			if not weak then
				local ct = tostring(ffi.typeof(v)):gsub("ctype<(.*)>", "%1")
				local ok, s = pcall(ffi.sizeof, v)
				if not ok or not s then s = 0 end
				local st = cdata_stats[ct]
				if not st then st = {count = 0, bytes = 0} cdata_stats[ct] = st end
				st.count = st.count + 1
				st.bytes = st.bytes + s
			end
		end
	end
	for name, mod in pairs(import.loaded) do push(mod) end
	push(_G)
	push(debug.getregistry())
	while sp > 0 do
		local v = stack[sp]
		stack[sp] = nil
		sp = sp - 1
		local t = type(v)
		if t == "table" and not visited[v] then
			visited[v] = true
			local mt = getmetatable(v)
			local weak_k, weak_v = false, false
			if type(mt) == "table" then
				push(mt)
				local mode = rawget(mt, "__mode")
				if type(mode) == "string" then weak_k = mode:find("k") ~= nil weak_v = mode:find("v") ~= nil end
			end
			local keys = {}
			local n = 0
			for k, val in next, v do
				n = n + 1
				if n <= 6 and type(k) == "string" then keys[#keys + 1] = k end
				visit_value(k, weak_k)
				visit_value(val, weak_v)
			end
			table.sort(keys)
			local sig = n > 6 and ("many(" .. table.concat(keys, ",") .. ")") or table.concat(keys, ",")
			if n == 0 then sig = "<empty>" end
			local st = shapes[sig]
			if not st then st = {count = 0, entries = 0} shapes[sig] = st end
			st.count = st.count + 1
			st.entries = st.entries + n
		elseif t == "function" and not visited[v] then
			visited[v] = true
			local i = 1
			while true do
				local ok, name, val = pcall(debug.getupvalue, v, i)
				if not ok or name == nil then break end
				visit_value(val)
				i = i + 1
			end
		end
	end
	return {shapes = shapes, cdata = cdata_stats, strings = strings_bytes}
end
function census.diff(a, b, top)
	print(("  strings %+.1f MB"):format((b.strings - a.strings) / 1024 / 1024))
	local rows = {}
	for sig, st in pairs(b.shapes) do
		local before = a.shapes[sig] or {count = 0, entries = 0}
		rows[#rows + 1] = {sig = sig, count = st.count - before.count, entries = st.entries - before.entries}
	end
	table.sort(rows, function(x, y) return x.entries > y.entries end)
	print("  table shapes by entries:")
	for i = 1, math.min(top or 10, #rows) do
		local r = rows[i]
		print(("    %+9d tables %+10d entries  %s"):format(r.count, r.entries, r.sig:sub(1, 110)))
	end
	rows = {}
	for ct, st in pairs(b.cdata) do
		local before = a.cdata[ct] or {count = 0, bytes = 0}
		rows[#rows + 1] = {ct = ct, count = st.count - before.count, bytes = st.bytes - before.bytes}
	end
	table.sort(rows, function(x, y) return x.bytes > y.bytes end)
	print("  cdata by bytes:")
	for i = 1, math.min(top or 10, #rows) do
		local r = rows[i]
		print(("    %+9d objs %+9.1f MB  %s"):format(r.count, r.bytes / 1024 / 1024, r.ct:sub(1, 90)))
	end
end
return census
