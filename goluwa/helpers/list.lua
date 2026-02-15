local list = {}
list.pack = _G.table.pack or
	function(...)
		local t = {...}
		t.n = select("#", ...)
		return t
	end
list.unpack = _G.table.unpack or _G.unpack
list.insert = _G.table.insert
list.remove = _G.table.remove
list.move = _G.table.move
list.concat = _G.table.concat
list.sort = _G.table.sort
list.pairs = assert(_G.ipairs)
list.clear = require("table.clear")

do
	local function flatten(tbl, out)
		for _, v in ipairs(tbl) do
			if list.is_list(v) then flatten(v, out) else out[#out + 1] = v end
		end
	end

	function list.flatten(lst)
		local out = {}
		flatten(lst, out)
		return out
	end
end

function list.slice(tbl, first, last, step)
	local sliced = {}

	for i = first or 1, last or #tbl, step or 1 do
		sliced[#sliced + 1] = tbl[i]
	end

	return sliced
end

function list.find(tbl, func)
	for i, v in ipairs(tbl) do
		if func(v, i) then return v end
	end

	return nil
end

function list.shuffle(a, times)
	times = times or 1
	local c = #a

	for _ = 1, c * times do
		local ndx0 = math.random(1, c)
		local ndx1 = math.random(1, c)
		local temp = a[ndx0]
		a[ndx0] = a[ndx1]
		a[ndx1] = temp
	end

	return a
end

function list.scroll(tbl, offset)
	if offset == 0 then return end

	if offset > 0 then
		for _ = 1, offset do
			local val = list.remove(tbl, 1)
			list.insert(tbl, val)
		end
	else
		for _ = 1, math.abs(offset) do
			local val = list.remove(tbl)
			list.insert(tbl, 1, val)
		end
	end
end

-- http://stackoverflow.com/questions/6077006/how-can-i-check-if-a-lua-table-contains-only-sequential-numeric-indices
function list.is_list(t)
	if type(t) ~= "table" then return false end

	local i = 0

	for _ in pairs(t) do
		i = i + 1

		if t[i] == nil then return false end
	end

	return true
end

do
	local list_concat = list.concat

	function list.concat_range(tbl, start, stop)
		local length = stop - start
		local str = {}
		local str_i = 1

		for i = start, stop do
			str[str_i] = tbl[i] or ""
			str_i = str_i + 1
		end

		return list_concat(str)
	end
end

do -- negative pairs
	local v

	local function iter(a, i)
		i = i - 1
		v = a[i]

		if v then return i, v end
	end

	function list.reverse_ipairs(a)
		return iter, a, #a + 1
	end
end

function list.map(tbl, cb)
	local copy = {}

	for i, v in ipairs(tbl) do
		copy[i] = cb(v, i)
	end

	return copy
end

function list.unique(tbl)
	local seen = {}
	local out = {}

	for i, v in ipairs(tbl) do
		if not seen[v] then
			seen[v] = true
			out[#out + 1] = v
		end
	end

	return out
end

function list.remove_value(tbl, val)
	for i, v in ipairs(tbl) do
		if v == val then
			list.remove(tbl, i)

			break
		end
	end
end

-- 12:34 - <mniip> http://codepad.org/cLaX7lVn
function list.multi_remove(tbl, locations)
	if locations[1] then
		local off = 0
		local idx = 1

		for i = 1, #tbl do
			while i + off == locations[idx] do
				off = off + 1
				idx = idx + 1
			end

			tbl[i] = tbl[i + off]
		end
	end

	return tbl
end

function list.reverse(tbl)
	for i = 1, math.floor(#tbl / 2) do
		tbl[i], tbl[#tbl - i + 1] = tbl[#tbl - i + 1], tbl[i]
	end

	return tbl
end

function list.fix_indices(tbl)
	local j = 1
	local n = #tbl

	for i = 1, n do
		local v = tbl[i]

		if v ~= nil then
			if i ~= j then
				tbl[j] = v
				tbl[i] = nil
			end

			j = j + 1
		end
	end

	-- Check for non-numeric keys or keys beyond #tbl
	local has_extra = false

	for k, v in pairs(tbl) do
		if type(k) ~= "number" or k >= j then
			has_extra = true

			break
		end
	end

	if not has_extra then return end

	-- Slow path for tables with non-numeric keys or large gaps
	local keys = {}
	local kn = 0

	for k in pairs(tbl) do
		kn = kn + 1
		keys[kn] = k
	end

	table.sort(keys, function(a, b)
		local ak, bk = tonumber(a), tonumber(b)

		if ak and bk then return ak < bk end

		if ak then return true end

		if bk then return false end

		return tostring(a) < tostring(b)
	end)

	local values = {}

	for i = 1, kn do
		values[i] = tbl[keys[i]]
		tbl[keys[i]] = nil
	end

	for i = 1, kn do
		tbl[i] = values[i]
	end
end

function list.has_value(tbl, val)
	for k, v in ipairs(tbl) do
		if v == val then return k end
	end

	return false
end

function list.get_index(tbl, val)
	for i, v in ipairs(tbl) do
		if i == v then return i end
	end

	return nil
end

function list.remove_values(tbl, val)
	local index = list.get_index(tbl, val)

	while index ~= nil do
		list.remove_values(tbl, index)
		index = list.get_index(tbl, val)
	end
end

function list.concat_member(tbl, key, sep)
	local temp = {}

	for i, v in ipairs(tbl) do
		temp[i] = tostring(v[key])
	end

	return list.concat(temp, sep)
end

do
	local setmetatable = setmetatable
	local ipairs = ipairs
	local META = {}
	META.__index = META
	META.concat = list.concat
	META.insert = list.insert
	META.remove = list.remove
	META.unpack = list.unpack
	META.sort = list.sort

	function META:pairs()
		return ipairs(self)
	end

	function list.list(count)
		return setmetatable(table.new(count or 1, 0), META)
	end
end

return list
