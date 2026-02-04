local prototype = require("prototype")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local META = prototype.CreateTemplate("text")
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
META:GetSet("AlignY", "top", {callback = "OnTextChanged"})
META:GetSet("Debug", false)
META:GetSet("Color", Color(1, 1, 1, 1))
META:EndStorable()

function META:Initialize()
	self:OnTextChanged()

	self.Owner:AddLocalListener("OnDraw", function()
		self:OnDraw()
	end)
end

function META:OnTextChanged()
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self:GetText()

	if self:GetWrap() then
		local width = self.Owner.transform.Size.x

		if
			self:GetWrapToParent() and
			self.Owner:GetParent() and
			self.Owner:GetParent().transform
		then
			width = self.Owner:GetParent().transform.Size.x
		end

		self.wrapped_text = font:WrapString(text, width)
	else
		self.wrapped_text = text
	end

	local w, h = font:GetTextSize(self.wrapped_text)

	if not self:GetWrap() then
		self.Owner.transform:SetSize(Vec2(w, h))

		if self.Owner:HasParent() and self.Owner:GetParent().layout then
			self.Owner:GetParent().layout:InvalidateLayout()
			print("update layout")
		end

		print(w, h)
	end
end

function META:OnDraw()
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self.wrapped_text or self:GetText()
	local x, y = 0, 0
	local ax, ay = self:GetAlignX(), self:GetAlignY()
	local size = self.Owner.transform.Size

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

return META:Register()
