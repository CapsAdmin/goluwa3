function table.random_pairs(tbl)
	local sorted = {}

	for key, val in pairs(tbl) do
		list.insert(sorted, {key = key, val = val, rand = math.random()})
	end

	list.sort(sorted, function(a, b)
		return a.rand > b.rand
	end)

	local i = 0
	return function()
		i = i + 1

		if sorted[i] then return sorted[i].key, sorted[i].val --, sorted[i].rand
		end
	end
end

function table.lowecase_lookup(tbl, key)
	for k, v in pairs(tbl) do
		if k:lower() == key:lower() then return v end
	end
end

function table.to_list(tbl, sort)
	local lst = {}

	for key, val in pairs(tbl) do
		list.insert(lst, {key = key, val = val})
	end

	if sort then list.sort(lst, sort) end

	return lst
end

function table.sorted_pairs(tbl, sort)
	local lst = table.to_list(tbl, sort)
	local i = 0
	return function()
		i = i + 1

		if lst[i] then return lst[i].key, lst[i].val end
	end
end

function table.has_value(tbl, val)
	for k, v in pairs(tbl) do
		if v == val then return k end
	end

	return false
end

function table.get_key(tbl, val)
	for k in pairs(tbl) do
		if k == val then return k end
	end

	return nil
end

function table.count(tbl)
	local i = 0

	for _ in pairs(tbl) do
		i = i + 1
	end

	return i
end

function table.merge(a, b, merge_aray)
	for k, v in pairs(b) do
		if type(v) == "table" and type(a[k]) == "table" then
			if merge_aray and list.is_list(a[k]) and list.is_list(v) then
				local offset = #a[k]

				for i = 1, #v do
					a[k][i + offset] = v[i]
				end
			else
				table.merge(a[k], v, merge_aray)
			end
		else
			a[k] = v
		end
	end

	return a
end

function table.virtual_merge(tbl, nodes)
	return setmetatable(
		tbl,
		{
			__index = function(_, key)
				local found = {}

				for _, node in ipairs(nodes) do
					local val = node[key]

					if val ~= nil then
						if type(val) ~= "table" then
							return val
						else
							list.insert(found, val)
						end
					end
				end

				if #found == 0 then return nil end

				return table.virtual_merge(found, found)
			end,
		}
	)
end

function table.add(a, b)
	for _, v in pairs(b) do
		list.insert(a, v)
	end
end

function table.random(tbl)
	local key = math.random(1, table.count(tbl))
	local i = 1

	for _key, _val in pairs(tbl) do
		if i == key then return _val, _key end

		i = i + 1
	end
end

do -- table copy
	local lookup_table = {}
	local type = type
	local pairs = pairs
	local getmetatable = getmetatable

	local function copy(obj, skip_meta)
		local t = type(obj)

		if t == "number" or t == "string" or t == "function" or t == "boolean" then
			return obj
		end

		if ((t == "table" or (t == "cdata" and structs.GetStructMeta(obj))) and obj.__copy) then
			return obj:__copy()
		elseif lookup_table[obj] then
			return lookup_table[obj]
		elseif t == "table" then
			local new_table = {}
			lookup_table[obj] = new_table

			for key, val in pairs(obj) do
				new_table[copy(key, skip_meta)] = copy(val, skip_meta)
			end

			if skip_meta then return new_table end

			local meta = getmetatable(obj)

			if meta then setmetatable(new_table, meta) end

			return new_table
		end

		return obj
	end

	function table.copy(obj, skip_meta)
		table.clear(lookup_table)
		return copy(obj, skip_meta)
	end
end

function table.shallow_copy(tbl)
	local new = {}

	for k, v in pairs(tbl) do
		new[k] = v
	end

	return new
end

function table.weak(k, v)
	if k and v then
		mode = "kv"
	elseif k then
		mode = "k"
	elseif v then
		mode = "v"
	else
		mode = "kv"
	end

	--return setmetatable({}, {__mode  = mode})
	return {}
end

-- https://stackoverflow.com/questions/20325332/how-to-check-if-two-tablesobjects-have-the-same-value-in-lua
function table.equal(o1, o2, ignore_mt)
	if o1 == o2 then return true end

	local o1Type = type(o1)
	local o2Type = type(o2)

	if o1Type ~= o2Type then return false end

	if o1Type ~= "table" then return false end

	if not ignore_mt then
		local mt1 = getmetatable(o1)

		if mt1 and mt1.__eq then
			--compare using built in method
			return o1 == o2
		end
	end

	local keySet = {}

	for key1, value1 in pairs(o1) do
		local value2 = o2[key1]

		if value2 == nil or table.equal(value1, value2, ignore_mt) == false then
			return false
		end

		keySet[key1] = true
	end

	for key2, _ in pairs(o2) do
		if not keySet[key2] then return false end
	end

	return true
end
