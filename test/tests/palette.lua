local T = import("test/environment.lua")
local ColorPalette = import("goluwa/palette.lua")

T.Test("color palette infers missing accents and builds on-colors from surface context", function()
	local palette = ColorPalette.New()
	palette:SetShades({
		"#080a0e",
		"#f8fafc",
	})
	palette:SetColors({
		green = "#16a34a",
		blue = "#2563eb",
	})
	palette:SetMap({
		surface = "green_dark",
		card = "white",
		primary = "blue_light",
		secondary = "green_grey",
	})
	palette.AdjustmentOptions = {target_contrast = 4.5}

	local primary = palette:Get("primary")
	local primary_on_surface = palette:Get("primary", "surface")
	local surface = palette:Get("surface")
	local primary_hue = select(1, primary:GetHSV())
	local on_hue = select(1, primary_on_surface:GetHSV())

	T(palette:GetBase("blue_light"):ToHex())["=="](primary:ToHex())
	T(palette:GetBase("green_grey"):ToHex())["=="](palette:Get("secondary"):ToHex())
	T(surface:ToHex())["=="](palette:GetBase("green_dark"):ToHex())
	T(palette:Get("card"):ToHex())["=="](palette:GetBase("white"):ToHex())
	assert(primary_on_surface:GetContrastRatio(surface) >= 4.5)
	assert(primary_on_surface:ToHex() ~= primary:ToHex())
	assert(math.abs(primary_hue - on_hue) < 0.06)
	T(primary_on_surface)["=="](palette:Get("primary", "surface"))
	assert(palette:GetBase("red"))
	assert(palette:GetBase("green"))
	assert(palette:GetBase("purple"))
	assert(palette:GetBase("brown"))
end)