local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local theme = require("ui.theme")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
return function(props)
	local scrollbar_visible = props.ScrollBarVisible ~= false
	local scrollbar_auto_hide = props.ScrollBarAutoHide ~= false
	local container = Panel.NewPanel(
		table.merge_many(
			{
				Name = "scrollable_panel",
				Color = theme.GetColor("invisible"),
				layout = {
					AlignmentX = "stretch",
					AlignmentY = "stretch",
					Direction = "y",
				},
			},
			props,
			{Children = nil}
		)
	)
	local viewport = Panel.NewPanel(
		{
			Name = "viewport",
			Parent = container,
			Color = theme.GetColor("invisible"),
			gui_element = {
				Clipping = true,
			},
			transform = {
				ScrollEnabled = true,
			},
			layout = table.merge_many(
				{
					GrowWidth = 1,
					GrowHeight = 1,
					Direction = "y",
					AlignmentX = "stretch",
					MinSize = Vec2(1,1),
					MaxSize = Vec2(10,10),
				},
				props.Layout or {},
				props.layout or {}
			),
			Children = props.Children,
		}
	)
	local handle = Panel.NewPanel(
		{
			Name = "scrollbar_handle",
			Parent = container,
			Color = Color(1, 1, 1, 0.4),
			Size = Vec2(6, 40),
			gui_element = {
				BorderRadius = 3,
			},
			layout = {
				Floating = true,
			},
			draggable = true,
		}
	)

	function handle:OnDrag(delta)
		local content_size = viewport.layout.content_size
		local view_size = viewport.transform.Size

		if not content_size or not view_size then return end

		local max_scroll = content_size.y - view_size.y

		if max_scroll <= 0 then return end

		local handle_height = self.transform:GetHeight()
		local scroll_track_range = view_size.y - handle_height

		if scroll_track_range <= 0 then return end

		local scroll_y = (self.scroll_start or 0) + (delta.y / scroll_track_range) * max_scroll
		viewport.transform:SetScroll(Vec2(0, math.clamp(scroll_y, 0, max_scroll)))
		return true
	end

	function handle:OnDragStarted()
		self.scroll_start = viewport.transform:GetScroll().y
	end

	local function update_handle()
		if not scrollbar_visible then
			handle.gui_element:SetVisible(false)
			return
		end

		local content_size = viewport.layout.content_size
		local view_size = viewport.transform.Size

		if not content_size or not view_size then
			handle.gui_element:SetVisible(false)
			return
		end

		local can_scroll = content_size.y > view_size.y

		if scrollbar_auto_hide and not can_scroll then
			handle.gui_element:SetVisible(false)
			return
		end

		handle.gui_element:SetVisible(true)
		local scroll = viewport.transform:GetScroll()
		local ratio = view_size.y / content_size.y
		local handle_height = math.max(20, view_size.y * ratio)
		local scroll_track_range = view_size.y - handle_height
		local max_scroll = content_size.y - view_size.y
		local handle_y = 0

		if max_scroll > 0 then
			handle_y = (scroll.y / max_scroll) * scroll_track_range
		end

		handle.transform:SetSize(Vec2(6, handle_height))
		handle.transform:SetPosition(Vec2(view_size.x - 8, handle_y))
	end

	container:AddLocalListener("OnTransformChanged", update_handle)
	viewport:AddLocalListener("OnTransformChanged", update_handle)

	function container:SetChildren(children)
		viewport:SetChildren(children)
	end

	function viewport:OnMouseInput(button, press, local_pos)
		if not press then return end

		if button == "mwheel_up" or button == "mwheel_down" then
			local content_size = self.layout.content_size
			local view_size = self.transform.Size

			if not content_size or not view_size then return end

			local scroll = self.transform:GetScroll():Copy()
			local delta = (button == "mwheel_up" and -40 or 40)
			scroll.y = scroll.y + delta
			local max_scroll = math.max(0, content_size.y - view_size.y)
			scroll.y = math.clamp(scroll.y, 0, max_scroll)
			self.transform:SetScroll(scroll)
			return true
		end
	end

	return container
end
