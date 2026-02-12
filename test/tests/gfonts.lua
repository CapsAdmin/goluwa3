local T = require("test.environment")
local gfonts = require("gfonts")
local fonts = require("render2d.fonts")
local tasks = require("tasks")

T.Test("gfonts download Orbitron", function()
	local promise = gfonts.Download({name = "Orbitron", weight = "Regular"})
	local path, changed = promise:Get()
	T(type(path))["=="]("string")
	T(path:find(".ttf", 1, true))["~="](nil)
end)

T.Test("gfonts download invalid font", function()
	local promise = gfonts.Download({name = "ThisFontDoesNotExistProbably12345", weight = "Regular"})
	local ok, err = pcall(function()
		promise:Get()
	end)
	T(ok)["=="](false)
	T(err:find("Failed to fetch CSS", 1, true))["~="](nil)
end)

T.Test("fonts.LoadGoogleFont hotswap", function()
	local font = fonts.LoadGoogleFont("Orbitron", "Regular", {size = 20})
	T(font.IsFont)["=="](true)
	local initial_ttf = font:GetFonts()[1]
	T(initial_ttf)["~="](nil)
	-- Wait for the font to be swapped (should happen in background)
	local timeout = os.clock() + 5

	while font:GetFonts()[1] == initial_ttf and os.clock() < timeout do
		tasks.Wait()
	end

	local new_ttf = font:GetFonts()[1]
	T(new_ttf)["~="](initial_ttf)
	T(new_ttf:GetSize())["=="](20)
end)

T.Test("fonts.LoadGoogleFont independent objects", function()
	-- Two DIFFERENT google fonts with the SAME size.
	-- Without the 'unique' fix, they would share the same system default font object
	-- and hotswap each other.
	local font1 = fonts.LoadGoogleFont("Orbitron", "Regular", {size = 14})
	local font2 = fonts.LoadGoogleFont("Rajdhani", "Regular", {size = 14})
	T(font1)["~="](font2)
	-- Wait for both to download
	local timeout = os.clock() + 5

	while os.clock() < timeout do
		local f1 = font1:GetFonts()[1]
		local f2 = font2:GetFonts()[1]
		local p1 = f1 and f1.GetPath and f1:GetPath()
		local p2 = f2 and f2.GetPath and f2:GetPath()

		if p1 and p2 and p1 ~= p2 and p1:find("url", 1, true) and p2:find("url", 1, true) then
			break
		end

		tasks.Wait()
	end

	local f1 = font1:GetFonts()[1]
	local f2 = font2:GetFonts()[1]
	local p1 = f1:GetPath()
	local p2 = f2:GetPath()
	T(type(p1))["=="]("string")
	T(type(p2))["=="]("string")
	T(p1)["~="](p2)
	T(font1)["~="](font2)
end)
