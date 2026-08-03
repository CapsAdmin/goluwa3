-- Showcase various SDF font sizes from tiny to massive, SDF parameter tweaking,
-- and primitive SDF shapes.
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local fontPath = fonts.GetDefaultSystemFontPath()
-- Font sizes from very small to very large
local font_tiny8 = fonts.New{Path = fontPath, Size = 8}
local font_tiny12 = fonts.New{Path = fontPath, Size = 12}
local font_small16 = fonts.New{Path = fontPath, Size = 16}
local font_small24 = fonts.New{Path = fontPath, Size = 24}
local font_medium36 = fonts.New{Path = fontPath, Size = 36}
local font_large48 = fonts.New{Path = fontPath, Size = 48}
local font_large72 = fonts.New{Path = fontPath, Size = 72}
local font_huge128 = fonts.New{Path = fontPath, Size = 128}
local font_huge256 = fonts.New{Path = fontPath, Size = 256}
local font_massive512 = fonts.New{Path = fontPath, Size = 512}
local sampleText = "The quick brown fox jumps over the lazy dog"
local shortText = "AaBbCc 123"

local function drawSectionTitle(title, x, y)
	render2d.SetColor(0.8, 0.8, 0.8, 1)
	font_small24:DrawText(title, x, y)
	render2d.SetColor(0.3, 0.3, 0.3, 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(x, y + 30, 400, 1)
end

local function drawSizeLabel(size, x, y)
	render2d.SetColor(1, 1, 1, 1)
	font_small16:DrawText(size .. "px", x, y)
end

event.AddListener("Draw2D", "sdf_font_sizes", function()
	local time = system.GetTime()
	local win_w, win_h = system.GetWindow():GetSize():Unpack()
	-- Background
	render2d.SetColor(0.08, 0.08, 0.1, 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(0, 0, win_w, win_h)
	local x = 40
	local y = 40
	-- ============================================================
	-- SECTION 1: Font size progression (tiny to massive)
	-- ============================================================
	drawSectionTitle("Font Size Progression", x, y)
	y = y + 45
	-- 8px - tiny, barely readable
	render2d.SetColor(1, 1, 1, 1)
	drawSizeLabel("8", x, y)
	font_tiny8:DrawText(sampleText, x + 50, y + 2)
	y = y + 25
	-- 12px
	drawSizeLabel("12", x, y)
	font_tiny12:DrawText(sampleText, x + 50, y + 2)
	y = y + 30
	-- 16px
	drawSizeLabel("16", x, y)
	font_small16:DrawText(sampleText, x + 50, y + 2)
	y = y + 35
	-- 24px
	drawSizeLabel("24", x, y)
	font_small24:DrawText(sampleText, x + 50, y + 2)
	y = y + 45
	-- 36px
	drawSizeLabel("36", x, y)
	font_medium36:DrawText(sampleText, x + 50, y + 2)
	y = y + 60
	-- 48px
	drawSizeLabel("48", x, y)
	font_large48:DrawText(sampleText, x + 50, y + 2)
	y = y + 75
	-- 72px
	drawSizeLabel("72", x, y)
	font_large72:DrawText(shortText, x + 50, y + 2)
	y = y + 100
	-- 128px - huge
	drawSizeLabel("128", x, y)
	font_huge128:DrawText(shortText, x + 50, y + 2)
	y = y + 170
	-- 256px - massive
	drawSizeLabel("256", x, y)
	font_huge256:DrawText("Aa", x + 50, y + 2)
	y = y + 320
	-- 512px - enormous
	drawSizeLabel("512", x, y)
	font_massive512:DrawText("A", x + 50, y + 2)
	y = y + 550
	-- ============================================================
	-- SECTION 2: SDF parameter tweaking
	-- ============================================================
	x = 40
	y = y + 40
	drawSectionTitle("SDF Parameter Tweaking", x, y)
	y = y + 45
	-- SDF threshold (thickness) comparison
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("SDF Threshold (thickness):", x, y)
	y = y + 25
	local thresholds = {0.3, 0.4, 0.5, 0.6, 0.7}

	for i, thresh in ipairs(thresholds) do
		render2d.PushBlur(1)
		render2d.PushSDFThreshold(thresh)
		render2d.SetColor(1, 1, 1, 1)
		font_large48:DrawText("SDF", x + (i - 1) * 100, y)
		render2d.PopSDFThreshold()
		render2d.PopBlur()
		render2d.SetColor(0.5, 0.5, 0.5, 1)
		font_tiny12:DrawText(string.format("%.1f", thresh), x + (i - 1) * 100 + 10, y + 15)
	end

	y = y + 70
	-- SDF softness comparison
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("SDF Softness (blur):", x, y)
	y = y + 25
	local softnesses = {0, 1, 3, 6, 12}

	for i, soft in ipairs(softnesses) do
		render2d.PushBlur(soft)
		render2d.PushSDFThreshold(0.5)
		render2d.SetColor(1, 1, 1, 1)
		font_large48:DrawText("SDF", x + (i - 1) * 100, y)
		render2d.PopSDFThreshold()
		render2d.PopBlur()
		render2d.SetColor(0.5, 0.5, 0.5, 1)
		font_tiny12:DrawText(tostring(soft), x + (i - 1) * 100 + 20, y + 15)
	end

	y = y + 70
	-- SDF gamma comparison
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("SDF Gamma:", x, y)
	y = y + 25
	local gammas = {0.5, 1.0, 1.5, 2.0, 3.0}

	for i, gamma in ipairs(gammas) do
		render2d.PushBlur(1)
		render2d.PushSDFThreshold(0.5)
		render2d.PushSDFGamma(gamma)
		render2d.SetColor(1, 1, 1, 1)
		font_large48:DrawText("SDF", x + (i - 1) * 100, y)
		render2d.PopSDFGamma()
		render2d.PopSDFThreshold()
		render2d.PopBlur()
		render2d.SetColor(0.5, 0.5, 0.5, 1)
		font_tiny12:DrawText(string.format("%.1f", gamma), x + (i - 1) * 100 + 10, y + 15)
	end

	y = y + 70
	-- SDF bias comparison
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("SDF Bias:", x, y)
	y = y + 25
	local biases = {-0.3, -0.15, 0.0, 0.15, 0.3}

	for i, bias in ipairs(biases) do
		render2d.PushBlur(1)
		render2d.PushSDFThreshold(0.5)
		render2d.PushSDFBias(bias)
		render2d.SetColor(1, 1, 1, 1)
		font_large48:DrawText("SDF", x + (i - 1) * 100, y)
		render2d.PopSDFBias()
		render2d.PopSDFThreshold()
		render2d.PopBlur()
		render2d.SetColor(0.5, 0.5, 0.5, 1)
		font_tiny12:DrawText(string.format("%.2f", bias), x + (i - 1) * 100 + 10, y + 15)
	end

	y = y + 70
	-- Combined effects with animation
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("Animated SDF (threshold + softness + gamma):", x, y)
	y = y + 25
	local pulse = math.sin(time * 2) * 0.5
	render2d.PushBlur(2 + pulse * 4)
	render2d.PushSDFThreshold(0.5 + pulse * 0.15)
	render2d.PushSDFGamma(1.0 + pulse * 0.5)
	render2d.PushColor(0.5 + pulse * 0.5, 0.5 - pulse * 0.2, 1, 1)
	font_huge128:DrawText("SDF", x, y)
	render2d.PopColor()
	render2d.PopSDFGamma()
	render2d.PopSDFThreshold()
	render2d.PopBlur()
	y = y + 170
	-- ============================================================
	-- SECTION 3: Primitive SDF shapes
	-- ============================================================
	drawSectionTitle("Primitive SDF Shapes", x, y)
	y = y + 45
	-- Filled circles at various sizes with SDF
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("Filled Circles (SDF-enabled):", x, y)
	y = y + 25
	local circleSizes = {5, 10, 20, 40, 80}

	for i, radius in ipairs(circleSizes) do
		render2d.PushBlur(2)
		render2d.SetColor(1, 0.4, 0.2, 1)
		render2d.DrawFilledCircle(x + radius + (i - 1) * (circleSizes[i] * 2 + 20), y, radius)
		render2d.PopBlur()
	end

	y = y + 100
	-- Outlined circles
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("Outlined Circles:", x, y)
	y = y + 25

	for i, radius in ipairs(circleSizes) do
		render2d.PushBlur(1)
		render2d.SetColor(0.2, 0.6, 1, 1)
		render2d.DrawCircle(x + radius + (i - 1) * (circleSizes[i] * 2 + 20), y, radius, 2)
		render2d.PopBlur()
	end

	y = y + 100
	-- Rectangles with border radius (SDF rounded rects)
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("Rounded Rectangles (SDF border radius):", x, y)
	y = y + 25
	local radii = {0, 5, 15, 30, 50}

	for i, r in ipairs(radii) do
		render2d.PushBlur(2)
		render2d.SetBorderRadius(r, r, r, r)
		render2d.SetColor(0.3, 1, 0.4, 1)
		render2d.DrawRect(x + (i - 1) * 80, y, 60, 40)
		render2d.PopBlur()
	end

	y = y + 55
	-- Rectangles with outline
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("Rectangles with Outline (SDF):", x, y)
	y = y + 25
	local outlineWidths = {1, 2, 4, 8, 12}

	for i, ow in ipairs(outlineWidths) do
		render2d.PushBlur(2)
		render2d.SetBorderRadius(5, 5, 5, 5)
		render2d.SetOutlineWidth(ow)
		render2d.SetColor(1, 0.8, 0, 1)
		render2d.DrawRect(x + (i - 1) * 80, y, 60, 40)
		render2d.PopBlur()
	end

	y = y + 55
	-- Lines with varying thickness
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("Lines (varying thickness):", x, y)
	y = y + 25
	local lineThicknesses = {1, 2, 4, 8, 16}

	for i, thickness in ipairs(lineThicknesses) do
		render2d.PushBlur(1)
		render2d.SetColor(1, 0.3, 0.8, 1)
		render2d.DrawLine(x, y + (i - 1) * 20, x + 200, y + (i - 1) * 20, thickness)
		render2d.PopBlur()
	end

	y = y + 110
	-- ============================================================
	-- SECTION 4: Extreme size SDF comparison
	-- ============================================================
	drawSectionTitle("Same SDF, Different Render Sizes", x, y)
	y = y + 45
	render2d.SetColor(0.6, 0.6, 0.6, 1)
	font_small16:DrawText("Font size 128 rendered at different scales:", x, y)
	y = y + 25
	local scales = {0.25, 0.5, 1.0, 2.0, 4.0}

	for i, scale in ipairs(scales) do
		render2d.PushBlur(1)
		render2d.PushSDFThreshold(0.5)
		render2d.SetColor(1, 1, 1, 1)
		render2d.PushMatrix()
		render2d.Translate(x + (i - 1) * 150, y)
		render2d.Scale(scale, scale)
		font_huge128:DrawText("Aa", 0, 0)
		render2d.PopMatrix()
		render2d.PopSDFThreshold()
		render2d.PopBlur()
		render2d.SetColor(0.5, 0.5, 0.5, 1)
		font_tiny12:DrawText(string.format("%.1fx", scale), x + (i - 1) * 150 + 30, y + 15)
	end
end)
