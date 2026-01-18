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
		local rasterized_font = require("render2d.fonts.rasterized_font")
		return rasterized_font.New(font)
	end

	error("Unsupported font format: " .. tostring(ext))
end

function fonts.GetDefaultFont()
	if not default_font then
		local base_font = require("render2d.fonts.base")
		local rasterized_font = require("render2d.fonts.rasterized_font")
		default_font = rasterized_font.New(base_font)
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

return fonts
