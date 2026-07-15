local Panel = import("goluwa/render2d/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local input = import("goluwa/input.lua")
local META = Panel:CreateTemplate("scrollable_panel")
META.CMP.transform = {}
META.CMP.layout = {
	AlignmentX = "stretch",
	Direction = "y",
}
META.CMP.gui_element = {}
META.CMP.mouse_input = {}
META.CMP.clickable = {}
META.CMP.animation = {}

function META:OnCreate(props)
	if props.layout then
		props.layout = table.merge(META.CMP.layout, props.layout)
	end

	self.BaseClass.OnCreate(self, props)
	self.scrollableScrollV = props.ScrollY ~= false
	self.scrollableScrollH = props.ScrollX == true
	self.scrollableScrollbarVisible = props.ScrollBarVisible ~= false
	self.scrollableScrollbarAutoHide = props.ScrollBarAutoHide ~= false
	self.scrollableScrollbarShiftMode = props.ScrollBarContentShiftMode or "always_shift"
	self.scrollableScrollbarReserve = props.ScrollBarReserve or 10
	self.scrollableCaptureWheelAtExtents = props.CaptureWheelAtExtents == true
	local padding = props.Padding

	if type(padding) == "string" then
		self.scrollableBasePadding = Rect() + theme.active:GetPadding(padding)
	elseif type(padding) == "number" then
		self.scrollableBasePadding = Rect() + padding
	elseif padding then
		self.scrollableBasePadding = padding:Copy()
	else
		self.scrollableBasePadding = Rect(0, 0, 0, 0)
	end

	self.scrollableViewport = nil
	self.scrollableTrackV = nil
	self.scrollableTrackH = nil
	self.scrollableHandleV = nil
	self.scrollableHandleH = nil

	if
		self.scrollableScrollbarShiftMode ~= "no_shift" and
		self.scrollableScrollbarShiftMode ~= "auto_shift" and
		self.scrollableScrollbarShiftMode ~= "always_shift"
	then
		self.scrollableScrollbarShiftMode = "always_shift"
	end

	local scrollable_panel = self
	local viewport = Panel.New{
		IsInternal = true,
		Name = "viewport",
		Ref = function(s)
			self.scrollableViewport = s

			s:AddLocalListener("OnTransformChanged", function()
				self:updateHandle()
			end)

			s:AddLocalListener("OnLayoutUpdated", function()
				self:updateHandle()
			end)
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
			AlignmentX = self.scrollableScrollH and "start" or "stretch",
			AlignmentY = self.scrollableScrollV and "start" or "stretch",
			MinSize = Vec2(1, 1),
			MaxSize = Vec2(self.scrollableScrollH and 1 or 0, self.scrollableScrollV and 1 or 0),
			Padding = self.scrollableBasePadding,
		},
		mouse_input = true,
		clickable = true,
		animation = true,
		OnMouseInput = function(self, button, press, local_pos)
			if not press then return end

			if button == "mwheel_up" or button == "mwheel_down" then
				return scrollable_panel:handleWheelScroll(self, button)
			end
		end,
		OnGlobalMouseInput = function(self, button, press, pos)
			if not press then return end

			if button ~= "mwheel_up" and button ~= "mwheel_down" then return end

			if not self.gui_element or not self.gui_element:IsHovered(pos) then return end

			return scrollable_panel:handleWheelScroll(self, button)
		end,
	}
	self:AddChild(viewport)
	self:AddChild(self:createTrack("y"))
	self:AddChild(self:createTrack("x"))
	self:AddChild(self:createHandle("y"))
	self:AddChild(self:createHandle("x"))
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	self.scrollableViewport:AddChild(child)
	return false
end

function META:PreRemoveChildren()
	self.scrollableViewport:RemoveChildren()
	return false
end

-- Public API
function META:GetViewport()
	return self.scrollableViewport
end

function META:ScrollRectIntoView(x1, y1, x2, y2, padding)
	return self:scrollRectIntoView(x1, y1, x2, y2, padding)
end

function META:ScrollChildIntoView(child, padding)
	assert(child.transform)
	self:updateDirtyLayout(child)
	self:updateDirtyLayout(self)
	local current = child
	local x = 0
	local y = 0

	while current and current:IsValid() and current ~= self.scrollableViewport do
		if not current.transform then return false end

		local pos = current.transform:GetPosition()
		x = x + pos.x
		y = y + pos.y
		current = current:GetParent()
	end

	if current ~= self.scrollableViewport then return false end

	local size = child.transform:GetSize()
	return self:scrollRectIntoView(x, y, x + size.x, y + size.y, padding)
end

-- Scrollbar state computation
function META:computeScrollbarState(content_size, view_size)
	content_size = content_size or Vec2(0, 0)
	view_size = view_size or Vec2(0, 0)
	local always_shift_v = self.scrollableScrollbarShiftMode == "always_shift" and
		self.scrollableScrollV and
		self.scrollableScrollbarVisible
	local always_shift_h = self.scrollableScrollbarShiftMode == "always_shift" and
		self.scrollableScrollH and
		self.scrollableScrollbarVisible
	local auto_shift = self.scrollableScrollbarShiftMode == "auto_shift"
	local show_v = false
	local show_h = false
	local reserve_v = always_shift_v
	local reserve_h = always_shift_h

	if auto_shift then
		for _ = 1, 2 do
			local available_w = math.max(0, view_size.x - (show_v and self.scrollableScrollbarReserve or 0))
			local available_h = math.max(0, view_size.y - (show_h and self.scrollableScrollbarReserve or 0))
			local can_scroll_v = content_size.y > available_h
			local can_scroll_h = content_size.x > available_w
			show_v = self.scrollableScrollV and
				self.scrollableScrollbarVisible and
				(
					not self.scrollableScrollbarAutoHide or
					can_scroll_v
				)
			show_h = self.scrollableScrollH and
				self.scrollableScrollbarVisible and
				(
					not self.scrollableScrollbarAutoHide or
					can_scroll_h
				)
		end

		reserve_v = show_v
		reserve_h = show_h
	else
		local can_scroll_v = content_size.y > view_size.y
		local can_scroll_h = content_size.x > view_size.x
		show_v = self.scrollableScrollV and
			self.scrollableScrollbarVisible and
			(
				not self.scrollableScrollbarAutoHide or
				can_scroll_v
			)
		show_h = self.scrollableScrollH and
			self.scrollableScrollbarVisible and
			(
				not self.scrollableScrollbarAutoHide or
				can_scroll_h
			)
	end

	return {
		content_size = content_size,
		view_size = view_size,
		show_v = show_v,
		show_h = show_h,
		reserve_v = reserve_v,
		reserve_h = reserve_h,
		available_w = math.max(0, view_size.x - (reserve_v and self.scrollableScrollbarReserve or 0)),
		available_h = math.max(0, view_size.y - (reserve_h and self.scrollableScrollbarReserve or 0)),
	}
end

-- Scrollbar handle update
function META:updateHandle()
	if not self.scrollableHandleV or not self.scrollableHandleH then return end

	local content_size = self.scrollableViewport.layout.content_size
	local view_size = self.scrollableViewport.transform.Size:Copy()
	local state = self:computeScrollbarState(content_size, view_size)
	-- Update viewport padding for scrollbar reserve
	local new_padding = Rect(
		self.scrollableBasePadding.x,
		self.scrollableBasePadding.y,
		self.scrollableBasePadding.w + (
				state.reserve_v and
				self.scrollableScrollbarReserve or
				0
			),
		self.scrollableBasePadding.h + (
				state.reserve_h and
				self.scrollableScrollbarReserve or
				0
			)
	)
	local current_padding = self.scrollableViewport.layout:GetPadding()

	if
		not current_padding or
		current_padding.x ~= new_padding.x or
		current_padding.y ~= new_padding.y or
		current_padding.w ~= new_padding.w or
		current_padding.h ~= new_padding.h
	then
		self.scrollableViewport.layout:SetPadding(new_padding)
		-- Recompute after layout may have shifted available dimensions
		view_size = self.scrollableViewport.transform.Size:Copy()
		content_size = self.scrollableViewport.layout.content_size
		state = self:computeScrollbarState(content_size, view_size)
	end

	if false then
		print(self.transform:GetSize(), content_size, view_size)
		table.print(state)
	end

	if not content_size or not view_size then
		self:clampScrollToBounds(Vec2(0, 0), Vec2(0, 0))
		self.scrollableTrackV.gui_element:SetVisible(false)
		self.scrollableTrackH.gui_element:SetVisible(false)
		self.scrollableHandleV.gui_element:SetVisible(false)
		self.scrollableHandleH.gui_element:SetVisible(false)
		return
	end

	local scroll = self:clampScrollToBounds(content_size, view_size) or
		self.scrollableViewport.transform:GetScroll()
	self:updateScrollbarAxis("y", state, scroll, content_size, view_size, self.scrollableBasePadding)
	self:updateScrollbarAxis("x", state, scroll, content_size, view_size, self.scrollableBasePadding)
end

function META:updateScrollbarAxis(axis, state, scroll, content_size, view_size, base_padding)
	local is_v = axis == "y"
	local handle = is_v and self.scrollableHandleV or self.scrollableHandleH
	local track = is_v and self.scrollableTrackV or self.scrollableTrackH
	local show = is_v and state.show_v or state.show_h
	local available = is_v and state.available_h or state.available_w
	local content_dim = content_size[axis]
	local scroll_dim = scroll[axis]

	if not show then
		if track then track.gui_element:SetVisible(false) end

		handle.gui_element:SetVisible(false)
		return
	end

	local max_scroll_view = math.max(1, available)
	local max_scroll = math.max(0, content_dim - max_scroll_view)

	if track then
		track.gui_element:SetVisible(true)

		if is_v then
			track.transform:SetSize(Vec2(6, available))
			track.transform:SetPosition(Vec2(self.transform:GetSize().x - 8, base_padding.y))
		else
			track.transform:SetSize(Vec2(available, 6))
			track.transform:SetPosition(Vec2(base_padding.x, self.transform:GetSize().y - 8))
		end
	end

	handle.gui_element:SetVisible(true)
	local ratio = math.min(1, max_scroll_view / math.max(content_dim, 1))
	local handle_len = math.max(20, available * ratio)
	local track_len = available
	local scroll_track_range = track_len - handle_len
	local handle_pos = 0

	if max_scroll > 0 then
		handle_pos = (scroll_dim / max_scroll) * scroll_track_range
	end

	if is_v then
		handle.transform:SetSize(Vec2(6, handle_len))
		handle.transform:SetPosition(Vec2(self.transform:GetSize().x - 8, handle_pos + base_padding.y))
	else
		handle.transform:SetSize(Vec2(handle_len, 6))
		handle.transform:SetPosition(Vec2(handle_pos + base_padding.x, self.transform:GetSize().y - 8))
	end
end

function META:clampScrollToBounds(content_size, view_size)
	local state = self:computeScrollbarState(content_size, view_size)
	local effective_view_size = Vec2(state.available_w, state.available_h)
	local scroll = self.scrollableViewport.transform:GetScroll():Copy()
	local next_scroll = scroll:Copy()
	local max_scroll_x = math.max(0, (content_size and content_size.x or 0) - effective_view_size.x)
	local max_scroll_y = math.max(0, (content_size and content_size.y or 0) - effective_view_size.y)

	if self.scrollableScrollH then
		next_scroll.x = math.clamp(next_scroll.x, 0, max_scroll_x)
	else
		next_scroll.x = 0
	end

	if self.scrollableScrollV then
		next_scroll.y = math.clamp(next_scroll.y, 0, max_scroll_y)
	else
		next_scroll.y = 0
	end

	local changed = next_scroll.x ~= scroll.x or next_scroll.y ~= scroll.y

	if changed then self.scrollableViewport.transform:SetScroll(next_scroll) end

	return next_scroll, changed
end

-- Wheel scrolling
function META:handleWheelScroll(target, button)
	local content_size = target.layout and target.layout.content_size
	local view_size = target.transform and target.transform.Size

	if not content_size or not view_size then return end

	local state = self:computeScrollbarState(content_size, view_size)
	local effective_view_size = Vec2(state.available_w, state.available_h)
	local scroll = target.transform:GetScroll():Copy()
	local next_scroll = scroll:Copy()
	local delta = (button == "mwheel_up" and -40 or 40)
	local is_shift = input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift")

	if
		(
			self.scrollableScrollH and
			not self.scrollableScrollV
		)
		or
		(
			self.scrollableScrollH and
			is_shift
		)
	then
		local max_scroll = math.max(0, content_size.x - effective_view_size.x)

		if max_scroll <= 0 then return self.scrollableCaptureWheelAtExtents end

		next_scroll.x = math.clamp(scroll.x - delta, 0, max_scroll)
	else
		local max_scroll = math.max(0, content_size.y - effective_view_size.y)

		if max_scroll <= 0 then return self.scrollableCaptureWheelAtExtents end

		next_scroll.y = math.clamp(scroll.y - delta, 0, max_scroll)
	end

	if next_scroll.x == scroll.x and next_scroll.y == scroll.y then
		return self.scrollableCaptureWheelAtExtents
	end

	target.transform:SetScroll(next_scroll)
	return true
end

-- Scroll-into-view helpers
function META:scrollRectIntoView(x1, y1, x2, y2, padding)
	padding = padding or self.scrollableBasePadding
	local content_size = self.scrollableViewport.layout and self.scrollableViewport.layout.content_size
	local view_size = self.scrollableViewport.transform and self.scrollableViewport.transform.Size

	if not content_size or not view_size then return false end

	local state = self:computeScrollbarState(content_size, view_size)
	local effective_view_size = Vec2(state.available_w, state.available_h)
	local scroll = self.scrollableViewport.transform:GetScroll():Copy()
	local next_scroll = scroll:Copy()
	local pad = padding

	if type(padding) == "number" then
		pad = Rect(padding, padding, padding, padding)
	elseif not padding or not padding.x then
		pad = Rect(0, 0, 0, 0)
	end

	if self.scrollableScrollH then
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

	if self.scrollableScrollV then
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

	self.scrollableViewport.transform:SetScroll(next_scroll)
	return true
end

function META:updateDirtyLayout(entity)
	local current = entity
	local root_layout = nil

	while current and current:IsValid() do
		local layout = current.layout

		if layout and layout:GetDirty() then root_layout = layout end

		current = current:GetParent()
	end

	if root_layout then root_layout:UpdateLayout() end
end

-- Track and handle creation
do
	function META:createTrack(axis)
		local is_v = axis == "y"
		return Panel.New{
			IsInternal = true,
			Name = "scrollbar_track_" .. axis,
			Ref = function(s)
				if is_v then self.scrollableTrackV = s else self.scrollableTrackH = s end

				s:SetState("color", self.scrollableTrackColor or "scrollbar_track")
			end,
			transform = {
				Size = is_v and
					Vec2(theme.active:GetSize("M"), 40) or
					Vec2(40, theme.active:GetSize("M")),
			},
			gui_element = {
				Visible = false,
				OnDraw = function(self)
					theme.active:Draw(self.Owner)
				end,
			},
			layout = {
				Floating = true,
			},
		}
	end

	function META:createHandle(axis)
		local is_v = axis == "y"
		local scrollable_panel = self
		return Panel.New{
			IsInternal = true,
			Name = "scrollbar_handle_" .. axis,
			Ref = function(s)
				if is_v then
					scrollable_panel.scrollableHandleV = s
				else
					scrollable_panel.scrollableHandleH = s
				end

				s:SetState("color", scrollable_panel.scrollableHandleColor or "scrollbar")

				s:AddLocalListener("OnTransformChanged", function()
					scrollable_panel:updateHandle()
				end)
			end,
			transform = {
				Size = is_v and
					Vec2(theme.active:GetSize("M"), 40) or
					Vec2(40, theme.active:GetSize("M")),
			},
			gui_element = {
				Visible = false,
				OnDraw = function(self)
					theme.active:Draw(self.Owner)
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
				local content_size = scrollable_panel.scrollableViewport.layout.content_size
				local view_size = scrollable_panel.scrollableViewport.transform.Size

				if not content_size or not view_size then return end

				local state = scrollable_panel:computeScrollbarState(content_size, view_size)
				local effective_view_size = Vec2(state.available_w, state.available_h)
				local max_scroll = content_size[axis] - effective_view_size[axis]

				if max_scroll <= 0 then return end

				local handle_len = is_v and self.transform:GetHeight() or self.transform:GetWidth()
				local base_padding = scrollable_panel.scrollableBasePadding
				local track_len = is_v and
					(
						effective_view_size.y - base_padding.y - base_padding.h
					)
					or
					(
						effective_view_size.x - base_padding.x - base_padding.w
					)
				local scroll_track_range = track_len - handle_len

				if scroll_track_range <= 0 then return end

				local scroll = scrollable_panel.scrollableViewport.transform:GetScroll():Copy()
				scroll[axis] = (self.scroll_start or 0) + (delta[axis] / scroll_track_range) * max_scroll
				scroll[axis] = math.clamp(scroll[axis], 0, max_scroll)
				scrollable_panel.scrollableViewport.transform:SetScroll(scroll)
				return true
			end,
			OnDragStarted = function(self)
				self.scroll_start = scrollable_panel.scrollableViewport.transform:GetScroll()[axis]
			end,
		}
	end
end

META:Register()
return META.New
