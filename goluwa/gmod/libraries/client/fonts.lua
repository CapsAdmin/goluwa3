local steam = import("goluwa/steam.lua")
local utf8 = import("goluwa/utf8.lua")
local vfs = import("goluwa/vfs.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local HostColor = import("goluwa/structs/color.lua")

local function ColorNorm(r, g, b, a)
	return HostColor.FromBytes((r or 0) * 255, (g or 0) * 255, (b or 0) * 255, (a or 1) * 255)
end

do
	local easy = {
		["roboto bk"] = "resource/fonts/Roboto-Black.ttf",
		["roboto"] = "resource/fonts/Roboto-Thin.ttf",
		["helvetica"] = "fonts/DejaVuSans.ttf",
		["dejavu sans"] = "fonts/DejaVuSans.ttf",
		["dejavu sans mono"] = "fonts/DejaVuSansMono.ttf",
		["times new roman"] = "fonts/DejaVuSans.ttf",
		["courier new"] = "fonts/DejaVuSansMono.ttf",
		["courier"] = "fonts/DejaVuSansMono.ttf",
		["arial"] = "fonts/DejaVuSans.ttf",
		["arial black"] = "fonts/DejaVuSans.ttf",
		["verdana"] = "fonts/DejaVuSans.ttf",
		["trebuchet ms"] = "fonts/DejaVuSans.ttf",
		["marlett"] = "resource/marlett.ttf",
	}

	function gine.TranslateFontName(name)
		if not name then return easy["dejavu sans"] end

		local name = name:lower()

		if easy[name] then return easy[name] end

		if vfs.IsFile("resource/" .. name .. ".ttf") then
			return "resource/" .. name .. ".ttf"
		end

		if vfs.IsFile("resource/fonts/" .. name .. ".ttf") then
			return "resource/fonts/" .. name .. ".ttf"
		end

		return easy["dejavu sans"]
	end
end

local default_font = {
	font = "Arial",
	extended = false,
	size = 13,
	weight = 500,
	blursize = 0,
	scanlines = 0,
	antialias = true,
	underline = false,
	italic = false,
	strikeout = false,
	symbol = false,
	rotary = false,
	shadow = false,
	additive = false,
	outline = false,
}

local function create_font(options)
	local path = options.path or options.Path

	if path == "" or (path and not vfs.IsFile(path)) then path = nil end

	return fonts.New{
		Path = path,
		Name = options.name or options.Name,
		Size = options.size or options.Size,
		Weight = options.weight or options.Weight,
		Padding = options.padding or options.Padding,
		Spread = options.spread or options.Spread,
		Mode = options.mode or options.Mode,
	}
end

function gine.LoadFonts()
	local screen_res = system.GetCurrentWindow():GetSize()
	local found = {}
	--table.merge(found, steam.VDFToTable(vfs.Read("resource/SourceScheme.res"), true).scheme.fonts)
	--table.merge(found, steam.VDFToTable(vfs.Read("resource/ChatScheme.res"), true).scheme.fonts)
	table.merge(
		found,
		steam.VDFToTable(vfs.Read("resource/ClientScheme.res"), true).scheme.fonts
	)

	for font_name, sub_fonts in pairs(found) do
		local candidates = {}

		for i, info in pairs(sub_fonts) do
			if info.yres then
				local x, y = unpack(info.yres:split(" "))
				list.insert(
					candidates,
					{info = info, dist = Vec2(tonumber(x), tonumber(y)):Distance(screen_res)}
				)
			end
		end

		list.sort(candidates, function(a, b)
			return a.dist < b.dist
		end)

		local info = (candidates[1] and candidates[1].info) or select(2, next(sub_fonts))

		if info then
			if type(info.tall) == "table" then info.tall = info.tall[1] -- what
			end

			gine.render2d_fonts[font_name:lower()] = create_font{
				path = gine.TranslateFontName(info.name),
				size = info.tall or default_font.size,
			}
		end
	end
end

do
	gine.translation = {}
	gine.translation2 = {}

	function gine.env.language.GetPhrase(key)
		return gine.translation[key] or key
	end

	function gine.env.language.Add(key, val)
		gine.translation[key] = val:trim()
		gine.translation2["#" .. key] = gine.translation[key]
	end
end

do
	local surface = gine.env.surface
	local current_font
	local text_pos = Vec2(0, 0)

	function surface.SetTextPos(x, y)
		text_pos = Vec2(x or 0, y or 0)
	end

	gine.render2d_fonts = gine.render2d_fonts or {}

	function surface.CreateFont(id, tbl)
		tbl = table.copy(tbl)
		local reload_args = {id, tbl}

		for k, v in pairs(default_font) do
			if tbl[k] == nil then tbl[k] = v end
		end

		local options = {}
		options.path = gine.TranslateFontName(tbl.font)
		--logn("[", id, "] ", tbl.font, " >> ", options.path)
		options.size = math.round(tbl.size / 1.25)

		-- hmm
		if options.path:lower():find("mono") then
			options.monospace = true
			options.spacing = options.size / 2
			options.tab_width_multiplier = 1
		--logn("forcing mono: ", options.size / 2)
		end

		if tbl.shadow then options.shadow = 2 end

		if tbl.blursize ~= 0 then
			options.padding = 100
			options.shadow = {
				dir = 0,
				color = ColorNorm(1, 1, 1, 1),
				blur_radius = tbl.blursize / 2,
				blur_passes = 2,
			}
		end

		options.filtering = "nearest"
		local font = create_font(options)
		font.reload_args = reload_args
		gine.render2d_fonts[id:lower()] = font
	end

	function surface.SetFont(name)
		current_font = gine.render2d_fonts[name:lower()]
	end

	function surface.GetTextSize(str)
		str = gine.translation2[str] or str

		if not current_font then current_font = gine.render2d_fonts.default end

		if not current_font then return 0, 0 end

		str = tostring(str or "")

		if str == "" then return 0, 0, 0, 0 end

		local line_height = current_font.GetLineHeight and
			current_font:GetLineHeight() or
			select(2, current_font:GetTextSize("|")) or
			0
		local spacing = rawget(current_font, "Spacing") or 0
		local cursor_x = 0
		local cursor_y = 0
		local max_advance_x = 0
		local min_x = math.huge
		local min_y = math.huge
		local max_x = -math.huge
		local max_y = -math.huge
		local saw_visible_glyph = false
		local metric_font = current_font

		if current_font.Fonts and current_font.Fonts[1] and current_font.Fonts[1].GetGlyph then
			metric_font = current_font.Fonts[1]

			if metric_font.SetSize and current_font.GetSize then
				metric_font:SetSize(current_font:GetSize())
			end
		end

		for _, char in ipairs(utf8.to_list(str)) do
			if char == "\n" then
				max_advance_x = math.max(max_advance_x, cursor_x)
				cursor_x = 0
				cursor_y = cursor_y + line_height + spacing
			elseif char == "\t" then
				if current_font.GetTabAdvance then
					cursor_x = cursor_x + current_font:GetTabAdvance(nil, 4, cursor_x)
				else
					cursor_x = cursor_x + ((current_font.GetSpaceAdvance and current_font:GetSpaceAdvance()) or 0) * 4
				end
			elseif char == " " then
				cursor_x = cursor_x + ((current_font.GetSpaceAdvance and current_font:GetSpaceAdvance()) or 0)
			else
				local glyph = metric_font.GetGlyph and metric_font:GetGlyph(char)

				if glyph then
					local glyph_left = cursor_x + (glyph.bitmap_left or 0)
					local glyph_top = cursor_y + (glyph.bitmap_top or 0)
					local glyph_right = glyph_left + (glyph.w or glyph.x_advance or 0)
					local glyph_bottom = glyph_top + (glyph.h or line_height)
					min_x = math.min(min_x, glyph_left)
					min_y = math.min(min_y, glyph_top)
					max_x = math.max(max_x, glyph_right)
					max_y = math.max(max_y, glyph_bottom)
					saw_visible_glyph = true
					cursor_x = cursor_x + (glyph.x_advance or 0) + spacing
				else
					cursor_x = cursor_x + (current_font.GetGlyphAdvance and current_font:GetGlyphAdvance(char) or 0)
				end
			end
		end

		max_advance_x = math.max(max_advance_x, cursor_x)

		if not saw_visible_glyph then return max_advance_x, line_height, 0, 0 end

		max_x = math.max(max_x, max_advance_x)
		return max_x - min_x, max_y - min_y, min_x, min_y
	end

	local txt_r, txt_g, txt_b, txt_a = 0, 0, 0, 0

	function surface.SetTextColor(r, g, b, a)
		if type(r) == "table" then r, g, b, a = r.r, r.g, r.b, r.a end

		txt_r = r / 255
		txt_g = g / 255
		txt_b = b / 255
		txt_a = (a or 255) / 255
	end

	function surface.DrawText(str)
		str = gine.translation2[str] or str

		if not current_font then current_font = gine.render2d_fonts.default end

		if not current_font then return end

		local _, _, min_x, min_y = surface.GetTextSize(str)
		render2d.PushColor(txt_r, txt_g, txt_b, txt_a)
		current_font:DrawText(str, text_pos.x - min_x, text_pos.y - min_y)
		render2d.PopColor()
		local w = select(1, surface.GetTextSize(str))
		text_pos = Vec2(text_pos.x + w, text_pos.y)
	end

	if RELOAD then
		for k, v in pairs(gine.render2d_fonts) do
			if v.reload_args then surface.CreateFont(unpack(v.reload_args)) end
		end
	end
end
