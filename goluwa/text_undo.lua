local system = import("goluwa/system.lua")
local utf8 = import("goluwa/string/utf8.lua")
local TextUndo = {}
TextUndo.__index = TextUndo

function TextUndo.New(config)
	config = config or {}
	local self = setmetatable(
		{
			Limit = config.Limit or 200,
			MergeTime = config.MergeTime or 1,
			states = {},
			index = 0,
			sealed = true,
		},
		TextUndo
	)
	self:Reset("", 1)
	return self
end

function TextUndo:Reset(text, cursor)
	self.states = {
		{
			text = text,
			cursor = cursor,
			undo_cursor = cursor,
			kind = "edit",
			time = 0,
			edit_start = 0,
			edit_end = 0,
		},
	}
	self.index = 1
	self.sealed = true
end

function TextUndo:CanUndo()
	return self.index > 1
end

function TextUndo:CanRedo()
	return self.index < #self.states
end

function TextUndo:GetCount()
	return #self.states - 1
end

function TextUndo:Push(text, cursor)
	local current = self.states[self.index]

	if text == current.text then
		current.cursor = cursor
		return
	end

	local old = current.text
	local prefix = 0
	local shortest = math.min(#old, #text)

	while prefix < shortest and old:byte(prefix + 1) == text:byte(prefix + 1) do
		prefix = prefix + 1
	end

	local suffix = 0

	while
		suffix < shortest - prefix and
		old:byte(#old - suffix) == text:byte(#text - suffix)
	do
		suffix = suffix + 1
	end

	local removed = old:sub(prefix + 1, #old - suffix)
	local added = text:sub(prefix + 1, #text - suffix)
	local kind = "edit"

	if removed == "" and utf8.length(added) == 1 then
		kind = "insert"
	elseif added == "" and utf8.length(removed) == 1 then
		kind = "delete"
	end

	local now = system.GetElapsedTime()
	local merge = not self.sealed and
		kind ~= "edit" and
		current.kind == kind and
		now - current.time < self.MergeTime

	if merge then
		if kind == "insert" then
			merge = prefix == current.edit_end and not added:find("^%s")
		else
			merge = prefix + #removed == current.edit_start or prefix == current.edit_start
		end
	end

	self.sealed = false

	if merge then
		current.text = text
		current.cursor = cursor
		current.time = now
		current.edit_start = prefix
		current.edit_end = prefix + #added
		return
	end

	for i = #self.states, self.index + 1, -1 do
		self.states[i] = nil
	end

	local undo_cursor = utf8.length(old:sub(1, prefix)) + (kind == "delete" and 2 or 1)
	self.states[#self.states + 1] = {
		text = text,
		cursor = cursor,
		undo_cursor = undo_cursor,
		kind = kind,
		time = now,
		edit_start = prefix,
		edit_end = prefix + #added,
	}

	if #self.states > self.Limit then table.remove(self.states, 1) end

	self.index = #self.states
end

function TextUndo:Undo()
	if self.index <= 1 then return nil end

	local undone = self.states[self.index]
	self.index = self.index - 1
	self.sealed = true
	return {text = self.states[self.index].text, cursor = undone.undo_cursor}
end

function TextUndo:Redo()
	if self.index >= #self.states then return nil end

	self.index = self.index + 1
	self.sealed = true
	return self.states[self.index]
end

return TextUndo
