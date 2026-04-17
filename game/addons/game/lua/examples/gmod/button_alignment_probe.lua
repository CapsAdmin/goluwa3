if IsValid(GoluwaButtonAlignmentProbe) then
	GoluwaButtonAlignmentProbe:Remove()
end

local function fill_rect(x, y, w, h, color)
	surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
	surface.DrawRect(x, y, w, h)
end

local function outline_rect(x, y, w, h, color)
	surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
	surface.DrawOutlinedRect(math.floor(x), math.floor(y), math.max(math.floor(w), 0), math.max(math.floor(h), 0))
end

local function get_xy(value)
	if not value then return 0, 0 end

	return value.x or 0, value.y or 0
end

local function get_wrapper_debug(panel)
	local panel_obj = rawget(panel, "__obj") or panel
	local text_offset = rawget(panel_obj, "text_offset")
	local text_inset = rawget(panel_obj, "text_inset")
	local offset_x, offset_y = get_xy(text_offset)
	local inset_x, inset_y = get_xy(text_inset)
	local layout_w, layout_h = panel:GetTextSize()
	local content_w, content_h = panel:GetContentSize()
	local text = panel.GetText and panel:GetText() or ""
	local draw_w, draw_h, min_x, min_y = gine.GetSurfaceTextBounds(text)
	return {
		offset_x = offset_x,
		offset_y = offset_y,
		inset_x = inset_x,
		inset_y = inset_y,
		layout_w = layout_w,
		layout_h = layout_h,
		content_w = content_w,
		content_h = content_h,
		draw_w = draw_w,
		draw_h = draw_h,
		min_x = min_x,
		min_y = min_y,
	}
end

local alignments = {
	{num = 7, name = "7 top-left"},
	{num = 8, name = "8 top-center"},
	{num = 9, name = "9 top-right"},
	{num = 4, name = "4 center-left"},
	{num = 5, name = "5 center"},
	{num = 6, name = "6 center-right"},
	{num = 1, name = "1 bottom-left"},
	{num = 2, name = "2 bottom-center"},
	{num = 3, name = "3 bottom-right"},
}
local frame = vgui.Create("DFrame")
GoluwaButtonAlignmentProbe = frame
frame:SetTitle("Button Alignment Probe")
frame:SetSize(1220, 860)
frame:Center()
frame:MakePopup()
local body = vgui.Create("DPanel", frame)
body:Dock(FILL)
body:DockPadding(12, 12, 12, 12)

function body:Paint(w, h)
	fill_rect(0, 0, w, h, Color(24, 26, 31))
	outline_rect(0, 0, w, h, Color(56, 62, 72))
	fill_rect(10, 10, w - 20, 58, Color(31, 35, 42))
	outline_rect(10, 10, w - 20, 58, Color(66, 74, 86))
	draw.SimpleText(
		"Each button shows: blue = panel bounds, yellow = content box, red = layout box, green = actual rendered glyph bounds.",
		"DermaDefaultBold",
		20,
		24,
		Color(255, 255, 255),
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_TOP
	)
	draw.SimpleText(
		"If text placement looks correct, but red looked wrong before, that was the probe mixing layout metrics with draw bounds.",
		"DermaDefault",
		20,
		44,
		Color(205, 210, 220),
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_TOP
	)
end

local grid = vgui.Create("DIconLayout", body)
grid:Dock(FILL)
grid:DockMargin(0, 68, 0, 0)
grid:SetSpaceX(14)
grid:SetSpaceY(14)
grid:SetBorder(0)

for _, info in ipairs(alignments) do
	local card = grid:Add("DPanel")
	card:SetSize(380, 225)

	function card:Paint(w, h)
		fill_rect(0, 0, w, h, Color(30, 34, 41))
		outline_rect(0, 0, w, h, Color(66, 74, 86))
	end

	local button = vgui.Create("DButton", card)
	button:SetPos(18, 38)
	button:SetSize(344, 154)
	button:SetFont("DermaDefault")
	button:SetText("AgjpQy 0123")
	button:SetContentAlignment(info.num)
	button:SetTextInset(0, 0)
	button:SetDrawBorder(true)
	local caption = vgui.Create("DLabel", card)
	caption:SetPos(18, 198)
	caption:SetSize(344, 18)
	caption:SetText("TextInset(18, 14) applied to all buttons")
	caption:SetTextColor(Color(210, 214, 222))
	caption:SetContentAlignment(5)
	caption:SetMouseInputEnabled(false)
end

frame:InvalidateLayout(true)
