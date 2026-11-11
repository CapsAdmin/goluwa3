local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("tree")

function META.IsLeaf(node)
	return type(node.size) == "number"
end

local is_leaf = META.IsLeaf

function META:SetEntry(str, value)
	local node = self.tree
	local parent_key
	local pattern = "[^" .. self.delimiter .. "]+"

	for key in str:gmatch(pattern) do
		if parent_key then
			local child = node[parent_key]

			if not child or is_leaf(child) then
				child = {}
				node[parent_key] = child
			end

			node = child
		end

		parent_key = key
	end

	node[parent_key] = value
end

function META:GetEntry(str)
	local node = self.tree

	for key in str:gmatch("[^" .. self.delimiter .. "]+") do
		if is_leaf(node) then return false, "key " .. key .. " not found" end

		node = node[key]

		if not node then return false, "key " .. key .. " not found" end
	end

	return node
end

function META.New(delimiter, tree)
	local self = META:CreateObject()
	self.tree = tree or {}
	self.delimiter = delimiter
	return self
end

return META:Register()
