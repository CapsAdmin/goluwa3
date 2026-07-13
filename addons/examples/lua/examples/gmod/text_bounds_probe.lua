if IsValid(GoluwaTextBoundsProbe) then GoluwaTextBoundsProbe:Remove() end

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

local function get_font_metrics(font_name)
	local current_gine = rawget(_G, "gine")
	local registry = current_gine and current_gine.render2d_fonts
	local font = registry and font_name and registry[tostring(font_name):lower()] or nil

	if not font then return 0, 0, 0 end

	local ascent = font.GetAscent and font:GetAscent() or 0
	local descent = font.GetDescent and font:GetDescent() or 0
	local line_height = font.GetLineHeight and font:GetLineHeight() or (ascent + descent)
	return ascent, descent, line_height
end

local function resolve_aligned_x(x, w, text_w, align, inset_x)
	if align == TEXT_ALIGN_CENTER then return x + math.floor((w - text_w) / 2) end

	if align == TEXT_ALIGN_RIGHT then return x + w - inset_x - text_w end

	return x + inset_x
end

local function resolve_aligned_y(y, h, text_h, align, inset_y)
	if align == TEXT_ALIGN_CENTER then return y + math.floor((h - text_h) / 2) end

	if align == TEXT_ALIGN_BOTTOM then return y + h - inset_y - text_h end

	return y + inset_y
end

local function draw_surface_sample(
	label,
	text,
	font,
	box_x,
	box_y,
	box_w,
	box_h,
	align_x,
	align_y,
	inset_x,
	inset_y,
	colors
)
	fill_rect(box_x, box_y, box_w, box_h, colors.background)
	outline_rect(box_x, box_y, box_w, box_h, colors.region)
	surface.SetFont(font)
	local text_w, text_h = surface.GetTextSize(text)
	local text_x = resolve_aligned_x(box_x, box_w, text_w, align_x, inset_x)
	local text_y = resolve_aligned_y(box_y, box_h, text_h, align_y, inset_y)
	outline_rect(text_x, text_y, text_w, text_h, colors.bounds)
	surface.SetDrawColor(colors.origin.r, colors.origin.g, colors.origin.b, colors.origin.a or 255)
	surface.DrawLine(text_x, box_y, text_x, box_y + box_h)
	surface.DrawLine(box_x, text_y, box_x + box_w, text_y)
	surface.SetTextColor(colors.text.r, colors.text.g, colors.text.b, colors.text.a or 255)
	surface.SetTextPos(text_x, text_y)
	surface.DrawText(text)
	draw.SimpleText(
		label,
		"DermaDefaultBold",
		box_x,
		box_y - 6,
		colors.header,
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_BOTTOM
	)
	draw.SimpleText(
		string.format("font=%s  text=%dx%d  inset=(%d,%d)", font, text_w, text_h, inset_x, inset_y),
		"DermaDefault",
		box_x + 6,
		box_y + box_h - 6,
		colors.header,
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_BOTTOM
	)
end

local function install_bounds_overlay(panel, label)
	local old_paint_over = panel.PaintOver
	panel.PaintOver = function(self, w, h)
		local panel_obj = rawget(self, "__obj") or self

		if old_paint_over then old_paint_over(self, w, h) end

		outline_rect(0, 0, w, h, Color(90, 190, 255))

		if self.GetTextSize then
			local offset_x, offset_y = get_xy(rawget(panel_obj, "text_offset"))
			local inset_x, inset_y = get_xy(rawget(panel_obj, "text_inset"))
			local content_alignment = self.GetContentAlignment and self:GetContentAlignment() or -1
			local font_name = self.GetFont and self:GetFont() or "?"
			local ascent, descent, line_height = get_font_metrics(font_name)
			local text_w, text_h = self:GetTextSize()
			local content_w, content_h = 0, 0

			if self.GetContentSize then
				content_w, content_h = self:GetContentSize()
			end

			outline_rect(offset_x, offset_y, text_w, text_h, Color(255, 120, 120))
			outline_rect(offset_x - inset_x, offset_y - inset_y, content_w, content_h, Color(255, 210, 90))
			surface.SetDrawColor(255, 120, 120, 255)
			surface.DrawLine(offset_x, 0, offset_x, h)
			surface.DrawLine(0, offset_y, w, offset_y)
			draw.SimpleText(
				string.format(
					"ofs=(%d,%d) text=(%d,%d) content=(%d,%d) inset=(%d,%d) align=%s font=%s",
					math.floor(offset_x),
					math.floor(offset_y),
					math.floor(text_w),
					math.floor(text_h),
					math.floor(content_w),
					math.floor(content_h),
					math.floor(inset_x),
					math.floor(inset_y),
					tostring(content_alignment),
					tostring(font_name)
				),
				"DermaDefault",
				4,
				16,
				Color(255, 240, 180),
				TEXT_ALIGN_LEFT,
				TEXT_ALIGN_TOP
			)
			draw.SimpleText(
				string.format(
					"fontmetrics ascent=%d descent=%d line=%d",
					math.floor(ascent),
					math.floor(descent),
					math.floor(line_height)
				),
				"DermaDefault",
				4,
				30,
				Color(180, 240, 255),
				TEXT_ALIGN_LEFT,
				TEXT_ALIGN_TOP
			)
		end

		draw.SimpleText(
			label,
			"DermaDefault",
			4,
			h - 3,
			Color(255, 255, 255),
			TEXT_ALIGN_LEFT,
			TEXT_ALIGN_BOTTOM
		)
	end
end

local function make_heading(parent, text)
	local label = vgui.Create("DLabel", parent)
	label:Dock(TOP)
	label:DockMargin(0, 0, 0, 8)
	label:SetTall(18)
	label:SetFont("DermaDefaultBold")
	label:SetText(text)
	label:SetTextColor(Color(240, 240, 240))
	label:SetContentAlignment(4)
	return label
end

local function make_card(parent, height)
	local panel = vgui.Create("DPanel", parent)
	panel:Dock(TOP)
	panel:DockMargin(0, 0, 0, 10)
	panel:SetTall(height)

	function panel:Paint(w, h)
		fill_rect(0, 0, w, h, Color(31, 34, 40))
		outline_rect(0, 0, w, h, Color(64, 70, 82))
	end

	return panel
end

local frame = vgui.Create("DFrame")
GoluwaTextBoundsProbe = frame
frame:SetTitle("Text Bounds Probe")
frame:SetSize(1280, 860)
frame:Center()
frame:MakePopup()
local outer = vgui.Create("DPanel", frame)
outer:Dock(FILL)
outer:DockPadding(10, 10, 10, 10)

function outer:Paint(w, h)
	fill_rect(0, 0, w, h, Color(22, 24, 29))
	outline_rect(0, 0, w, h, Color(52, 56, 66))
end

local left = vgui.Create("DPanel", outer)
left:Dock(LEFT)
left:SetWide(610)
left:DockMargin(0, 0, 10, 0)
left:DockPadding(10, 10, 10, 10)

function left:Paint(w, h)
	fill_rect(0, 0, w, h, Color(27, 30, 36))
	outline_rect(0, 0, w, h, Color(60, 66, 78))
	outline_rect(0, 36, w, h - 36, Color(44, 48, 58))
	draw.SimpleText(
		"surface metrics",
		"DermaLarge",
		10,
		10,
		Color(255, 255, 255),
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_TOP
	)
	draw.SimpleText(
		"raw surface.GetTextSize and explicit draw positions",
		"DermaDefault",
		10,
		30,
		Color(180, 186, 196),
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_TOP
	)
	draw_surface_sample(
		"DFrame title area",
		"Dock Layout Probe",
		"DermaDefault",
		18,
		72,
		w - 36,
		46,
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_CENTER,
		8,
		0,
		{
			background = Color(60, 72, 110),
			region = Color(126, 154, 228),
			bounds = Color(255, 128, 128),
			origin = Color(255, 128, 128),
			text = Color(255, 255, 255),
			header = Color(220, 228, 255),
		}
	)
	draw_surface_sample(
		"DTab active button",
		"controls",
		"DermaDefault",
		18,
		164,
		200,
		28,
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_TOP,
		10,
		4,
		{
			background = Color(76, 82, 92),
			region = Color(168, 176, 188),
			bounds = Color(255, 164, 92),
			origin = Color(255, 164, 92),
			text = Color(255, 255, 255),
			header = Color(236, 224, 196),
		}
	)
	draw_surface_sample(
		"Centered DButton label",
		"Apply",
		"DermaDefault",
		18,
		242,
		190,
		34,
		TEXT_ALIGN_CENTER,
		TEXT_ALIGN_CENTER,
		0,
		0,
		{
			background = Color(72, 104, 82),
			region = Color(140, 212, 162),
			bounds = Color(255, 128, 128),
			origin = Color(255, 128, 128),
			text = Color(255, 255, 255),
			header = Color(214, 244, 220),
		}
	)
	draw_surface_sample(
		"Left aligned with inset",
		"Indented label",
		"DermaDefault",
		18,
		320,
		260,
		28,
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_TOP,
		12,
		4,
		{
			background = Color(92, 72, 74),
			region = Color(214, 152, 158),
			bounds = Color(255, 216, 118),
			origin = Color(255, 216, 118),
			text = Color(255, 255, 255),
			header = Color(255, 230, 230),
		}
	)
	local legend_y = h - 120
	fill_rect(18, legend_y, w - 36, 92, Color(30, 32, 38))
	outline_rect(18, legend_y, w - 36, 92, Color(64, 70, 82))
	draw.SimpleText(
		"Legend",
		"DermaDefaultBold",
		28,
		legend_y + 12,
		Color(255, 255, 255),
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_TOP
	)
	draw.SimpleText(
		"blue/gray: available region",
		"DermaDefault",
		28,
		legend_y + 34,
		Color(190, 200, 220),
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_TOP
	)
	draw.SimpleText(
		"red/orange: measured text bounds and draw origin",
		"DermaDefault",
		28,
		legend_y + 52,
		Color(255, 190, 160),
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_TOP
	)
	draw.SimpleText(
		"If the right half differs from this half, the wrapper layout math is still off.",
		"DermaDefault",
		28,
		legend_y + 70,
		Color(210, 210, 210),
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_TOP
	)
	return true
end

local right = vgui.Create("DPanel", outer)
right:Dock(FILL)
right:DockPadding(10, 10, 10, 10)

function right:Paint(w, h)
	fill_rect(0, 0, w, h, Color(27, 30, 36))
	outline_rect(0, 0, w, h, Color(60, 66, 78))
end

make_heading(right, "Derma examples with panel, text, and content bounds")
local frame_card = make_card(right, 210)
local sample_frame = vgui.Create("DFrame", frame_card)
sample_frame:SetTitle("Frame title alignment")
sample_frame:SetSize(420, 150)
sample_frame:SetPos(16, 36)
sample_frame:ShowCloseButton(true)
sample_frame:SetDraggable(false)
sample_frame:SetSizable(false)
sample_frame:SetScreenLock(false)
install_bounds_overlay(sample_frame.lblTitle, "lblTitle bounds")
local frame_body = vgui.Create("DLabel", sample_frame)
frame_body:Dock(FILL)
frame_body:SetWrap(true)
frame_body:SetTextInset(12, 12)
frame_body:SetTextColor(Color(255, 255, 255))
frame_body:SetContentAlignment(7)
frame_body:SetText(
	"The title label above should sit naturally inside the 24px title bar. Red/orange boxes track the wrapper text origin and measured bounds."
)
install_bounds_overlay(frame_body, "frame body label")
local property_card = make_card(right, 250)
local property_sheet = vgui.Create("DPropertySheet", property_card)
property_sheet:SetPos(16, 36)
property_sheet:SetSize(520, 196)
local page_one = vgui.Create("DPanel", property_sheet)
page_one:DockPadding(10, 10, 10, 10)

function page_one:Paint(w, h)
	fill_rect(0, 0, w, h, Color(44, 48, 56))
	outline_rect(0, 0, w, h, Color(84, 92, 108))
end

local page_one_label = vgui.Create("DLabel", page_one)
page_one_label:Dock(TOP)
page_one_label:SetTall(28)
page_one_label:SetText("Active tab text should honor left/top inset.")
page_one_label:SetTextInset(12, 4)
page_one_label:SetContentAlignment(7)
page_one_label:SetTextColor(Color(255, 255, 255))
install_bounds_overlay(page_one_label, "active page label")
local page_two = vgui.Create("DPanel", property_sheet)

function page_two:Paint(w, h)
	fill_rect(0, 0, w, h, Color(44, 48, 56))
	outline_rect(0, 0, w, h, Color(84, 92, 108))
end

local page_three = vgui.Create("DPanel", property_sheet)

function page_three:Paint(w, h)
	fill_rect(0, 0, w, h, Color(44, 48, 56))
	outline_rect(0, 0, w, h, Color(84, 92, 108))
end

local controls_sheet = property_sheet:AddSheet("controls", page_one)
local options_sheet = property_sheet:AddSheet("options", page_two)
local metrics_sheet = property_sheet:AddSheet("metrics", page_three)
install_bounds_overlay(controls_sheet.Tab, "tab: controls")
install_bounds_overlay(options_sheet.Tab, "tab: options")
install_bounds_overlay(metrics_sheet.Tab, "tab: metrics")
local widget_card = make_card(right, 210)
local widget_label = vgui.Create("DLabel", widget_card)
widget_label:SetPos(16, 40)
widget_label:SetSize(220, 30)
widget_label:SetText("Inset label")
widget_label:SetTextInset(12, 4)
widget_label:SetContentAlignment(7)
widget_label:SetTextColor(Color(255, 255, 255))
install_bounds_overlay(widget_label, "DLabel inset")
local widget_button = vgui.Create("DButton", widget_card)
widget_button:SetPos(16, 88)
widget_button:SetSize(220, 36)
widget_button:SetText("Centered button")
install_bounds_overlay(widget_button, "DButton centered")
local widget_note = vgui.Create("DLabel", widget_card)
widget_note:SetPos(16, 142)
widget_note:SetSize(560, 44)
widget_note:SetWrap(true)
widget_note:SetTextColor(Color(230, 230, 230))
widget_note:SetContentAlignment(7)
widget_note:SetText(
	"Blue outlines are panel bounds. Orange outlines are content bounds. Red outlines track the measured text box using the wrapper's current text_offset."
)
frame:InvalidateLayout(true)
