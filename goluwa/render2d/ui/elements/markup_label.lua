local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Markup = import("goluwa/render2d/markup.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("markup_label")
META.CMP.transform = {}
META.CMP.layout = {GrowWidth = 1, MinSize = Vec2(1, 1)}
META.CMP.visual = {}
META:StartStorable()
META:GetSet("Text", "")
META:GetSet("FontSize", "M")
META:GetSet("AdaptColors", false)
META:GetSet("ContentMinHeight", 0)
META:EndStorable()

function META.SyncTheme(markup, font_size, adapt_colors)
	local active = theme.active
	local background = active:GetColor("surface")
	local selection_color = active:GetColor("text_selection")
	local text_color = active:GetColor("text", {surface = "surface"})
	local font = active:GetFont("body", font_size)
	markup:SetBackground(background)
	markup:SetAdaptColors(adapt_colors)

	if markup.SelectionColor ~= selection_color then
		markup:SetSelectionColor(selection_color)
	end

	if markup.DefaultColor ~= text_color then markup:SetDefaultColor(text_color) end

	if markup.DefaultFont ~= font then markup:SetDefaultFont(font) end

	return background
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self.Markup = Markup.New()
	self.Markup:SetEditable(false)
	self.Markup:SetSelectable(false)
	self.Markup:SetMinimumHeight(self.ContentMinHeight)
	self.Markup:AddString(self.Text, true)
end

function META:SetText(text)
	self.Text = text

	if not self.Markup then return self end

	self.Markup:SetText(text, true)
	return self
end

function META:OnDraw()
	local markup = self.Markup
	META.SyncTheme(markup, self.FontSize, self.AdaptColors)
	markup:SetMaxWidth(self.transform:GetWidth())
	markup:Update()
	local height = math.max(markup.height or 0, 1)

	if self.layout:GetMinSize().y ~= height then
		self.layout:SetMinSize(Vec2(1, height))
		self.layout:SetMaxSize(Vec2(0, height))
	end

	markup:Draw()
end

return META:Register()
