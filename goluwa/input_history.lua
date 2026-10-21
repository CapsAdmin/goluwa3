local codec = import("goluwa/codec.lua")
local InputHistory = {}
InputHistory.__index = InputHistory

function InputHistory.New(config)
	config = config or {}
	local self = setmetatable(
		{
			Name = config.Name,
			MaxEntries = config.MaxEntries or 500,
			entries = {},
			edits = {},
			browsing = false,
			index = nil,
			draft = "",
			prefix = nil,
		},
		InputHistory
	)

	if self.Name then self:Load() end

	return self
end

function InputHistory:GetPath()
	return "data/history_" .. self.Name .. ".txt"
end

function InputHistory:Load()
	local entries = codec.ReadFile("luadata", self:GetPath())

	if entries then
		self.entries = entries

		while #self.entries > self.MaxEntries do
			table.remove(self.entries, 1)
		end
	end
end

function InputHistory:Save()
	if self.Name then codec.WriteFile("luadata", self:GetPath(), self.entries) end
end

function InputHistory:GetEntries()
	return self.entries
end

function InputHistory:GetCount()
	return #self.entries
end

function InputHistory:IsBrowsing()
	return self.browsing
end

function InputHistory:GetIndex()
	return self.index
end

function InputHistory:Reset()
	self.browsing = false
	self.index = nil
	self.prefix = nil
	self.draft = ""
	table.clear(self.edits)
end

function InputHistory:Add(text)
	self:Reset()

	if not text:find("%S") or self.entries[#self.entries] == text then
		return false
	end

	for i = #self.entries, 1, -1 do
		if self.entries[i] == text then table.remove(self.entries, i) end
	end

	table.insert(self.entries, text)

	while #self.entries > self.MaxEntries do
		table.remove(self.entries, 1)
	end

	self:Save()
	return true
end

function InputHistory:Remove(index)
	table.remove(self.entries, index)
	self:Reset()
	self:Save()
end

function InputHistory:Clear()
	table.clear(self.entries)
	self:Reset()
	self:Save()
end

function InputHistory:Search(query)
	local out = {}
	query = query:lower()

	for i = #self.entries, 1, -1 do
		if self.entries[i]:lower():find(query, 1, true) then
			table.insert(out, {index = i, text = self.entries[i]})
		end
	end

	return out
end

function InputHistory:store_edit(current_text)
	if not self.index then return end

	self.edits[self.index] = current_text ~= self.entries[self.index] and current_text or nil
end

function InputHistory:find(from, step)
	local prefix = self.prefix

	for i = from, step > 0 and #self.entries or 1, step do
		if not prefix or self.entries[i]:starts_with(prefix) then return i end
	end
end

function InputHistory:Older(current_text, prefix)
	if not self.browsing then
		self.browsing = true
		self.draft = current_text
		self.prefix = prefix
		self.index = nil
	else
		self:store_edit(current_text)
	end

	local found = self:find((self.index or #self.entries + 1) - 1, -1)

	if not found then
		if not self.index then self.browsing = false end

		return nil
	end

	self.index = found
	return self.edits[found] or self.entries[found]
end

function InputHistory:Newer(current_text)
	if not self.browsing then return nil end

	self:store_edit(current_text)
	local found = self:find(self.index + 1, 1)

	if found then
		self.index = found
		return self.edits[found] or self.entries[found]
	end

	self.browsing = false
	self.index = nil
	self.prefix = nil
	return self.draft
end

return InputHistory
