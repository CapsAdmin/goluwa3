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

T.Test2D("gfonts hotswap", function()
	local font = fonts.New({Name = "Orbitron", Weight = "Regular", Size = 20})
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
