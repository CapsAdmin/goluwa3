local prototype = require("prototype")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local META = prototype.CreateTemplate("panel_text")
META.Base = require("gui.panels.base")
META:StartStorable()
META:GetSet(
	"Font",
	fonts.LoadFont(fonts.GetSystemDefaultFont(), 14),
	{callback = "OnTextChanged"}
)
META:GetSet("Text", "", {callback = "OnTextChanged"})
META:GetSet("Wrap", false, {callback = "OnTextChanged"})
META:GetSet("WrapToParent", false, {callback = "OnTextChanged"})
META:GetSet("AlignX", "left", {callback = "OnTextChanged"})
META:GetSet("AlignX", "left", {callback = "OnTextChanged"})
META:GetSet("AlignY", "top", {callback = "OnTextChanged"})
META:GetSet("Debug", false)
META:EndStorable()

function META:Initialize()
	self.BaseClass.Initialize(self)
	self:OnTextChanged()
	self:SetFocusOnClick(true)
end

function META:OnTextChanged()
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self:GetText()

	if self:GetWrap() then
		local width = self:GetSize().x

		if self:GetWrapToParent() and self:GetParent():IsValid() then
			width = self:GetParent():GetSize().x
		end

		self.wrapped_text = font:WrapString(text, width)
	else
		self.wrapped_text = text
	end

	local w, h = font:GetTextSize(self.wrapped_text)

	if not self:GetWrap() then self:SetSize(Vec2(w, h)) end
end

function META:OnLayout()
	self.BaseClass.OnLayout(self)
	self:OnTextChanged()
end

function META:SetSize(vec)
	self.BaseClass.SetSize(self, vec)

	if self:GetWrap() then self:OnTextChanged() end
end

function META:OnCharInput(char)
	print("Char input:", char)
end

function META:OnKeyInput(key, press)
	print("Key input:", key, press)
end

function META:OnDraw()
	self.Font = self.Font or fonts.LoadFont(fonts.GetSystemDefaultFont(), 20)
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self.wrapped_text or self:GetText()
	local x, y = 0, 0
	local ax, ay = self:GetAlignX(), self:GetAlignY()
	local size = self:GetSize()

	if type(ax) == "number" then
		x = size.x * ax
	elseif ax == "center" then
		x = size.x / 2
	elseif ax == "right" then
		x = size.x
	end

	if type(ay) == "number" then
		y = size.y * ay
	elseif ay == "center" then
		y = size.y / 2
	elseif ay == "bottom" then
		y = size.y
	end

	render2d.SetColor(self:GetColor():Unpack())
	font:DrawText(text, x, y, 0, ax, ay)

	if self.Debug then
		local w, h = font:GetTextSize(text)
		render2d.SetColor(1, 0, 0, 0.25)
		render2d.SetTexture(nil)
		render2d.DrawRect(0, 0, w, h)
	end
end

if HOTRELOAD then
	local timer = require("timer")
	local utility = require("utility")
	local Color = require("structs.color")

	timer.Delay(0, function()
		local gui = require("gui.gui")
		local pnl = utility.RemoveOldObject(gui.Create("frame"))
		pnl:SetPosition(Vec2() + 300)
		pnl:SetSize(Vec2() + 200)
		pnl:SetDragEnabled(true)
		pnl:SetResizable(true)
		pnl:SetClipping(true)
		pnl:SetScrollEnabled(true)
		pnl:SetColor(Color.FromHex("#062a67"):SetAlpha(1))
		local txt = pnl:CreatePanel("text")
		txt:SetWrap(true)
		txt:SetWrapToParent(true)
		txt:SetText([[The materia builder is built to assist in exploring the possibilities of dynamic spells, harmonizing culturures, and customizing a written scale. All with implementation in mind to bridge mage and warriors.]])
	end)
end

return META:Register()
