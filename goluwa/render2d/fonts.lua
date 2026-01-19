local fs = require("fs")
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

function fonts.GetSystemFonts()
	local paths = {}

	if WINDOWS then
		table.insert(paths, os.getenv("WINDIR") .. "/Fonts")
		local local_app_data = os.getenv("LOCALAPPDATA")

		if local_app_data then
			table.insert(paths, local_app_data .. "/Microsoft/Windows/Fonts")
		end
	elseif OSX then
		table.insert(paths, "/System/Library/Fonts")
		table.insert(paths, "/Library/Fonts")
		table.insert(paths, os.getenv("HOME") .. "/Library/Fonts")
	elseif LINUX then
		table.insert(paths, "/usr/share/fonts")
		table.insert(paths, "/usr/local/share/fonts")
		table.insert(paths, os.getenv("HOME") .. "/.fonts")
		table.insert(paths, os.getenv("HOME") .. "/.local/share/fonts")
		-- NixOS support
		table.insert(paths, "/run/current-system/sw/share/X11/fonts")
		table.insert(paths, "/run/current-system/sw/share/fonts")
		table.insert(paths, os.getenv("HOME") .. "/.nix-profile/share/fonts")
	end

	local found_fonts = {}
	local scanned = {}

	local function scan(dir)
		if not fs.is_directory(dir) then return end

		if scanned[dir] then return end

		scanned[dir] = true
		local files = fs.get_files(dir)

		if not files then return end

		for _, file in ipairs(files) do
			if file ~= "." and file ~= ".." then
				local full_path = dir .. "/" .. file

				if fs.is_directory(full_path) then
					scan(full_path)
				else
					local ext = file:match("%.([^%.]+)$")

					if ext then
						ext = ext:lower()

						if ext == "ttf" or ext == "otf" then
							table.insert(found_fonts, full_path)
						end
					end
				end
			end
		end
	end

	for _, path in ipairs(paths) do
		scan(path)
	end

	return found_fonts
end

function fonts.GetSystemDefaultFont()
	if WINDOWS then
		return os.getenv("WINDIR") .. "/Fonts/arial.ttf"
	elseif OSX then
		return "/Library/Fonts/Arial.ttf"
	elseif LINUX then
		-- Try fc-match first (most reliable on Linux)
		local handle = io.popen("fc-match -f '%{file}'")

		if handle then
			local path = handle:read("*a")
			handle:close()

			if path and path ~= "" and fs.exists(path) then return path end
		end

		local home = os.getenv("HOME")
		local font_name = nil

		-- Try GTK 3/4
		if not font_name then
			local path = home .. "/.config/gtk-3.0/settings.ini"

			if not fs.exists(path) then path = home .. "/.config/gtk-4.0/settings.ini" end

			if fs.exists(path) then
				local content = fs.read_file(path)
				font_name = content:match("gtk%-font%-name=([^%s\n]+)")
			end
		end

		-- Try GTK 2
		if not font_name then
			local path = home .. "/.gtkrc-2.0"

			if fs.exists(path) then
				local content = fs.read_file(path)
				font_name = content:match("gtk%-font%-name=\"([^\"]+)\"")
			end
		end

		-- Try KDE (Plasma)
		if not font_name then
			local path = home .. "/.config/kdeglobals"

			if fs.exists(path) then
				local content = fs.read_file(path)
				-- General font entry format: font=Noto Sans,10,-1,5,50,0,0,0,0,0
				local font_line = content:match("font=([^,\n]+)")

				if font_line then font_name = font_line end
			end
		end

		if font_name then
			-- Strip size if present (e.g. "Noto Sans 10")
			font_name = font_name:gsub("%s+%d+$", "")
			local clean_name = font_name:lower():gsub("[%s%-_]", "")
			local list = fonts.GetSystemFonts()

			for _, path in ipairs(list) do
				local file_name = path:match("([^/]+)$"):lower():gsub("[%s%-_]", "")

				-- Prefer Regular fonts
				if
					file_name:find(clean_name) and
					(
						file_name:find("regular") or
						not file_name:find("bold")
					)
				then
					return path
				end
			end
		end

		local candidates = {
			"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
			"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
			"/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
			"/usr/share/fonts/noto/NotoSans-Regular.ttf",
			"/usr/share/fonts/TTF/DejaVuSans.ttf",
		}

		for _, path in ipairs(candidates) do
			if fs.is_file(path) then return path end
		end

		local list = fonts.GetSystemFonts()

		for _, path in ipairs(list) do
			if path:lower():find("arial") or path:lower():find("sans") then
				return path
			end
		end
	end
end

return fonts
