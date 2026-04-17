if IsValid(GoluwaDockLayoutProbe) then GoluwaDockLayoutProbe:Remove() end

local function make_fill_label(parent, text)
	local label = vgui.Create("DLabel", parent)
	label:Dock(FILL)
	label:SetText(text)
	label:SetContentAlignment(5)
	label:SetTextColor(Color(255, 255, 255))
	return label
end

local function make_corner_label(parent, text)
	local label = vgui.Create("DLabel", parent)
	label:SetText(text)
	label:SetTextColor(Color(255, 255, 255))
	label:SizeToContents()
	label:SetPos(8, 6)
	label:SetMouseInputEnabled(false)
	label:SetZPos(1000)
	return label
end

local function make_panel(parent, dock_mode, size, color, text, use_fill_label)
	local panel = vgui.Create("DPanel", parent)
	panel:Dock(dock_mode)

	if dock_mode == TOP or dock_mode == BOTTOM then
		panel:SetTall(size)
	elseif dock_mode == LEFT or dock_mode == RIGHT then
		panel:SetWide(size)
	end

	function panel:Paint(w, h)
		surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
		surface.DrawRect(0, 0, w, h)
	end

	if use_fill_label == false then
		make_corner_label(panel, text)
	else
		make_fill_label(panel, text)
	end

	return panel
end

local frame = vgui.Create("DFrame")
GoluwaDockLayoutProbe = frame
frame:SetTitle("Dock Layout Probe")
frame:SetSize(900, 620)
frame:Center()
frame:MakePopup()
local outer = vgui.Create("DPanel", frame)
outer:Dock(FILL)
outer:DockPadding(10, 10, 10, 10)

function outer:Paint(w, h)
	surface.SetDrawColor(24, 24, 28, 255)
	surface.DrawRect(0, 0, w, h)
end

make_panel(outer, TOP, 70, Color(180, 70, 70), "TOP 70")
make_panel(outer, BOTTOM, 70, Color(70, 110, 180), "BOTTOM 70")
make_panel(outer, LEFT, 160, Color(70, 150, 90), "LEFT 160")
make_panel(outer, RIGHT, 160, Color(180, 140, 70), "RIGHT 160")
local fill = make_panel(outer, FILL, 0, Color(90, 80, 140), "FILL", false)
fill:DockPadding(10, 10, 10, 10)
local nested_top = make_panel(fill, TOP, 52, Color(160, 90, 120), "nested TOP 52")
local nested_bottom = make_panel(fill, BOTTOM, 52, Color(90, 160, 160), "nested BOTTOM 52")
local nested_left = make_panel(fill, LEFT, 120, Color(130, 110, 70), "nested LEFT 120")
local nested_right = make_panel(fill, RIGHT, 120, Color(90, 120, 70), "nested RIGHT 120")
local nested_fill = make_panel(fill, FILL, 0, Color(70, 70, 70), "nested FILL", false)
local info = vgui.Create("DLabel", nested_fill)
info:Dock(FILL)
info:SetWrap(true)
info:SetTextInset(12, 12)
info:SetContentAlignment(7)
info:SetTextColor(Color(255, 255, 255))
info:SetText(
	"If docking works, every colored block should occupy its own region.\n" .. "If docking is broken, these panels usually collapse into a thin strip in the top-left."
)
