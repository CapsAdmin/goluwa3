local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Markup = import("goluwa/render2d/markup.lua")
local META = Panel:CreateTemplate("markup_panel")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	GrowHeight = 1,
}
META:StartStorable()
META:GetSet("Markup", nil)
META:GetSet("ContentPadding", 4)
META:GetSet("StickToBottom", true)
META:EndStorable()

local function on_container_draw(container)
	container.MarkupPanel:draw_content(container)
end

function META:OnCreate(props)
	props.Size = props.Size or Vec2(400, 200)
	props.Markup = props.Markup or Markup.New()
	META.BaseClass.OnCreate(self, props)
	self._content_height = 0
	self._scroll_panel = ScrollablePanel{
		Parent = self,
		IsInternal = true,
		ScrollY = true,
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
		},
	}
	self._container = Panel.New{
		Parent = self._scroll_panel,
		Name = "markup_container",
		MarkupPanel = self,
		transform = true,
		layout = {
			MinSize = Vec2(1, 1),
			GrowWidth = 1,
			FitHeight = true,
		},
		visual = true,
		OnDraw = on_container_draw,
	}
end

function META:ScrollToBottom()
	self._pending_bottom = true
end

function META:OnParentVisibilityChanged(visible)
	if visible then self:ScrollToBottom() end
end

function META:draw_content(container)
	local markup = self.Markup
	local padding = self.ContentPadding
	local viewport = container:GetParent().transform
	local view = viewport:GetSize()
	local width = container.transform:GetWidth()
	markup:SetMaxWidth(width - padding * 2)
	markup:Update()
	local height = math.max((markup.height or 0) + padding * 2, view.y)

	if height ~= self._content_height then
		local at_bottom = self._pending_bottom or
			viewport:GetScroll().y >= self._content_height - view.y - 1
		self._content_height = height
		self._pending_bottom = self.StickToBottom and at_bottom
		container.layout:SetMinSize(Vec2(1, height))
	end

	local content_size = container:GetParent().layout.content_size

	if self._pending_bottom and content_size then
		local content_height = content_size.y
		viewport:SetScroll(Vec2(0, math.max(0, content_height - view.y)))
		self._pending_bottom = content_height + 1 < height
	end

	render2d.SetColor(0, 0, 0, 1)
	render2d.DrawRect(0, 0, width, height)
	render2d.PushMatrix(padding, padding)
	markup:Draw()
	render2d.PopMatrix()
end

return META:Register()
