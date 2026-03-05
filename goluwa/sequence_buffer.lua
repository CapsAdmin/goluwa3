local prototype = require("prototype")
local utf8 = require("utf8")
local SequenceBuffer = prototype.CreateTemplate("sequence_buffer")

function SequenceBuffer.New(str)
	return SequenceBuffer:CreateObject({
		Text = str or "",
		list = nil,
		lines = nil,
	})
end

function SequenceBuffer:SetText(str)
	self.Text = str
	self.lines = nil
	self.list = nil
end

function SequenceBuffer:GetLines()
	if not self.lines then self.lines = self:Split(self:GetNewline()) end

	return self.lines
end

function SequenceBuffer:SetLines(lines)
	self:SetText(table.concat(lines, self:GetNewline()))
	self.lines = lines
	self.list = nil
end

function SequenceBuffer:GetText()
	if self.list and not self.Text then
		self.Text = table.concat(self.list)
	end
	return self.Text
end

function SequenceBuffer:GetList()
	if not self.list then
		self.list = utf8.to_list(self.Text)
	end

	return self.list
end

function SequenceBuffer:GetNewline()
	return "\n"
end

function SequenceBuffer:GetTab()
	return "\t"
end

function SequenceBuffer:GetLength(str)
	if type(self) ~= "table" then return utf8.length(self) end

	if str then return utf8.length(str) end

	return #self:GetList()
end

function SequenceBuffer:Sub(i, j)
	if type(self) ~= "table" then return utf8.sub(self, i, j) end

	local list = self:GetList()
	local len = #list
	if i < 0 then i = len + i + 1 end
	if not j then j = -1 end
	if j < 0 then j = len + j + 1 end
	if i < 1 then i = 1 end
	if j > len then j = len end
	if i > j then return "" end

	return table.concat(list, "", i, j)
end

function SequenceBuffer:ToTable()
	return self:GetList()
end

function SequenceBuffer.GetTable(str)
	return utf8.to_list(str)
end

function SequenceBuffer.MidSplit(str)
	return utf8.mid_split(str)
end

function SequenceBuffer:Insert(pos, str)
	local list = self:GetList()
	local str_list = utf8.to_list(str)
	for i = 1, #str_list do
		table.insert(list, pos + i - 1, str_list[i])
	end
	self.Text = nil
	self.lines = nil
	return utf8.length(str)
end

function SequenceBuffer:RemoveRange(start, stop)
	local list = self:GetList()
	for i = 1, stop - start do
		table.remove(list, start)
	end
	self.Text = nil
	self.lines = nil
end

function SequenceBuffer:Split(sep)
	return self:GetText():split(sep, true)
end

function SequenceBuffer:GetLineCount()
	return #self:GetLines()
end

function SequenceBuffer:GetLine(line_index)
	return self:GetLines()[line_index]
end

function SequenceBuffer:GetLineStart(pos)
	local start_pos = pos
	local newline = self:GetNewline()

	while start_pos > 1 and self:Sub(start_pos - 1, start_pos - 1) ~= newline do
		start_pos = start_pos - 1
	end

	return start_pos
end

function SequenceBuffer:GetLineEnd(pos)
	local end_pos = pos
	local len = self:GetLength()
	local newline = self:GetNewline()

	while end_pos <= len and self:Sub(end_pos, end_pos) ~= newline do
		end_pos = end_pos + 1
	end

	return end_pos
end

local function get_char_class(char)
	if not char then return "none" end

	if char:match("[%w_]") then return "word" end

	if char:match("%s") then return "space" end

	return "other"
end

function SequenceBuffer:GetNextWordBoundary(pos, dir)
	local len = self:GetLength()
	local new_pos = pos

	if dir == -1 then
		if new_pos <= 1 then return 1 end

		while new_pos > 1 and get_char_class(self:Sub(new_pos - 1, new_pos - 1)) == "space" do
			new_pos = new_pos - 1
		end

		if new_pos <= 1 then return 1 end

		new_pos = new_pos - 1
		local class = get_char_class(self:Sub(new_pos, new_pos))

		while new_pos > 1 and get_char_class(self:Sub(new_pos - 1, new_pos - 1)) == class do
			new_pos = new_pos - 1
		end
	else
		while new_pos <= len and get_char_class(self:Sub(new_pos, new_pos)) == "space" do
			new_pos = new_pos + 1
		end

		if new_pos > len then return len + 1 end

		local class = get_char_class(self:Sub(new_pos, new_pos))

		while new_pos <= len and get_char_class(self:Sub(new_pos, new_pos)) == class do
			new_pos = new_pos + 1
		end
	end

	return new_pos
end

function SequenceBuffer:GetIndentation(line_index)
	local line = self:GetLine(line_index) or ""
	return line:match("^([\t ]*)") or ""
end

function SequenceBuffer:IndentLine(line_index, back)
	local lines = self:GetLines()
	local line = lines[line_index]

	if not line then return end

	local tab = self:GetTab()

	if back then
		if line:sub(1, #tab) == tab then
			lines[line_index] = line:sub(#tab + 1)
		elseif line:sub(1, 4) == "    " then
			lines[line_index] = line:sub(5)
		end
	else
		lines[line_index] = tab .. line
	end

	self:SetLines(lines)
end

function SequenceBuffer:GetLineColByPos(pos)
	local line = 1
	local col = 1
	local newline = self:GetNewline()

	for i = 1, pos - 1 do
		if self:Sub(i, i) == newline then
			line = line + 1
			col = 1
		else
			col = col + 1
		end
	end

	return line, col
end

function SequenceBuffer:GetPosByLineCol(target_line, target_col)
	local line = 1
	local col = 1
	local pos = 1
	local len = self:GetLength()
	local newline = self:GetNewline()

	while pos <= len do
		if line == target_line then if col == target_col then return pos end end

		if self:Sub(pos, pos) == newline then
			if line == target_line then return pos end

			line = line + 1
			col = 1
		else
			col = col + 1
		end

		pos = pos + 1
	end

	return pos
end

SequenceBuffer:Register()
return SequenceBuffer
