local data_history = {}
local META = {}
META.__index = META
local COALESCE_TIME = 0.6
local MAX_STEPS = 200

function data_history.New(data)
	return setmetatable({Last = table.copy(data), Undo = {}, Redo = {}, Time = -math.huge}, META)
end

function META:Commit(data, now, force)
	if force or now - self.Time > COALESCE_TIME then
		self.Undo[#self.Undo + 1] = self.Last

		if #self.Undo > MAX_STEPS then table.remove(self.Undo, 1) end

		self.Redo = {}
	end

	self.Last = table.copy(data)
	self.Time = now
end

function META:Step(from, to)
	local state = table.remove(from)

	if not state then return end

	to[#to + 1] = self.Last
	self.Last = state
	self.Time = -math.huge
	return table.copy(state)
end

function META:DoUndo()
	return self:Step(self.Undo, self.Redo)
end

function META:DoRedo()
	return self:Step(self.Redo, self.Undo)
end

return data_history
