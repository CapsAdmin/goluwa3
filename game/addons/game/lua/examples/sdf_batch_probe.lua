local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local font_path = fonts.GetDefaultSystemFontPath()
local label_font = fonts.New{Path = font_path, Size = 14}
local sizes = {8, 10, 12, 14, 18, 24, 36, 64}
local rows = {}
local probe_text = "Hamburgefonsiv 0123456789"
local compact_text = "AaEeRr gypq"
local gradient = render2d.CreateGradient{
	mode = "linear",
	stops = {
		{pos = 0, color = Color(0.2, 1, 0.7, 1)},
		{pos = 1, color = Color(0.1, 0.5, 1, 1)},
	},
}

for _, size in ipairs(sizes) do
	rows[#rows + 1] = {
		size = size,
		font = fonts.New{Path = font_path, Size = size, Unique = true},
	}
end

local function prewarm_font(font)
	font:GetTextSize(probe_text)
	font:GetTextSize(compact_text)
	font:GetTextSize("SDF")
	font:GetTextSize("Grad")
end

label_font:GetTextSize("SDF Probe: rect batched path")

for _, row in ipairs(rows) do
	prewarm_font(row.font)
end

local function draw_box(x, y, w, h, r, g, b, a)
	render2d.SetTexture(nil)
	render2d.SetColor(r, g, b, a)
	render2d.DrawRect(x, y, w, h)
end

local function draw_probe_text(font, text, x, y)
	local w, h = font:GetTextSize(text)
	draw_box(x - 4, y - 2, w + 8, h + 4, 1, 0.2, 0.2, 0.12)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText(text, x, y)
	return w, h
end

local function draw_state_row(font, x, y, title)
	label_font:DrawText(title, x, y)
	render2d.PushBlur(1)
	render2d.PushSDFThreshold(0.5)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("SDF", x + 120, y - 6)
	render2d.PopSDFThreshold()
	render2d.PopBlur()
	render2d.PushSDFGradientTexture(gradient)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Grad", x + 220, y - 6)
	render2d.PopSDFGradientTexture()
end

event.AddListener("Draw2D", "sdf_batch_probe", function()
	local win_w, win_h = system.GetWindow():GetSize():Unpack()
	draw_box(0, 0, win_w, win_h, 0.18, 0.18, 0.18, 1)
	local left_x = 40
	local y = 24
	label_font:DrawText("SDF Probe: rect batched path", left_x, y)
	y = y + 54

	for _, row in ipairs(rows) do
		local label = string.format("%2dpx", row.size)
		label_font:DrawText(label, 8, y + 6)
		local w, h = draw_probe_text(row.font, probe_text, left_x, y)
		draw_probe_text(row.font, compact_text, left_x, y + h + 8)
		label_font:DrawText(string.format("w=%d h=%d", w, h), left_x, y + h + 28)
		y = y + h * 2 + 42
	end

	local footer_y = win_h - 70
	draw_state_row(rows[#rows - 1].font, left_x, footer_y, "State variants")
end)
