local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local theme = require("ui.theme")
local input = require("input")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
return function(props)
	local scroll_v = props.ScrollY ~= false
	local scroll_h = props.ScrollX == true
	local scrollbar_visible = props.ScrollBarVisible ~= false
	local scrollbar_auto_hide = props.ScrollBarAutoHide ~= false
	local viewport
	local handle_v
	local handle_h

	local function update_handle()
		if not viewport:IsValid() then return end

		local content_size = viewport.layout.content_size
		local view_size = viewport.transform.Size

		if not content_size or not view_size then
			if handle_v:IsValid() then handle_v.gui_element:SetVisible(false) end

			if handle_h:IsValid() then handle_h.gui_element:SetVisible(false) end

			return
		end

		local scroll = viewport.transform:GetScroll()

		if handle_v:IsValid() then
			local can_scroll = content_size.y > view_size.y

			if not scroll_v or not scrollbar_visible or (scrollbar_auto_hide and not can_scroll) then
				handle_v.gui_element:SetVisible(false)
			else
				handle_v.gui_element:SetVisible(true)
				local ratio = math.min(1, view_size.y / content_size.y)
				local handle_height = math.max(20, view_size.y * ratio)
				local scroll_track_range = view_size.y - handle_height
				local max_scroll = content_size.y - view_size.y
				local handle_y = 0

				if max_scroll > 0 then
					handle_y = (scroll.y / max_scroll) * scroll_track_range
				end

				handle_v.transform:SetSize(Vec2(6, handle_height))
				handle_v.transform:SetPosition(Vec2(view_size.x - 8, handle_y))
			end
		end

		if handle_h:IsValid() then
			local can_scroll = content_size.x > view_size.x

			if not scroll_h or not scrollbar_visible or (scrollbar_auto_hide and not can_scroll) then
				handle_h.gui_element:SetVisible(false)
			else
				handle_h.gui_element:SetVisible(true)
				local ratio = math.min(1, view_size.x / content_size.x)
				local handle_width = math.max(20, view_size.x * ratio)
				local scroll_track_range = view_size.x - handle_width
				local max_scroll = content_size.x - view_size.x
				local handle_x = 0

				if max_scroll > 0 then
					handle_x = (scroll.x / max_scroll) * scroll_track_range
				end

				handle_h.transform:SetSize(Vec2(handle_width, 6))
				handle_h.transform:SetPosition(Vec2(handle_x, view_size.y - 8))
			end
		end
	end

	local function create_handle(axis)
		local is_v = axis == "y"
		return Panel.New(
			{
				IsInternal = true,
				Name = "scrollbar_handle_" .. axis,
				Ref = function(s)
					if is_v then handle_v = s else handle_h = s end

					s:AddLocalListener("OnTransformChanged", update_handle)
				end,
				rect = {
					Color = Color(1, 1, 1, 0.4),
				},
				transform = {
					Size = is_v and Vec2(6, 40) or Vec2(40, 6),
				},
				gui_element = {
					BorderRadius = 3,
				},
				layout = {
					Floating = true,
				},
				draggable = true,
				mouse_input = true,
				clickable = true,
				animation = true,
				OnDrag = function(self, delta)
					local content_size = viewport.layout.content_size
					local view_size = viewport.transform.Size

					if not content_size or not view_size then return end

					local max_scroll = content_size[axis] - view_size[axis]

					if max_scroll <= 0 then return end

					local handle_len = is_v and self.transform:GetHeight() or self.transform:GetWidth()
					local scroll_track_range = view_size[axis] - handle_len

					if scroll_track_range <= 0 then return end

					local scroll = viewport.transform:GetScroll():Copy()
					scroll[axis] = (self.scroll_start or 0) + (delta[axis] / scroll_track_range) * max_scroll
					scroll[axis] = math.clamp(scroll[axis], 0, max_scroll)
					viewport.transform:SetScroll(scroll)
					return true
				end,
				OnDragStarted = function(self)
					self.scroll_start = viewport.transform:GetScroll()[axis]
				end,
			}
		)
	end

	return Panel.New(
		{
			Name = "scrollable_panel",
			rect = {
				Color = theme.GetColor("invisible"),
			},
			layout = {
				AlignmentX = "stretch",
				Direction = "y",
				props.layout,
			},
			transform = true,
			gui_element = true,
			mouse_input = true,
			clickable = true,
			animation = true,
			PreChildAdd = function(self, child)
				if child.IsInternal then return end

				viewport:AddChild(child)
				return false
			end,
			PreRemoveChildren = function()
				viewport:RemoveChildren()
				return false
			end,
		}
	)(
		{
			Panel.New(
				{
					IsInternal = true,
					Name = "viewport",
					Ref = function(s)
						viewport = s
						s:AddLocalListener("OnTransformChanged", update_handle)
						s:AddLocalListener("OnLayoutUpdated", update_handle)
					end,
					rect = {
						Color = props.Color or theme.GetColor("invisible"),
					},
					gui_element = {
						Clipping = true,
					},
					transform = {
						ScrollEnabled = true,
					},
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						Direction = props.Direction or "y",
						AlignmentX = scroll_h and "start" or "stretch",
						AlignmentY = scroll_v and "start" or "stretch",
						MinSize = Vec2(1, 1),
						MaxSize = Vec2(scroll_h and 1 or 0, scroll_v and 1 or 0),
						Padding = props.Padding,
					},
					mouse_input = true,
					clickable = true,
					animation = true,
					OnMouseInput = function(self, button, press, local_pos)
						if not press then return end

						if button == "mwheel_up" or button == "mwheel_down" then
							local content_size = self.layout.content_size
							local view_size = self.transform.Size

							if not content_size or not view_size then return end

							local scroll = self.transform:GetScroll():Copy()
							local delta = (button == "mwheel_up" and -40 or 40)
							local is_shift = input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift")

							if (scroll_h and not scroll_v) or (scroll_h and is_shift) then
								scroll.x = scroll.x - delta
								local max_scroll = math.max(0, content_size.x - view_size.x)
								scroll.x = math.clamp(scroll.x, 0, max_scroll)
							else
								scroll.y = scroll.y - delta
								local max_scroll = math.max(0, content_size.y - view_size.y)
								scroll.y = math.clamp(scroll.y, 0, max_scroll)
							end

							self.transform:SetScroll(scroll)
							return true
						end
					end,
				}
			),
			create_handle("y"),
			create_handle("x"),
		}
	)
end
