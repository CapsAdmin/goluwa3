local Panel = import("goluwa/ecs/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local theme = import("lua/ui/theme.lua")
local input = import("goluwa/input.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")

local function normalize_padding(padding)
	if type(padding) == "string" then return Rect() + theme.GetPadding(padding) end

	if type(padding) == "number" then return Rect() + padding end

	if not padding then return Rect(0, 0, 0, 0) end

	return padding
end

return function(props)
	props = props or {}
	local external_ref = props.Ref

	if external_ref then
		props = table.shallow_copy(props)
		props.Ref = nil
	end

	local scroll_v = props.ScrollY ~= false
	local scroll_h = props.ScrollX == true
	local scrollbar_visible = props.ScrollBarVisible ~= false
	local scrollbar_auto_hide = props.ScrollBarAutoHide ~= false
	local scrollbar_shift_mode = props.ScrollBarContentShiftMode or "always_shift"
	local scrollbar_reserve = props.ScrollBarReserve or 10
	local capture_wheel_at_extents = props.CaptureWheelAtExtents == true
	local base_padding = normalize_padding(props.Padding)
	local viewport
	local track_v
	local track_h
	local handle_v
	local handle_h

	if
		scrollbar_shift_mode ~= "no_shift" and
		scrollbar_shift_mode ~= "auto_shift" and
		scrollbar_shift_mode ~= "always_shift"
	then
		scrollbar_shift_mode = "always_shift"
	end

	local function make_padding(right_shift, bottom_shift)
		return Rect(
			base_padding.x,
			base_padding.y,
			base_padding.w + right_shift,
			base_padding.h + bottom_shift
		)
	end

	local function compute_scrollbar_state(content_size, view_size)
		content_size = content_size or Vec2(0, 0)
		view_size = view_size or Vec2(0, 0)
		local always_shift_v = scrollbar_shift_mode == "always_shift" and scroll_v and scrollbar_visible
		local always_shift_h = scrollbar_shift_mode == "always_shift" and scroll_h and scrollbar_visible
		local auto_shift = scrollbar_shift_mode == "auto_shift"
		local show_v = false
		local show_h = false
		local reserve_v = always_shift_v
		local reserve_h = always_shift_h

		if auto_shift then
			for _ = 1, 2 do
				local available_w = math.max(0, view_size.x - (show_v and scrollbar_reserve or 0))
				local available_h = math.max(0, view_size.y - (show_h and scrollbar_reserve or 0))
				local can_scroll_v = content_size.y > available_h
				local can_scroll_h = content_size.x > available_w
				show_v = scroll_v and scrollbar_visible and (not scrollbar_auto_hide or can_scroll_v)
				show_h = scroll_h and scrollbar_visible and (not scrollbar_auto_hide or can_scroll_h)
			end

			reserve_v = show_v
			reserve_h = show_h
		else
			local can_scroll_v = content_size.y > view_size.y
			local can_scroll_h = content_size.x > view_size.x
			show_v = scroll_v and scrollbar_visible and (not scrollbar_auto_hide or can_scroll_v)
			show_h = scroll_h and scrollbar_visible and (not scrollbar_auto_hide or can_scroll_h)
		end

		return {
			content_size = content_size,
			view_size = view_size,
			show_v = show_v,
			show_h = show_h,
			reserve_v = reserve_v,
			reserve_h = reserve_h,
			available_w = math.max(0, view_size.x - (reserve_v and scrollbar_reserve or 0)),
			available_h = math.max(0, view_size.y - (reserve_h and scrollbar_reserve or 0)),
		}
	end

	local function update_viewport_padding(state)
		if not viewport or not viewport:IsValid() or not viewport.layout then return end

		local padding = make_padding(
			state.reserve_v and scrollbar_reserve or 0,
			state.reserve_h and scrollbar_reserve or 0
		)
		local current = viewport.layout:GetPadding()

		if
			not current or
			current.x ~= padding.x or
			current.y ~= padding.y or
			current.w ~= padding.w or
			current.h ~= padding.h
		then
			viewport.layout:SetPadding(padding)
		end
	end

	local function clamp_scroll_to_bounds(content_size, view_size)
		if not viewport or not viewport:IsValid() then return nil, false end

		local state = compute_scrollbar_state(content_size, view_size)
		local effective_view_size = Vec2(state.available_w, state.available_h)
		local scroll = viewport.transform:GetScroll():Copy()
		local next_scroll = scroll:Copy()
		local max_scroll_x = math.max(0, (content_size and content_size.x or 0) - effective_view_size.x)
		local max_scroll_y = math.max(0, (content_size and content_size.y or 0) - effective_view_size.y)

		if scroll_h then
			next_scroll.x = math.clamp(next_scroll.x, 0, max_scroll_x)
		else
			next_scroll.x = 0
		end

		if scroll_v then
			next_scroll.y = math.clamp(next_scroll.y, 0, max_scroll_y)
		else
			next_scroll.y = 0
		end

		local changed = next_scroll.x ~= scroll.x or next_scroll.y ~= scroll.y

		if changed then viewport.transform:SetScroll(next_scroll) end

		return next_scroll, changed
	end

	local function update_handle()
		if not viewport:IsValid() then return end

		local content_size = viewport.layout.content_size
		local view_size = viewport.transform.Size
		local state = compute_scrollbar_state(content_size, view_size)
		update_viewport_padding(state)

		if not content_size or not view_size then
			clamp_scroll_to_bounds(Vec2(0, 0), Vec2(0, 0))

			if track_v and track_v:IsValid() then track_v.gui_element:SetVisible(false) end

			if track_h and track_h:IsValid() then track_h.gui_element:SetVisible(false) end

			if handle_v:IsValid() then handle_v.gui_element:SetVisible(false) end

			if handle_h:IsValid() then handle_h.gui_element:SetVisible(false) end

			return
		end

		local scroll = clamp_scroll_to_bounds(content_size, view_size) or viewport.transform:GetScroll()

		if handle_v:IsValid() then
			if not state.show_v then
				if track_v and track_v:IsValid() then track_v.gui_element:SetVisible(false) end

				handle_v.gui_element:SetVisible(false)
			else
				local track_height = state.available_h
				local track_x = view_size.x - 8
				local max_scroll_view_h = math.max(1, state.available_h)
				local max_scroll = math.max(0, content_size.y - max_scroll_view_h)

				if track_v and track_v:IsValid() then
					track_v.gui_element:SetVisible(true)
					track_v.transform:SetSize(Vec2(6, track_height))
					track_v.transform:SetPosition(Vec2(track_x, 0))
				end

				handle_v.gui_element:SetVisible(true)
				local ratio = math.min(1, max_scroll_view_h / math.max(content_size.y, 1))
				local handle_height = math.max(20, track_height * ratio)
				local scroll_track_range = track_height - handle_height
				local handle_y = 0

				if max_scroll > 0 then
					handle_y = (scroll.y / max_scroll) * scroll_track_range
				end

				handle_v.transform:SetSize(Vec2(6, handle_height))
				handle_v.transform:SetPosition(Vec2(track_x, handle_y))
			end
		end

		if handle_h:IsValid() then
			if not state.show_h then
				if track_h and track_h:IsValid() then track_h.gui_element:SetVisible(false) end

				handle_h.gui_element:SetVisible(false)
			else
				local track_width = state.available_w
				local track_y = view_size.y - 8
				local max_scroll_view_w = math.max(1, state.available_w)
				local max_scroll = math.max(0, content_size.x - max_scroll_view_w)

				if track_h and track_h:IsValid() then
					track_h.gui_element:SetVisible(true)
					track_h.transform:SetSize(Vec2(track_width, 6))
					track_h.transform:SetPosition(Vec2(0, track_y))
				end

				handle_h.gui_element:SetVisible(true)
				local ratio = math.min(1, max_scroll_view_w / math.max(content_size.x, 1))
				local handle_width = math.max(20, track_width * ratio)
				local scroll_track_range = track_width - handle_width
				local handle_x = 0

				if max_scroll > 0 then
					handle_x = (scroll.x / max_scroll) * scroll_track_range
				end

				handle_h.transform:SetSize(Vec2(handle_width, 6))
				handle_h.transform:SetPosition(Vec2(handle_x, track_y))
			end
		end
	end

	local function handle_wheel_scroll(target, button)
		local content_size = target.layout and target.layout.content_size
		local view_size = target.transform and target.transform.Size

		if not content_size or not view_size then return end

		local state = compute_scrollbar_state(content_size, view_size)
		local effective_view_size = Vec2(state.available_w, state.available_h)
		local scroll = target.transform:GetScroll():Copy()
		local next_scroll = scroll:Copy()
		local delta = (button == "mwheel_up" and -40 or 40)
		local is_shift = input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift")

		if (scroll_h and not scroll_v) or (scroll_h and is_shift) then
			local max_scroll = math.max(0, content_size.x - effective_view_size.x)

			if max_scroll <= 0 then return capture_wheel_at_extents end

			next_scroll.x = math.clamp(scroll.x - delta, 0, max_scroll)
		else
			local max_scroll = math.max(0, content_size.y - effective_view_size.y)

			if max_scroll <= 0 then return capture_wheel_at_extents end

			next_scroll.y = math.clamp(scroll.y - delta, 0, max_scroll)
		end

		if next_scroll.x == scroll.x and next_scroll.y == scroll.y then
			return capture_wheel_at_extents
		end

		target.transform:SetScroll(next_scroll)
		return true
	end

	local function get_padding_rect(padding)
		if type(padding) == "number" then
			return Rect(padding, padding, padding, padding)
		end

		if padding and padding.x and padding.y and padding.w and padding.h then
			return padding
		end

		return Rect(0, 0, 0, 0)
	end

	local function scroll_rect_into_view(x1, y1, x2, y2, padding)
		if not viewport or not viewport:IsValid() then return false end

		local content_size = viewport.layout and viewport.layout.content_size
		local view_size = viewport.transform and viewport.transform.Size

		if not content_size or not view_size then return false end

		local state = compute_scrollbar_state(content_size, view_size)
		local effective_view_size = Vec2(state.available_w, state.available_h)
		local scroll = viewport.transform:GetScroll():Copy()
		local next_scroll = scroll:Copy()
		local pad = get_padding_rect(padding)

		if scroll_h then
			local max_scroll_x = math.max(0, content_size.x - effective_view_size.x)
			local target_left = x1 - pad.x
			local target_right = x2 + pad.w

			if target_left < next_scroll.x then
				next_scroll.x = target_left
			elseif target_right > next_scroll.x + effective_view_size.x then
				next_scroll.x = target_right - effective_view_size.x
			end

			next_scroll.x = math.clamp(next_scroll.x, 0, max_scroll_x)
		end

		if scroll_v then
			local max_scroll_y = math.max(0, content_size.y - effective_view_size.y)
			local target_top = y1 - pad.y
			local target_bottom = y2 + pad.h

			if target_top < next_scroll.y then
				next_scroll.y = target_top
			elseif target_bottom > next_scroll.y + effective_view_size.y then
				next_scroll.y = target_bottom - effective_view_size.y
			end

			next_scroll.y = math.clamp(next_scroll.y, 0, max_scroll_y)
		end

		if next_scroll.x == scroll.x and next_scroll.y == scroll.y then return false end

		viewport.transform:SetScroll(next_scroll)
		return true
	end

	local function update_dirty_layout(entity)
		local current = entity
		local root_layout = nil

		while current and current:IsValid() do
			local layout = current.layout

			if layout and layout:GetDirty() then root_layout = layout end

			current = current:GetParent()
		end

		if root_layout then root_layout:UpdateLayout() end
	end

	local function create_track(axis)
		local is_v = axis == "y"
		return Panel.New{
			IsInternal = true,
			Name = "scrollbar_track_" .. axis,
			OnSetProperty = theme.OnSetProperty,
			Ref = function(s)
				if is_v then track_v = s else track_h = s end
			end,
			transform = {
				Size = is_v and Vec2(6, 40) or Vec2(40, 6),
			},
			gui_element = {
				BorderRadius = theme.GetRadius("small"),
				Visible = false,
				OnDraw = function(self)
					theme.active:DrawSurface(theme.GetDrawContext(self, true), props.ScrollBarTrackColor or "scrollbar_track")
				end,
			},
			layout = {
				Floating = true,
			},
		}
	end

	local function create_handle(axis)
		local is_v = axis == "y"
		return Panel.New{
			IsInternal = true,
			Name = "scrollbar_handle_" .. axis,
			OnSetProperty = theme.OnSetProperty,
			Ref = function(s)
				if is_v then handle_v = s else handle_h = s end

				s:AddLocalListener("OnTransformChanged", update_handle)
			end,
			transform = {
				Size = is_v and Vec2(6, 40) or Vec2(40, 6),
			},
			gui_element = {
				BorderRadius = theme.GetRadius("small"),
				Visible = false,
				OnDraw = function(self)
					theme.active:DrawSurface(theme.GetDrawContext(self, true), props.ScrollBarColor or "scrollbar")
				end,
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

				local state = compute_scrollbar_state(content_size, view_size)
				local effective_view_size = Vec2(state.available_w, state.available_h)
				local max_scroll = content_size[axis] - effective_view_size[axis]

				if max_scroll <= 0 then return end

				local handle_len = is_v and self.transform:GetHeight() or self.transform:GetWidth()
				local scroll_track_range = effective_view_size[axis] - handle_len

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
	end

	local panel = Panel.New{
		Name = "scrollable_panel",
		OnSetProperty = theme.OnSetProperty,
		layout = {
			AlignmentX = "stretch",
			Direction = "y",
			props.layout,
		},
		transform = true,
		gui_element = true,
		mouse_input = {
			Cursor = props.Cursor,
		},
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
	}{
		Panel.New{
			IsInternal = true,
			Name = "viewport",
			OnSetProperty = theme.OnSetProperty,
			Ref = function(s)
				viewport = s
				s:AddLocalListener("OnTransformChanged", update_handle)
				s:AddLocalListener("OnLayoutUpdated", update_handle)
			end,
			gui_element = {
				Clipping = true,
			},
			mouse_input = {
				Cursor = props.Cursor,
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
				Padding = base_padding,
			},
			mouse_input = true,
			clickable = true,
			animation = true,
			OnMouseInput = function(self, button, press, local_pos)
				if not press then return end

				if button == "mwheel_up" or button == "mwheel_down" then
					return handle_wheel_scroll(self, button)
				end
			end,
			OnGlobalMouseInput = function(self, button, press, pos)
				if not press then return end

				if button ~= "mwheel_up" and button ~= "mwheel_down" then return end

				if not self.gui_element or not self.gui_element:IsHovered(pos) then return end

				return handle_wheel_scroll(self, button)
			end,
		},
		create_track("y"),
		create_track("x"),
		create_handle("y"),
		create_handle("x"),
	}

	function panel:GetViewport()
		return viewport
	end

	function panel:ScrollRectIntoView(x1, y1, x2, y2, padding)
		return scroll_rect_into_view(x1, y1, x2, y2, padding)
	end

	function panel:ScrollChildIntoView(child, padding)
		if
			not child or
			not child:IsValid()
			or
			not child.transform or
			not viewport or
			not viewport:IsValid()
		then
			return false
		end

		update_dirty_layout(child)
		update_dirty_layout(panel)
		local current = child
		local x = 0
		local y = 0

		while current and current:IsValid() and current ~= viewport do
			if not current.transform then return false end

			local pos = current.transform:GetPosition()
			x = x + pos.x
			y = y + pos.y
			current = current:GetParent()
		end

		if current ~= viewport then return false end

		local size = child.transform:GetSize()
		return scroll_rect_into_view(x, y, x + size.x, y + size.y, padding)
	end

	if external_ref then external_ref(panel) end

	return panel
end
