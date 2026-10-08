local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local Icon = import("goluwa/render2d/ui/elements/icon.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("window")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	AlignmentX = "stretch",
	Floating = true,
}
META.CMP.resizable = {BringToFrontOnResize = true}
META.CMP.visual = {}
META.CMP.mouse_input = {BringToFrontOnClick = true}
META.CMP.clickable = {}
META.CMP.animation = {}
META:StartStorable()
META:GetSet("Title", "Window")
META:GetSet("MinSize", nil)
META:GetSet("Padding", nil)
META:EndStorable()

function META:OnClose()
	self:Remove()
end

local function on_header_draw(header)
	theme.active:Draw(header)
end

local function on_content_draw(content)
	theme.active:Draw(content)
end

local function on_content_post_draw(content)
	theme.active:DrawPost(content)
end

local function on_close_click(button)
	button.Window:OnClose()
end

function META:OnCreate(props)
	props.Size = props.Size or Vec2(400, 300)
	props.Position = props.Position or Vec2(100, 100)
	META.BaseClass.OnCreate(self, props)
	self.resizable:SetMinimumSize(self.MinSize or Vec2(100, 100))
	self._header = Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "window_header",
		transform = true,
		layout = {
			Direction = "x",
			AlignmentY = "center",
			FitHeight = true,
			Padding = "XS",
		},
		visual = true,
		draggable = true,
		mouse_input = {Cursor = "sizeall"},
		clickable = true,
		animation = true,
		OnDraw = on_header_draw,
	}
	self._header.draggable:SetTarget(self)
	self._title = Text{
		Parent = self._header,
		IsInternal = true,
		Text = self.Title,
		Font = "heading",
		IgnoreMouseInput = true,
		layout = {
			GrowWidth = 1,
			FitHeight = true,
		},
	}
	self._close_button = Clickable{
		Parent = self._header,
		IsInternal = true,
		Window = self,
		Mode = "text",
		Size = "M",
		layout = {
			Padding = "XXXS",
			FitWidth = false,
			FitHeight = false,
		},
		OnClick = on_close_click,
	}
	Icon{
		Parent = self._close_button,
		IsInternal = true,
		Icon = "close",
		Size = "S",
	}
	self._content = Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "window_content",
		transform = true,
		layout = {
			Direction = "y",
			GrowWidth = 1,
			GrowHeight = 1,
			Padding = self.Padding or "M",
		},
		visual = true,
		mouse_input = true,
		clickable = true,
		animation = true,
		OnDraw = on_content_draw,
		OnPostDraw = on_content_post_draw,
	}
end

function META:SetTitle(title)
	self.Title = title

	if self._title then self._title.text:SetText(title) end

	return self
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	self._content:AddChild(child)
	return false
end

function META:PreRemoveChildren()
	self._content:RemoveChildren()
	return false
end

return META:Register()
