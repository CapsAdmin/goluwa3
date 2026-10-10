local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local History = objects.CreateTemplate("history")
History:GetSet("Limit", 500)
-- pushes with the same Key closer together than this (seconds) become one entry, a slider drag is one edit
History:GetSet("MergeTime", 0.75)

function History.New()
	return History:CreateObject{
		entries = {},
		index = 0,
		depth = 0,
		applying = false,
	}
end

local function notify(self)
	event.Call("HistoryChanged", self)
end

-- entry is {Name, Undo = function, Redo = function, Key = optional merge key}, the change itself has already happened
function History:Push(entry)
	if self.applying then return end

	assert(entry.Undo and entry.Redo and entry.Name, "a history entry needs Name, Undo and Redo")
	local now = system.GetElapsedTime()

	if self.depth > 0 then
		self.group[#self.group + 1] = entry
		return
	end

	local entries = self.entries
	local last = entries[self.index]

	if
		entry.Key and
		last and
		self.index == #entries and
		last.Key == entry.Key and
		now - last.Time < self.MergeTime
	then
		last.Redo = entry.Redo
		last.Time = now
		notify(self)
		return
	end

	for i = #entries, self.index + 1, -1 do
		entries[i] = nil
	end

	entry.Time = now
	entries[#entries + 1] = entry

	if #entries > self.Limit then table.remove(entries, 1) end

	self.index = #entries
	notify(self)
end

-- every entry pushed until the matching End is one entry
function History:Begin(name)
	self.depth = self.depth + 1

	if self.depth == 1 then
		self.group = {}
		self.group_name = name
	end
end

function History:End()
	self.depth = self.depth - 1

	if self.depth > 0 then return end

	local group = self.group
	self.group = nil

	if #group == 0 then return end

	if #group == 1 then
		group[1].Name = self.group_name
		group[1].Key = nil
		self:Push(group[1])
		return
	end

	self:Push{
		Name = self.group_name,
		Undo = function()
			for i = #group, 1, -1 do
				group[i].Undo()
			end
		end,
		Redo = function()
			for i = 1, #group do
				group[i].Redo()
			end
		end,
	}
end

function History:CanUndo()
	return self.index > 0
end

function History:CanRedo()
	return self.index < #self.entries
end

function History:Undo()
	if self.index == 0 then return false end

	local entry = self.entries[self.index]
	self.applying = true
	local ok, err = pcall(entry.Undo)
	self.applying = false
	self.index = self.index - 1
	notify(self)

	if not ok then error(err, 0) end

	return true
end

function History:Redo()
	if self.index == #self.entries then return false end

	local entry = self.entries[self.index + 1]
	self.applying = true
	local ok, err = pcall(entry.Redo)
	self.applying = false
	self.index = self.index + 1
	notify(self)

	if not ok then error(err, 0) end

	return true
end

-- steps until index entries are applied, 0 is the state before the first entry
function History:GoTo(index)
	while self.index > index do
		self:Undo()
	end

	while self.index < index do
		self:Redo()
	end
end

function History:Clear()
	self.entries = {}
	self.index = 0
	notify(self)
end

function History:GetEntries()
	return self.entries
end

function History:GetIndex()
	return self.index
end

function History:IsApplying()
	return self.applying
end

History:Register()
return History
