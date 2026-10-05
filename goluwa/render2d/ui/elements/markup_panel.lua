local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Markup = import("goluwa/render2d/markup.lua")
local META = Panel:CreateTemplate("markup_panel")
META.Name = "markup_panel"
META.CMP.transform = {
	Size = Vec2(400, 200),
}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	GrowHeight = 1,
}
META:GetSet("ContentPadding", 4)
META:GetSet("StickToBottom", true)
META.content_height = 0

function META:GetMarkup()
	return self.markup
end

function META:OnCreate(props)
	props = props or {}
	self.markup = props.Markup or Markup.New()
	self.ContentPadding = props.ContentPadding or 4
	self.StickToBottom = props.StickToBottom ~= false
	self.BaseClass.OnCreate(self, {Ref = props.Ref})
	self:AddChild(
		ScrollablePanel{
			Ref = function(s)
				self.scroll_panel = s
			end,
			ScrollY = true,
			ScrollBarAutoHide = true,
			ScrollBarVisible = true,
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
			},
		}{
			Panel.New{
				Name = "markup_container",
				transform = true,
				layout = {
					MinSize = Vec2(1, 1),
					GrowWidth = 1,
					FitHeight = true,
				},
				visual = true,
				OnDraw = function(container)
					self:DrawContent(container)
				end,
			},
		}
	)
end

function META:ScrollToBottom()
	self.pending_bottom = true
end

function META:OnParentVisibilityChanged(visible)
	if visible then self:ScrollToBottom() end
end

function META:DrawContent(container)
	local markup = self.markup
	local padding = self.ContentPadding
	local viewport = container:GetParent().transform
	local view = viewport:GetSize()
	local width = container.transform:GetWidth()
	markup:SetMaxWidth(width - padding * 2)
	markup:Update()
	local height = math.max((markup.height or 0) + padding * 2, view.y)

	if height ~= self.content_height then
		local at_bottom = self.pending_bottom or viewport:GetScroll().y >= self.content_height - view.y - 1
		self.content_height = height
		self.pending_bottom = self.StickToBottom and at_bottom
		container.layout:SetMinSize(Vec2(1, height))
	end

	local content_size = container:GetParent().layout.content_size

	if self.pending_bottom and content_size then
		local content_height = content_size.y
		viewport:SetScroll(Vec2(0, math.max(0, content_height - view.y)))
		self.pending_bottom = content_height + 1 < height
	end

	render2d.SetColor(0, 0, 0, 1)
	render2d.DrawRect(0, 0, width, height)
	render2d.PushMatrix(padding, padding)
	markup:Draw()
	render2d.PopMatrix()
end

META:Register()
return META.New
