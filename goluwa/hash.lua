-- hash.lua — Trie-based value internment for stable integer IDs.
--
-- Usage:
--   local hash = import("goluwa/hash.lua")
--   local interner = hash.New()
--   local id = interner:intern("foo", 42, true)  -- stable integer >= 1
--
-- Common types (nil, number, string, boolean) are hashed directly.
-- Tables are hashed by their structure:
--   - Arrays descend by length then each element
--   - Empty tables use a nil sentinel
--   - Dict tables raise an error (unstable iteration order)
--
-- Custom serialization via __hash_serialize metamethod:
--   local mt = { __hash_serialize = function(self) return { self.x, self.y } end }
--   interner:intern(setmetatable({ x = 1, y = 2 }, mt))  -- same as interner:intern(1, 2)
--
-- Helper for keyed tables:
--   local id = interner:internWith(config, "key1", "key2", "key3")
--
-- Optional L1 object cache (caller responsibility):
--   local cache = setmetatable({}, {__mode = "k"})
--   if cache[obj] then return cache[obj] end
--   cache[obj] = interner:intern(...)
local Hash = {}
Hash.__index = Hash

--- Create a new interner with its own trie root and counter.
function Hash.New()
	return setmetatable(
		{
			_root = {},
			_nextId = 1,
			_nilKey = {},
			_leafKey = {},
		},
		Hash
	)
end

--- Hash a sequence of values and return a stable integer ID.
--
-- Values can be: nil, number, string, boolean, or a table.
-- Tables are hashed structurally. Use __hash_serialize metamethod
-- to customize serialization for custom types.
function Hash:intern(...)
	local node = self._root
	local count = select("#", ...)

	for i = 1, count do
		node = self:_descend(node, select(i, ...))
	end

	return self:_finalize(node)
end

--- Descend one level into the trie with a single value.
function Hash:_descend(node, value)
	-- nil: use sentinel key
	if value == nil then
		value = self._nilKey
	-- Custom serializer: metamethod returns serialized parts
	elseif type(value) == "table" then
		local mt = getmetatable(value)

		if mt and mt.__hash_serialize then
			local parts = mt.__hash_serialize(value)

			if type(parts) == "table" then
				for _, part in ipairs(parts) do
					local child = node[part]

					if not child then
						child = {}
						node[part] = child
					end

					node = child
				end

				return node
			end

			value = parts
		-- Table: arrays descend by length then elements
		elseif #value > 0 then
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
			-- Empty table: use nil sentinel
			value = self._nilKey
		end
	end

	-- Dict-like table: descend by sorted keys then values
	-- Skip sentinel keys to avoid infinite recursion
	if type(value) == "table" and value ~= self._nilKey and value ~= self._leafKey then
		return self:_descendDict(node, value)
	end

	-- Primitive (number, string, boolean, sentinel)
	local child = node[value]

	if not child then
		child = {}
		node[value] = child
	end

	return child
end

--- Descend into the trie with a dict-like table (sorted by keys).
function Hash:_descendDict(node, tbl)
	local keys = {}
	local keyCount = 0

	for k in pairs(tbl) do
		keyCount = keyCount + 1
		keys[keyCount] = k
	end

	if keyCount == 0 then return self:_descend(node, self._nilKey) end

	-- Sort keys for stable ordering
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
		-- Descend key
		node = self:_descend(node, k)

		-- Descend value: primitives go directly to node indexing
		if type(v) == "table" and v ~= self._nilKey and v ~= self._leafKey then
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

--- Assign and return a unique integer ID at a leaf node.
function Hash:_finalize(node)
	local id = node[self._leafKey]

	if id then return id end

	id = self._nextId
	self._nextId = id + 1
	node[self._leafKey] = id
	return id
end

--- Hash values extracted from a table by the given keys.
--
-- Usage: interner:internWith(config, "key1", "key2", "key3")
function Hash:internWith(tbl, ...)
	local values = {}
	local count = select("#", ...)

	for i = 1, count do
		local key = select(i, ...)
		values[i] = tbl and tbl[key] or nil
	end

	return self:intern(unpack(values, 1, count))
end

--- Hash a table by its keys in sorted order, then their values.
--
-- This provides a stable hash for dict-like tables where key order
-- matters but the table is not an array. Keys must be hashable
-- (nil, number, string, boolean).
--
-- Usage: interner:internDict(config)
function Hash:internDict(tbl)
	if type(tbl) ~= "table" then return self:intern(tbl) end

	if #tbl > 0 then return self:intern(tbl) end -- treat as array
	local keys = {}
	local keyCount = 0

	for k in pairs(tbl) do
		keyCount = keyCount + 1
		keys[keyCount] = k
	end

	if keyCount == 0 then
		return self:_finalize(self:_descend(self._root, self._nilKey))
	end

	-- Sort keys for stable ordering
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)

		if ta ~= tb then
			-- number < string < boolean (consistent ordering)
			if ta == "number" then return true end

			if tb == "number" then return false end

			if ta == "string" then return true end

			if tb == "string" then return false end

			return ta < tb
		end

		return a < b
	end)

	local node = self._root

	for i = 1, keyCount do
		local k = keys[i]
		node = self:_descend(node, k)
		node = self:_descend(node, tbl[k])
	end

	return self:_finalize(node)
end

return Hash
