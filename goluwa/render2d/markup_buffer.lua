local prototype = require("prototype")
local utf8 = require("utf8")
local SequenceBuffer = require("sequence_buffer")
local MarkupBuffer = prototype.CreateTemplate("markup_buffer")
MarkupBuffer.Base = SequenceBuffer

function MarkupBuffer.New(str_or_chunks, markup_obj)
	local self = MarkupBuffer:CreateObject({
		chunks = {},
		markup = markup_obj,
	})

	if type(str_or_chunks) == "string" then
		self:SetText(str_or_chunks)
	elseif type(str_or_chunks) == "table" then
		self.chunks = str_or_chunks
	end

	return self
end

function MarkupBuffer:GetChunks()
	return self.chunks
end

function MarkupBuffer:Clear()
	table.clear(self.chunks)
	self.lines = nil
	self.Text = nil
end

function MarkupBuffer:SetText(str)
	if self.markup then
		self.chunks = self.markup:StringTagsToTable(str)
	else
		self.chunks = {{type = "string", val = str}}
	end

	self.lines = nil
	self.Text = nil
end

function MarkupBuffer:GetText()
	if self.Text then return self.Text end

	local out = {}

	for _, chunk in ipairs(self.chunks) do
		if chunk.type == "string" then
			table.insert(out, chunk.val)
		elseif chunk.type == "newline" then
			table.insert(out, "\n")
		elseif chunk.w and chunk.w > 0 and chunk.h and chunk.h > 0 then
			table.insert(out, " ")
		end
	end

	self.Text = table.concat(out)
	return self.Text
end

function MarkupBuffer:GetLength()
	return utf8.length(self:GetText())
end

function MarkupBuffer:Sub(i, j)
	return utf8.sub(self:GetText(), i, j)
end

function MarkupBuffer:Insert(pos, str)
	local current_pos = 1
	local inserted = false

	for i, chunk in ipairs(self.chunks) do
		local chunk_len = 0

		if chunk.type == "string" then
			chunk_len = utf8.length(chunk.val)
		elseif chunk.type == "newline" or (chunk.w and chunk.w > 0 and chunk.h and chunk.h > 0) then
			chunk_len = 1
		end

		if pos >= current_pos and pos <= current_pos + chunk_len then
			if chunk.type == "string" then
				local offset = pos - current_pos
				chunk.val = utf8.sub(chunk.val, 1, offset) .. str .. utf8.sub(chunk.val, offset + 1)
				inserted = true

				break
			elseif pos == current_pos then
				-- Insert before this non-string chunk
				table.insert(self.chunks, i, {type = "string", val = str})
				inserted = true

				break
			end
		end

		current_pos = current_pos + chunk_len
	end

	if not inserted then table.insert(self.chunks, {type = "string", val = str}) end

	self.lines = nil
	self.Text = nil
	return utf8.length(str)
end

function MarkupBuffer:InsertChunks(pos, chunks)
	local current_pos = 1
	local inserted = false

	for i, chunk in ipairs(self.chunks) do
		local chunk_len = 0

		if chunk.type == "string" then
			chunk_len = utf8.length(chunk.val)
		elseif chunk.type == "newline" or (chunk.w and chunk.w > 0 and chunk.h and chunk.h > 0) then
			chunk_len = 1
		end

		if pos >= current_pos and pos <= current_pos + chunk_len then
			-- Insert at this chunk boundary or within it
			if chunk.type == "string" and pos > current_pos and pos < current_pos + chunk_len then
				-- Split string chunk
				local offset = pos - current_pos
				local part1 = utf8.sub(chunk.val, 1, offset)
				local part2 = utf8.sub(chunk.val, offset + 1)
				chunk.val = part1

				-- Insert chunks after part1
				for j = 1, #chunks do
					table.insert(self.chunks, i + j, chunks[j])
				end

				-- Insert part2 after the new chunks
				table.insert(self.chunks, i + #chunks + 1, {type = "string", val = part2})
				inserted = true

				break
			else
				-- Boundary (start or end of chunk)
				local insert_at = i

				if pos > current_pos then insert_at = i + 1 end

				for j = 1, #chunks do
					table.insert(self.chunks, insert_at + j - 1, chunks[j])
				end

				inserted = true

				break
			end
		end

		current_pos = current_pos + chunk_len
	end

	if not inserted then
		for _, chunk in ipairs(chunks) do
			table.insert(self.chunks, chunk)
		end
	end

	self.lines = nil
	self.Text = nil
end

function MarkupBuffer:RemoveRange(start, stop)
	local current_pos = 1
	local i = 1

	while i <= #self.chunks do
		local chunk = self.chunks[i]
		local chunk_len = 0

		if chunk.type == "string" then
			chunk_len = utf8.length(chunk.val)
		elseif chunk.type == "newline" or (chunk.w and chunk.w > 0 and chunk.h and chunk.h > 0) then
			chunk_len = 1
		end

		local chunk_start = current_pos
		local chunk_end = current_pos + chunk_len

		if chunk_start < stop and chunk_end >= start then
			-- Overlap
			if chunk.type == "string" then
				local rel_start = math.max(1, start - chunk_start + 1)
				local rel_stop = math.min(chunk_len, stop - chunk_start)
				-- remove rel_start to rel_stop inclusive (in utf8 terms)
				chunk.val = utf8.sub(chunk.val, 1, rel_start - 1) .. utf8.sub(chunk.val, rel_stop + 1)

				if chunk.val == "" then
					table.remove(self.chunks, i)
					i = i - 1
				end
			else
				-- non-string chunk (newline or object)
				table.remove(self.chunks, i)
				i = i - 1
			end
		end

		i = i + 1
		current_pos = current_pos + chunk_len
	end

	self.lines = nil
	self.Text = nil
end

function MarkupBuffer:AddColor(color)
	table.insert(self.chunks, {type = "color", val = color})
end

function MarkupBuffer:AddFont(font)
	table.insert(self.chunks, {type = "font", val = font})
end

function MarkupBuffer:AddString(str, tags)
	if tags and self.markup then
		for _, chunk in ipairs(self.markup:StringTagsToTable(str)) do
			table.insert(self.chunks, chunk)
		end
	else
		table.insert(self.chunks, {type = "string", val = tostring(str)})
	end
end

function MarkupBuffer:AddTagStopper()
	table.insert(self.chunks, {type = "tag_stopper", val = true})
end

function MarkupBuffer:GetFullText()
	return self:GetFullTextSub(1, self:GetLength() + 1)
end

function MarkupBuffer:GetFullTextSub(start, stop)
	local out = {}
	local current_pos = 1

	for _, chunk in ipairs(self.chunks) do
		local chunk_len = 0

		if chunk.type == "string" then
			chunk_len = utf8.length(chunk.val)
		elseif chunk.type == "newline" or (chunk.w and chunk.w > 0 and chunk.h and chunk.h > 0) then
			chunk_len = 1
		end

		local chunk_start = current_pos
		local chunk_end = current_pos + chunk_len

		if chunk_start < stop and chunk_end >= start then
			if chunk.type == "string" then
				local rel_start = math.max(1, start - chunk_start + 1)
				local rel_stop = math.min(chunk_len, stop - chunk_start)
				table.insert(out, utf8.sub(chunk.val, rel_start, rel_stop))
			elseif chunk.type == "newline" then
				table.insert(out, "\n")
			elseif chunk.type == "color" then
				local c = chunk.val
				table.insert(out, ("<color=%s,%s,%s,%s>"):format(c.r, c.g, c.b, c.a))
			elseif chunk.type == "font" then
				table.insert(out, ("<font=%s>"):format(chunk.val:GetName()))
			elseif chunk.type == "tag_stopper" then
				table.insert(out, "</>")
			elseif chunk.type == "custom" then
				local val = chunk.val

				if val.stop_tag then
					table.insert(out, ("</%s>"):format(val.type))
				else
					local args = ""

					if val.args and #val.args > 0 then
						args = "=" .. table.concat(val.args, ",")
					end

					table.insert(out, ("<%s%s>"):format(val.type, args))
				end
			end
		end

		current_pos = current_pos + chunk_len
	end

	return table.concat(out)
end

MarkupBuffer:Register()
return MarkupBuffer
