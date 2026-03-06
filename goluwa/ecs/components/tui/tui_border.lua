local prototype = require("prototype")
local utf8 = require("utf8")
local META = prototype.CreateTemplate("tui_border")
META:StartStorable()
-- Optional title shown in the top border ("" = no title)
META:GetSet("Title", "")
-- "left" | "right"  — which side the title label is placed on
META:GetSet("TitleAlign", "left")
-- Border drawing characters (defaults match tui.lua)
META:GetSet("TopLeft", "╭")
META:GetSet("TopRight", "╮")
META:GetSet("BottomLeft", "╰")
META:GetSet("BottomRight", "╯")
META:GetSet("Horizontal", "─")
META:GetSet("Vertical", "│")
META:EndStorable()

function META:Initialize()
	self.Owner:EnsureComponent("tui_element")

	self.Owner:AddLocalListener("OnDraw", function(_, term, abs_x, abs_y, w, h)
		self:OnDraw(term, abs_x, abs_y, w, h)
	end)
end

function META:OnDraw(term, abs_x, abs_y, w, h)
	if w < 2 or h < 1 then return end

	local tl = self:GetTopLeft()
	local tr = self:GetTopRight()
	local bl = self:GetBottomLeft()
	local br = self:GetBottomRight()
	local hz = self:GetHorizontal()
	local vt = self:GetVertical()
	local title = self:GetTitle()
	local title_align = self:GetTitleAlign()
	local inner_w = w - 2 -- space between corner characters
	local top_border

	if title and title ~= "" then
		local label = " " .. title:upper() .. " "
		local label_len = utf8.length(label)
		local start_pos

		if title_align == "right" then
			start_pos = w - label_len -- 1-based position of label start (inclusive corners)
		else
			start_pos = 2
		end

		local prefix_len = start_pos - 1
		local suffix_len = w - prefix_len - label_len
		local prefix = tl .. string.rep(hz, math.max(0, prefix_len - 1))
		local suffix = string.rep(hz, math.max(0, suffix_len - 1)) .. tr
		top_border = prefix .. label .. suffix
	else
		top_border = tl .. string.rep(hz, inner_w) .. tr
	end

	local bottom_border = bl .. string.rep(hz, inner_w) .. br
	local middle_row = vt .. string.rep(" ", inner_w) .. vt

	for i = 0, h - 1 do
		term:SetCaretPosition(abs_x, abs_y + i)

		if i == 0 then
			term:WriteText(top_border)
		elseif i == h - 1 then
			term:WriteText(bottom_border)
		else
			term:WriteText(middle_row)
		end
	end
end

return META:Register()