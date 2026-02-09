local fs = require("fs")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local ttf_font = require("render2d.fonts.ttf")
local base_font = require("render2d.fonts.base")
local rasterized_font = require("render2d.fonts.rasterized_font")
local fonts = library()
-- Font management
local current_font = nil
local default_font = nil
local X, Y = 0, 0
local loaded_fonts = {}

function fonts.LoadFont(path, size, padding)
	size = size or 16
	padding = padding or 0
	local key = tostring(path) .. "_" .. tostring(size) .. "_" .. tostring(padding)

	if loaded_fonts[key] then return loaded_fonts[key] end

	local ext = tostring(path):match("%.([^%.]+)$")

	if ext == "ttf" or ext == "otf" then
		local font = ttf_font.New(path)
		font:SetSize(size)
		-- Wrap in rasterized_font for texture atlas support
		local res = rasterized_font.New(font, padding)
		loaded_fonts[key] = res
		return res
	elseif path == "default" then
		return fonts.GetDefaultFont()
	end

	-- Check if it's already a font object
	if type(path) == "table" and path.IsFont then return path end

	error("Unsupported font format: " .. tostring(ext or path))
end

local function add_blur_stage(stages, blur_radius, blur_dir)
	table.insert(
		stages,
		{
			source = [[
		vec4 sum = vec4(0.0);
		vec2 blur = vec2(radius)/size;
		float hstep = dir.x;
		float vstep = dir.y;

		sum += texture(self, vec2(uv.x - 4.0*blur.x*hstep, uv.y - 4.0*blur.y*vstep)) * 0.0162162162;
		sum += texture(self, vec2(uv.x - 3.0*blur.x*hstep, uv.y - 3.0*blur.y*vstep)) * 0.0540540541;
		sum += texture(self, vec2(uv.x - 2.0*blur.x*hstep, uv.y - 2.0*blur.y*vstep)) * 0.1216216216;
		sum += texture(self, vec2(uv.x - 1.0*blur.x*hstep, uv.y - 1.0*blur.y*vstep)) * 0.1945945946;

		sum += texture(self, vec2(uv.x, uv.y)) * 0.2270270270;

		sum += texture(self, vec2(uv.x + 1.0*blur.x*hstep, uv.y + 1.0*blur.y*vstep)) * 0.1945945946;
		sum += texture(self, vec2(uv.x + 2.0*blur.x*hstep, uv.y + 2.0*blur.y*vstep)) * 0.1216216216;
		sum += texture(self, vec2(uv.x + 3.0*blur.x*hstep, uv.y + 3.0*blur.y*vstep)) * 0.0540540541;
		sum += texture(self, vec2(uv.x + 4.0*blur.x*hstep, uv.y + 4.0*blur.y*vstep)) * 0.0162162162;

		return sum;
		]],
			vars = {
				radius = blur_radius,
				dir = blur_dir,
			},
		}
	)
end

local effects = {}
effects.shadow = function(info, options)
	local dir = info.dir or options.size / 2
	local color = info.color or Color(0, 0, 0, 0.25)
	local blur_radius = info.blur_radius

	if type(dir) == "number" then
		dir = Vec2(-dir, dir)
	elseif typex(dir) == "vec2" then
		dir = Vec2(-dir.x, dir.y)
	end

	local stages = {}
	table.insert(stages, {copy = true})
	local passes = info.dir_passes or 1

	for i = 1, passes do
		local m = (i / passes)
		table.insert(
			stages,
			{
				source = "return vec4(color.r, color.g, color.b, texture(copy, uv - (dir / size)).a * color.a);",
				vars = {
					dir = dir * m,
					color = i == 1 and
						color or
						Color(color.r, color.g, color.b, (color.a * -m + 1) ^ (info.dir_falloff or 1)),
				},
				blend_mode = i == 1 and "none" or "alpha",
			}
		)
	end

	if blur_radius then
		local times = info.blur_passes or 1

		for i = 1, times do
			local m = i / times
			add_blur_stage(stages, blur_radius, Vec2(0, 1) * m)
			add_blur_stage(stages, blur_radius, Vec2(1, 0) * m)
		end
	end

	if info.alpha_pow then
		table.insert(
			stages,
			{
				source = "return vec4(texture(self, uv).rgb, pow(texture(self, uv).a, alpha_pow));",
				vars = {
					alpha_pow = info.alpha_pow,
				},
			}
		)
	end

	table.insert(
		stages,
		{
			source = "return texture(self, uv) * vec4(1,1,1,color.a);",
			vars = {
				color = color,
			},
		}
	)
	table.insert(
		stages,
		{
			source = "return texture(copy, uv) + texture(self, uv) * (1.0 - texture(copy, uv).a);", -- simple alpha blend
			vars = {},
			blend_mode = "alpha",
		}
	)
	return stages
end
effects.gradient = function(info, options)
	return {
		source = "return vec4(texture(gradient_texture, uv).rgb, texture(self, uv).a);",
		vars = {
			gradient_texture = info.texture,
		},
	}
end
effects.color = function(info, options)
	return {
		source = "return texture(self, uv) * color;",
		vars = {
			color = info.color,
		},
	}
end

function fonts.CreateFont(options)
	options = options or {}
	local path = options.path or fonts.GetSystemDefaultFont()
	local size = options.size or 14
	-- Calculate padding needed for effects BEFORE loading the font
	local padding = options.padding or 0

	-- If we have shadow or other effects, calculate required padding
	if options.shadow then
		local shadow_info = options.shadow
		local dir = shadow_info.dir or (size / 2)

		if type(dir) == "number" then
			dir = math.abs(dir)
		else
			dir = math.max(math.abs(dir.x or 0), math.abs(dir.y or 0))
		end

		local blur_radius = shadow_info.blur_radius or 0
		local blur_extend = blur_radius * 4 * (shadow_info.blur_passes or 1)
		local required_padding = math.ceil(dir + blur_extend)
		padding = math.max(padding, required_padding)
	end

	local font = fonts.LoadFont(path, size, padding)

	if padding > 0 then font:SetPadding(padding) end

	if options.separate_effects then font:SetSeparateEffects(true) end

	local shading_info = {}
	local sorted = {}

	for name, callback in pairs(effects) do
		if options[name] then
			options[name].order = options[name].order or 0
			table.insert(sorted, {info = options[name], callback = callback})
		end
	end

	if options.effects then
		for _, effect in ipairs(options.effects) do
			local callback = effects[effect.type]

			if callback then
				effect.order = effect.order or 0
				table.insert(sorted, {info = effect, callback = callback})
			end
		end
	end

	table.sort(sorted, function(a, b)
		return a.info.order > b.info.order
	end)

	for _, data in ipairs(sorted) do
		local stages = data.callback(data.info, options)

		if stages.source then stages = {stages} end

		for _, stage in ipairs(stages) do
			table.insert(shading_info, stage)
		end
	end

	if #shading_info > 0 then
		font:SetShadingInfo(shading_info)
		font:Rebuild()
	end

	return font
end

function fonts.GetDefaultFont()
	if not default_font then
		print("creating defauilt font")
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

function fonts.FindFontPath(name)
	for _, path in ipairs(fonts.GetSystemFonts()) do
		if path:lower():find(name:lower()) then return path end
	end
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
