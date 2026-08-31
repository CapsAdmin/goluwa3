local Hash = {}
Hash.__index = Hash
local NIL = {}

function Hash.New()
	return setmetatable({
		root = {},
		next_id = 1,
		leaf_key = {},
	}, Hash)
end

local function descend(self, node, value)
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
				node = descend(self, node, value[i])
			end

			return node
		else
			value = NIL
		end
	end

	local child = node[value]

	if not child then
		child = {}
		node[value] = child
	end

	return child
end

local function finalize(self, node)
	local id = node[self.leaf_key]

	if id then return id end

	id = self.next_id
	self.next_id = id + 1
	node[self.leaf_key] = id
	return id
end

function Hash:intern(list, count)
	local node = self.root

	if count == nil then count = list and #list or 0 end

	for i = 1, count do
		node = descend(self, node, list[i])
	end

	return finalize(self, node)
end

function Hash:intern_scalars(list, count)
	local node = self.root

	for i = 1, count do
		local value = list[i]
		local child = node[value]

		if not child then
			child = {}
			node[value] = child
		end

		node = child
	end

	return finalize(self, node)
end

function Hash:intern_with_keys(tbl, keys)
	local node = self.root

	for i = 1, #keys do
		node = descend(self, node, tbl and tbl[keys[i]] or nil)
	end

	return finalize(self, node)
end

return Hash
