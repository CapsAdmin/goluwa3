local utf8 = import("goluwa/string/utf8.lua")
local objects = import("goluwa/objects/objects.lua")
local pretext = import("goluwa/pretext/init.lua")
local META = objects.CreateTemplate("font_base")
META.IsFont = true
META:GetSet("Path", "default")
META:GetSet("Size", 8)
META:IsSet("Ready", false)

function META:__copy()
	return self
end

function META:DrawText(str, x, y, spacing, align_x, align_y, extra_space_advance)
	if align_x or align_y then
		local w, h = self:GetTextSize(str)

		if type(align_x) == "number" then
			x = x - (w * align_x)
		elseif align_x == "center" then
			x = x - (w / 2)
		elseif align_x == "right" then
			x = x - w
		end

		if type(align_y) == "number" then
			y = y - (h * align_y)
		elseif align_y == "baseline" then
			y = y - self:GetAscent()
		elseif align_y == "center" then
			y = y - (h / 2)
		elseif align_y == "bottom" then
			y = y - h
		end
	end

	self:DrawString(str, x, y, spacing, extra_space_advance)
end

function META:GetSpaceAdvance()
	local width = select(1, self:GetTextSize(" "))

	if width == 0 then
		width = select(1, self:GetTextSize("| |")) - select(1, self:GetTextSize("||"))
	end

	return width
end

function META:GetTabAdvance(space_width, tab_size, current_width)
	if self.GetTabWidth then
		return self:GetTabWidth(space_width, tab_size, current_width)
	end

	return (space_width or self:GetSpaceAdvance()) * (tab_size or 4)
end

function META:GetGlyphAdvance(char)
	return select(1, self:GetTextSize(char))
end

function META:MeasureText(str)
	return self:GetTextSize(str)
end

function META:WrapString(str, max_width)
	str = tostring(str or "")
	max_width = max_width or 0
	self.wrap_string_cache = self.wrap_string_cache or {}
	local cache_key = tostring(max_width) .. "\0" .. str

	if self.wrap_string_cache[cache_key] ~= nil then
		return self.wrap_string_cache[cache_key]
	end

	local size = self:GetTextSize(str)

	if max_width > size then
		self.wrap_string_cache[cache_key] = str
		return str
	end

	local wrapped = pretext.wrap_font_text(self, str, max_width)
	self.wrap_string_cache[cache_key] = wrapped
	return wrapped
end

return META:Register()
