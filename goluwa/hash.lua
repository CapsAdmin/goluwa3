local Hash = {}
Hash.__index = Hash
local NIL = {}

function Hash.New()
	return setmetatable({
		_root = {},
		_nextId = 1,
		_leafKey = {},
	}, Hash)
end

function Hash:intern(list, count)
	local node = self._root

	if count == nil then count = list and #list or 0 end

	for i = 1, count do
		node = self:_descend(node, list[i])
	end

	return self:_finalize(node)
end

function Hash:_descend(node, value)
	if value == nil then
		value = NIL
	elseif type(value) == "table" then
		if #value > 0 then
			local len = #value
			local child = node[len]

			if not child then
				child = {}
				node[len] = child
			end

			node = child

			for i = 1, len do
				node = self:_descend(node, value[i])
			end

			return node
		else
			value = NIL
		end
	end

	if type(value) == "table" and value ~= NIL and value ~= self._leafKey then
		return self:_descendDict(node, value)
	end

	local child = node[value]

	if not child then
		child = {}
		node[value] = child
	end

	return child
end

function Hash:_descendDict(node, tbl)
	local keys = {}
	local keyCount = 0

	for k in pairs(tbl) do
		keyCount = keyCount + 1
		keys[keyCount] = k
	end

	if keyCount == 0 then return self:_descend(node, NIL) end

	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)

		if ta ~= tb then
			if ta == "number" then return true end

			if tb == "number" then return false end

			if ta == "string" then return true end

			if tb == "string" then return false end

			return ta < tb
		end

		return a < b
	end)

	for i = 1, keyCount do
		local k = keys[i]
		local v = tbl[k]
		node = self:_descend(node, k)

		if type(v) == "table" and v ~= NIL and v ~= self._leafKey then
			node = self:_descend(node, v)
		else
			local child = node[v]

			if not child then
				child = {}
				node[v] = child
			end

			node = child
		end
	end

	return node
end

function Hash:_finalize(node)
	local id = node[self._leafKey]

	if id then return id end

	id = self._nextId
	self._nextId = id + 1
	node[self._leafKey] = id
	return id
end

function Hash:internWith(tbl, keys)
	local node = self._root

	for i = 1, #keys do
		node = self:_descend(node, tbl and tbl[keys[i]] or nil)
	end

	return self:_finalize(node)
end

return Hash
