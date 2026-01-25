local prototype = require("prototype")
local markup = require("render2d.markup")
local render2d = require("render2d.render2d")
local fonts = require("render2d.fonts")
local input = require("input")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local META = prototype.CreateTemplate("panel_text2")
META.Base = require("gui.elements.base")
META:StartStorable()
META:GetSet("MarkupString", "", {callback = "OnMarkupStringChanged"})
META:GetSet("Editable", false, {callback = "OnEditableChanged"})
META:GetSet("Selectable", true, {callback = "OnSelectableChanged"})
META:GetSet("AutoHeight", false)
META:EndStorable()

function META:Initialize()
	self.BaseClass.Initialize(self)
	self.markup_obj = markup.New()
	-- When the markup object's text changes (e.g. from editing), update the property
	self.markup_obj.OnTextChanged = function(_, text)
		if self._internal_change then return end

		self._internal_change = true
		self:SetMarkupString(text)
		self._internal_change = false

		if self.OnTextChanged then self:OnTextChanged(text) end
	end
	self:SetFocusOnClick(true)
	self:SetColor(Color(0, 0, 0, 0)) -- Transparent background by default
end

function META:OnMarkupStringChanged(str)
	if self._internal_change then return end

	self._internal_change = true
	self.markup_obj:SetText(str, true)
	self._internal_change = false
	self:InvalidateLayout()
end

function META:SetMarkup(str)
	self:SetMarkupString(str)
end

function META:GetMarkup()
	return self:GetMarkupString()
end

function META:AddText(str, tags)
	self._internal_change = true
	self.markup_obj:AddString(str, tags)
	self:SetMarkupString(self.markup_obj:GetText(true))
	self._internal_change = false
	self:InvalidateLayout()
end

function META:AddFont(font)
	self.markup_obj:AddFont(font)
end

function META:OnEditableChanged(b)
	self.markup_obj:SetEditable(b)
end

function META:OnSelectableChanged(b)
	self.markup_obj:SetSelectable(b)
end

function META:OnLayout()
	self.BaseClass.OnLayout(self)
	-- Ensure markup knows how wide it can be
	self.markup_obj:SetMaxWidth(self:GetSize().x)
	self.markup_obj:Update()

	if self:GetAutoHeight() then
		local h = self.markup_obj.height

		if h and h > 0 and h ~= self:GetSize().y then
			self:SetSize(Vec2(self:GetSize().x, h))
		end
	end
end

function META:OnCharInput(char)
	self.markup_obj:OnCharInput(char)
end

function META:OnKeyInput(key, press)
	-- Pass modifier states to markup
	self.markup_obj:SetShiftDown(input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift"))
	self.markup_obj:SetControlDown(input.IsKeyDown("left_control") or input.IsKeyDown("right_control"))

	if press then self.markup_obj:OnKeyInput(key) end
end

function META:OnMouseInput(button, press, pos)
	self.markup_obj:SetMousePosition(pos)
	self.markup_obj:OnMouseInput(button, press)
end

do
	local m
	local event = require("event")

	event.AddListener("Draw2D", "test", function()
		if not m then
			m = markup.New()
			m:AddString("what")
		end

		render2d.PushMatrix(50, 50)
		m:Update()
		m:Draw()
		render2d.PopMatrix()
	end)
end

function META:OnDraw()
	-- self.BaseClass.OnDraw(self) -- Draws background if Color alpha > 0
	-- Sync mouse position for hover effects in markup
	self.markup_obj:SetMousePosition(self:GetMousePosition())
	self.markup_obj:Update()
	-- Use a default font if none is set in markup to avoid invisible text
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(1)
	render2d.SetTexture(nil)
	self.markup_obj:Draw()
end

if HOTRELOAD then
	local timer = require("timer")
	local utility = require("utility")

	timer.Delay(0, function()
		local gui = require("gui.gui")
		local pnl = utility.RemoveOldObject(gui.Create("frame"))
		pnl:SetPosition(Vec2() + 300)
		pnl:SetSize(Vec2(400, 300))
		pnl:SetDragEnabled(true)
		pnl:SetResizable(true)
		pnl:SetClipping(false) -- Disable clipping as user requested
		pnl:SetScrollEnabled(true)
		pnl:SetColor(Color.FromHex("#062a67"):SetAlpha(1))
		local txt = pnl:CreatePanel("text2")
		txt:SetPosition(Vec2(10, 30))
		txt:SetSize(Vec2(380, 260))
		txt:SetEditable(true)
		-- Use system font explicitly to be safe
		local sys_font = fonts.GetSystemDefaultFont()
		txt:AddFont(fonts.CreateFont({size = 14, read_speed = 100}))
		txt:SetMarkup(string.format("<font=%s><color=1,1,1,1>Type here...</color></font>\n", sys_font))
		txt:AddText("<color=1,0.5,0.5,1>Red Text</color> ", true)
		txt:AddText("<color=0.5,1,0.5,1>Green Text</color>", true)
	end)
end

return META:Register()
