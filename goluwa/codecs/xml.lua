--[[HOTRELOAD 
    run_file("test/xml.lua")
]]
--  XML Parser
-- A simple XML parser that converts XML documents into Lua tables
local xml = library()
xml.file_extensions = {"xml"}
local ffi = require("ffi")
local cast = ffi.cast
local uint8_ptr_t = ffi.typeof("const uint8_t*")

local function defaultEntityTable()
	return {
		quot = "\"",
		apos = "\'",
		lt = "<",
		gt = ">",
		amp = "&",
		tab = "\t",
		nbsp = " ",
	}
end

local function replaceEntities(s, entities)
	return s:gsub("&([^;]+);", entities)
end

local function createEntityTable(docEntities, resultEntities)
	local entities = resultEntities or defaultEntityTable()

	for _, e in pairs(docEntities) do
		e.value = replaceEntities(e.value, entities)
		entities[e.name] = e.value
	end

	return entities
end

local byte = string.byte
local sub = string.sub
local find = string.find
local BYTE_LT = byte("<")
local BYTE_GT = byte(">")
local BYTE_SLASH = byte("/")
local BYTE_QUESTION = byte("?")
local BYTE_EXCLAIM = byte("!")
local BYTE_SPACE = byte(" ")
local BYTE_TAB = byte("\t")
local BYTE_CR = byte("\r")
local BYTE_LF = byte("\n")
local BYTE_EQ = byte("=")
local BYTE_DQUOTE = byte("\"")
local BYTE_SQUOTE = byte("'")
local BYTE_DASH = byte("-")
local BYTE_COLON = byte(":")
local BYTE_UNDERSCORE = byte("_")
local BYTE_E = byte("E")
local is_whitespace_map = ffi.new("uint8_t[256]")
is_whitespace_map[BYTE_SPACE] = 1
is_whitespace_map[BYTE_TAB] = 1
is_whitespace_map[BYTE_CR] = 1
is_whitespace_map[BYTE_LF] = 1

local function is_whitespace(c)
	return is_whitespace_map[c] == 1
end

local is_name_char_map = ffi.new("uint8_t[256]")

for i = 0, 255 do
	local valid = (
			i >= 65 and
			i <= 90
		) -- A-Z
		or
		(
			i >= 97 and
			i <= 122
		) -- a-z
		or
		(
			i >= 48 and
			i <= 57
		) -- 0-9
		or
		i == BYTE_DASH or
		i == BYTE_COLON or
		i == BYTE_UNDERSCORE
	is_name_char_map[i] = valid and 1 or 0
end

local function is_name_char(c)
	return is_name_char_map[c] == 1
end

local function skip_whitespace(p, pos)
	while is_whitespace_map[p[pos - 1]] == 1 do
		pos = pos + 1
	end

	return pos
end

local function read_name(s, p, pos)
	local start = pos

	while is_name_char_map[p[pos - 1]] == 1 do
		pos = pos + 1
	end

	if pos == start then return nil, pos end

	return sub(s, start, pos - 1), pos
end

local function trim_text(txt)
	local len = #txt

	if len == 0 then return "" end

	local p = cast(uint8_ptr_t, txt)
	local start_pos = 0

	while start_pos < len and is_whitespace_map[p[start_pos]] == 1 do
		start_pos = start_pos + 1
	end

	if start_pos >= len then return "" end

	local end_pos = len - 1

	while end_pos >= start_pos and is_whitespace_map[p[end_pos]] == 1 do
		end_pos = end_pos - 1
	end

	if start_pos == 0 and end_pos == len - 1 then return txt end

	return sub(txt, start_pos + 1, end_pos + 1)
end

local function addtext(t, txt)
	txt = trim_text(txt)

	if #txt ~= 0 then
		t.n = t.n + 1
		t[t.n] = {text = txt}
	end
end

-- Parse an XML string into a Lua table structure
-- Returns a table with:
--   children: array of parsed elements
--   entities: document entities
--   tentities: (reserved)
function xml.Decode(s)
	local entities, tentities = {n = 0}, nil
	local t, l = {n = 0}, {n = 0}
	local pos = 1
	local len = #s
	local p = cast(uint8_ptr_t, s) -- keep s as reference to prevent GC
	while pos <= len do
		-- Find next '<'
		local lt_pos = find(s, "<", pos, true)

		if not lt_pos then
			-- No more tags, add remaining text
			local txt = sub(s, pos)
			addtext(t, txt)

			break
		end

		-- Add text before the tag
		if lt_pos > pos then
			local txt = sub(s, pos, lt_pos - 1)
			addtext(t, txt)
		end

		-- Check for comment
		if
			p[lt_pos - 1] == BYTE_LT and
			p[lt_pos] == BYTE_EXCLAIM and
			p[lt_pos + 1] == BYTE_DASH and
			p[lt_pos + 2] == BYTE_DASH
		then
			local comment_end = find(s, "-->", lt_pos + 4, true)

			if comment_end then pos = comment_end + 3 else pos = len + 1 end
		else
			-- Find closing '>'
			local gt_pos = find(s, ">", lt_pos + 1, true)

			if gt_pos then
				local tag_start = lt_pos + 1
				local first_char = p[tag_start - 1]

				if first_char == BYTE_SLASH then
					-- Close tag
					tag_start = tag_start + 1
					local tag_name, name_end = read_name(s, p, tag_start)

					if tag_name then
						t = l[l.n]
						l[l.n] = nil
						l.n = l.n - 1
					end
				elseif first_char == BYTE_QUESTION then

				-- Processing instruction, skip it
				elseif first_char == BYTE_EXCLAIM then
					-- DOCTYPE or ENTITY
					tag_start = tag_start + 1
					local name, name_end = read_name(s, p, tag_start)

					if name and sub(name, 1, 6) == "ENTITY" then
						-- Parse entity: <!ENTITY name "value">
						local entity_pos = skip_whitespace(p, name_end)
						local entity_name, entity_name_end = read_name(s, p, entity_pos)

						if entity_name then
							entity_pos = skip_whitespace(p, entity_name_end)
							local quote_char = p[entity_pos - 1]

							if quote_char == BYTE_DQUOTE or quote_char == BYTE_SQUOTE then
								local quote_str = sub(s, entity_pos, entity_pos)
								local value_start = entity_pos + 1
								local value_end = find(s, quote_str, value_start, true)

								if value_end then
									local entity_value = sub(s, value_start, value_end - 1)
									entities.n = entities.n + 1
									entities[entities.n] = {name = entity_name, value = entity_value}
								end
							end
						end
					end
				else
					-- Open tag
					local tag_name, name_end = read_name(s, p, tag_start)

					if tag_name then
						local attrs = {}
						local orderedattrs = {n = 0}
						local attr_pos = skip_whitespace(p, name_end)
						local self_closing = false

						-- Check for self-closing before '>'
						if p[gt_pos - 2] == BYTE_SLASH then self_closing = true end

						local attr_end_pos = self_closing and (gt_pos - 1) or gt_pos

						-- Parse attributes
						while attr_pos < attr_end_pos do
							local c = p[attr_pos - 1]

							if c == BYTE_SLASH or c == BYTE_GT then break end

							local attr_name, attr_name_end = read_name(s, p, attr_pos)

							if not attr_name then break end

							attr_pos = skip_whitespace(p, attr_name_end)

							if p[attr_pos - 1] ~= BYTE_EQ then break end

							attr_pos = skip_whitespace(p, attr_pos + 1)
							local quote_char = p[attr_pos - 1]

							if quote_char ~= BYTE_DQUOTE and quote_char ~= BYTE_SQUOTE then
								break
							end

							local quote_str = sub(s, attr_pos, attr_pos)
							local value_start = attr_pos + 1
							local value_end = find(s, quote_str, value_start, true)

							if not value_end then break end

							local attr_value = sub(s, value_start, value_end - 1)
							attrs[attr_name] = attr_value
							orderedattrs.n = orderedattrs.n + 1
							orderedattrs[orderedattrs.n] = {name = attr_name, value = attr_value}
							attr_pos = skip_whitespace(p, value_end + 1)
						end

						t.n = t.n + 1
						t[t.n] = {tag = tag_name, attrs = attrs, children = {n = 0}, orderedattrs = orderedattrs}

						if not self_closing then
							l.n = l.n + 1
							l[l.n] = t
							t = t[t.n].children
						end
					end
				end

				pos = gt_pos + 1
			end
		end
	end

	return {children = t, entities = entities, tentities = tentities}
end

-- Parse an XML file
-- Returns parsed document table and nil on success
-- Returns nil and error message on failure
function xml.parse_file(filename)
	local f, err = io.open(filename)

	if f then
		local content = f:read("*a")
		f:close()
		return xml.parse(content), nil
	end

	return nil, err
end

local PROFILE = false

if PROFILE then
	local fs = require("fs")
	local files = {}

	for i, v in ipairs(fs.walk("goluwa/bindings/wayland/")) do
		if v:ends_with(".xml") then files[#files + 1] = fs.read_file(v) end
	end

	local profiler = require("profiler")

	do
		profiler.Start("XML")
		local max = #files

		for i = 1, 1000 do
			for i, v in ipairs(files) do
				--io.write("parsing file ", i, " of ", max, "\n")
				assert(xml.parse(v))
			end
		end

		profiler.Stop()
	end
end

return xml
