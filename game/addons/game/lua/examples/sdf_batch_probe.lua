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
	local batched = fonts.New{Path = font_path, Size = size, Unique = true}
	local immediate = fonts.New{Path = font_path, Size = size, Unique = true}
	batched:SetBatchedDraw(true)
	immediate:SetBatchedDraw(false)
	rows[#rows + 1] = {
		size = size,
		batched = batched,
		immediate = immediate,
	}
end

local function prewarm_font(font)
	font:GetTextSize(probe_text)
	font:GetTextSize(compact_text)
	font:GetTextSize("SDF")
	font:GetTextSize("Grad")
end

label_font:GetTextSize("SDF Probe: batched vs immediate")
label_font:GetTextSize("Batched")
label_font:GetTextSize("Immediate")

for _, row in ipairs(rows) do
	prewarm_font(row.batched)
	prewarm_font(row.immediate)
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
	local right_x = math.floor(win_w * 0.5) + 20
	local y = 24
	label_font:DrawText("SDF Probe: batched vs immediate", left_x, y)
	label_font:DrawText("Batched", left_x, y + 24)
	label_font:DrawText("Immediate", right_x, y + 24)
	y = y + 54

	for _, row in ipairs(rows) do
		local label = string.format("%2dpx", row.size)
		label_font:DrawText(label, 8, y + 6)
		local w1, h1 = draw_probe_text(row.batched, probe_text, left_x, y)
		local w2, h2 = draw_probe_text(row.immediate, probe_text, right_x, y)
		draw_probe_text(row.batched, compact_text, left_x, y + h1 + 8)
		draw_probe_text(row.immediate, compact_text, right_x, y + h2 + 8)
		label_font:DrawText(string.format("w=%d h=%d", w1, h1), left_x, y + h1 + 28)
		label_font:DrawText(string.format("w=%d h=%d", w2, h2), right_x, y + h2 + 28)
		y = y + math.max(h1, h2) * 2 + 42
	end

	local footer_y = win_h - 70
	draw_state_row(rows[#rows - 1].batched, left_x, footer_y, "Batched states")
	draw_state_row(rows[#rows - 1].immediate, right_x, footer_y, "Immediate states")
	render2d.SetTexture(nil)
	render2d.SetColor(0.45, 0.45, 0.45, 0.7)
	render2d.DrawRect(math.floor(win_w * 0.5), 0, 1, win_h)
end)
