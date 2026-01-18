local fonts = library()
-- Font management
local current_font = nil
local default_font = nil
local X, Y = 0, 0

function fonts.LoadFont(path, size)
	size = size or 16
	local ext = path:match("%.([^%.]+)$")

	if ext == "ttf" or ext == "otf" then
		local ttf_font = require("render2d.fonts.ttf")
		local font = ttf_font.New(path)
		font:SetSize(size)
		-- Wrap in rasterized_font for texture atlas support
		local rasterized = require("render2d.fonts.rasterized_font")
		return rasterized.New(font)
	end

	error("Unsupported font format: " .. tostring(ext))
end

function fonts.GetDefaultFont()
	if not default_font then
		local base_font = require("render2d.fonts.base")
		default_font = base_font.New()
	end

	return default_font
end

function fonts.GetFallbackFont()
	return fonts.GetDefaultFont()
end

function fonts.SetFont(font)
	current_font = font or fonts.GetDefaultFont()
end

function fonts.GetFont()
	return current_font or fonts.GetDefaultFont()
end

-- Text positioning
function fonts.SetTextPosition(x, y)
	X = x or X
	Y = y or Y
end

function fonts.GetTextPosition()
	return X, Y
end

-- Drawing functions
function fonts.DrawText(str, x, y, spacing, align_x, align_y)
	x = x or X
	y = y or Y

	if align_x or align_y then
		local w, h = fonts.GetTextSize(fonts.GetFont(), str)
		x = x - (w * (align_x or 0))
		y = y - (h * (align_y or 0))
	end

	fonts.GetFont():DrawString(str, x, y, spacing)
	X = x
	Y = y
end

do
	local cache = {} or table.weak()

	function fonts.GetTextSize(font, str)
		str = str or "|"

		if cache[font] and cache[font][str] then
			return cache[font][str][1], cache[font][str][2]
		end

		local x, y = font:GetTextSize(str)
		cache[font] = cache[font] or table.weak()
		cache[font][str] = cache[font][str] or table.weak()
		cache[font][str][1] = x
		cache[font][str][2] = y
		return x, y
	end

	function fonts.InvalidateFontSizeCache(font)
		if font then cache[font] = nil else cache = {} end
	end
end

do -- text wrap
	local function wrap_1(str, max_width)
		local lines = {}
		local i = 1
		local last_pos = 0
		local line_width = 0
		local space_pos
		local tbl = str:utf8_to_list()

		--local pos = 1
		--for _ = 1, 10000 do
		--	local char = tbl[pos]
		--	if not char then break end
		for pos, char in ipairs(tbl) do
			local w = fonts.GetTextSize(font, char)

			if char:find("%s") then space_pos = pos end

			if line_width + w >= max_width then
				if space_pos then
					lines[i] = str:utf8_sub(last_pos + 1, space_pos)
					last_pos = space_pos
				else
					lines[i] = str:utf8_sub(last_pos + 1, pos)
					last_pos = pos
				end

				i = i + 1
				line_width = 0
				space_pos = nil
			end

			line_width = line_width + w
		--pos = pos + 1
		end

		if lines[1] then
			lines[i] = str:utf8_sub(last_pos + 1)
			return list.concat(lines, "\n")
		end

		return str
	end

	local function wrap_2(str, max_width, font)
		local tbl = str:utf8_to_list()
		local lines = {}
		local chars = {}
		local i = 1
		local width = 0
		local width_before_last_space = 0
		local width_of_trailing_space = 0
		local last_space_index = -1
		local prev_char

		while i < #tbl do
			local c = tbl[i]
			local char_width = fonts.GetTextSize(font, c)
			local new_width = width + char_width

			if c == "\n" then
				list.insert(lines, list.concat(chars))
				list.clear(chars)
				width = 0
				width_before_last_space = 0
				width_of_trailing_space = 0
				prev_char = nil
				last_space_index = -1
				i = i + 1
			elseif char ~= " " and width >= max_width then
				if #chars == 0 then
					i = i + 1
				elseif last_space_index ~= -1 then
					for i = #chars, 1, -1 do
						if chars[i] == " " then break end

						list.remove(chars, i)
					end

					width = width_before_last_space
					i = last_space_index
					i = i + 1
				end

				list.insert(lines, list.concat(chars))
				list.clear(chars)
				prev_char = nil
				width = char_width
				width_before_last_space = 0
				width_of_trailing_space = 0
				last_space_index = -1
			else
				if prev_char ~= " " and c == " " then
					width_before_last_space = width
				end

				width = new_width
				prev_char = c
				list.insert(chars, c)

				if c == " " then
					last_space_index = i
				elseif c ~= "\n" then
					width_of_trailing_space = 0
				end

				i = i + 1
			end
		end

		if #chars ~= 0 then list.insert(lines, list.concat(chars)) end

		return list.concat(lines, "\n")
	end

	local cache = table.weak()

	function fonts.WrapString(font, str, max_width)
		if cache[str] and cache[str][max_width] and cache[str][max_width][font] then
			return cache[str][max_width][font]
		end

		if max_width < fonts.GetTextSize(font, nil) then
			return list.concat(str:split(""), "\n")
		end

		if max_width > fonts.GetTextSize(font, str) then return str end

		local res = wrap_2(str, max_width, font)
		cache[str] = cache[str] or {}
		cache[str][max_width] = cache[str][max_width] or {}
		cache[str][max_width][font] = res
		return res
	end
end

function fonts.DotLimitText(font, text, w)
	local strw, strh = fonts.GetTextSize(font, text)
	local dot_w = fonts.GetTextSize(font, ".")

	if strw > w + 2 then
		local x = 0

		for i, char in ipairs(text:utf8_to_list()) do
			if x >= w - dot_w * 3 then return text:utf8_sub(0, i - 2) .. "..." end

			x = x + fonts.GetTextSize(font, char)
		end
	end

	return text
end

return fonts
