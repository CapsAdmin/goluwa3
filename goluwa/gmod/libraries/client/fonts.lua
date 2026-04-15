local steam = import("goluwa/steam.lua")
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

	return fonts.New(
		{
			Path = path,
			Name = options.name or options.Name,
			Size = options.size or options.Size,
			Weight = options.weight or options.Weight,
			Padding = options.padding or options.Padding,
			Spread = options.spread or options.Spread,
			Mode = options.mode or options.Mode,
		}
	)
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

			gine.render2d_fonts[font_name:lower()] = create_font(
				{
					path = gine.TranslateFontName(info.name),
					size = info.tall or default_font.size,
				}
			)
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
		return current_font:GetTextSize(str)
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
		render2d.PushColor(txt_r, txt_g, txt_b, txt_a)
		current_font:DrawText(str, text_pos.x, text_pos.y)
		render2d.PopColor()
		local w = select(1, current_font:GetTextSize(str))
		text_pos = Vec2(text_pos.x + w, text_pos.y)
	end

	if RELOAD then
		for k, v in pairs(gine.render2d_fonts) do
			if v.reload_args then surface.CreateFont(unpack(v.reload_args)) end
		end
	end
end