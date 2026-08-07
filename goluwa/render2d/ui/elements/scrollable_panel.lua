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
META.CMP.visual = {}
META.CMP.mouse_input = {}
META.CMP.clickable = {}
META.CMP.animation = {}
META:StartStorable()

META:GetSet("ScrollY", true, function(self, val)
	self.Viewport.layout:SetAlignmentY(val and "start" or "stretch")
	self.Viewport.layout:SetMaxSize(Vec2(self.ScrollX and 1 or 0, val and 1 or 0))
	self.TrackY.visual:SetVisible(val)
	self:updateHandle()
end)

META:GetSet("ScrollX", false, function(self, val)
	self.Viewport.layout:SetAlignmentX(val and "start" or "stretch")
	self.Viewport.layout:SetMaxSize(Vec2(val and 1 or 0, self.ScrollY and 1 or 0))
	self.TrackX.visual:SetVisible(val)
	self:updateHandle()
end)

META:GetSet("ScrollbarVisible", true, function(self, val)
	self:updateHandle()
end)

META:GetSet("ScrollbarAutoHide", true, function(self, val)
	self:updateHandle()
end)

META:GetSet(
	"Direction",
	"y",
	{enums = {"y", "x"}},
	function(self, val)
		self.Viewport.layout:SetDirection(val)
	end
)

META:GetSet(
	"ScrollbarShiftMode",
	"always_shift",
	{
		enums = {"always_shift", "auto_shift", "no_shift"},
	}
)
META:GetSet("ScrollbarReserve", 10)
META:GetSet("CaptureWheelAtExtents", true)

META:GetSet("Padding", Rect(), function(self, val)
	self.Viewport.layout:SetPadding(val)
end)

META:GetSet("Cursor", "arrow", function(self, val)
	self.Viewport.mouse_input:SetCursor(val)
end)

META:EndStorable()

function META:OnCreate(props)
	if props.layout then
		props.layout = table.merge(META.CMP.layout, props.layout)
	end

	self.BaseClass.OnCreate(self, props)
	local scrollable_panel = self
	self.Viewport = Panel.New{
		IsInternal = true,
		Name = "viewport",
		OnTransformChanged = function()
			self:updateHandle()
		end,
		OnLayoutUpdated = function()
			self:updateHandle()
		end,
		visual = {
			Clipping = true,
		},
		mouse_input = true,
		transform = {
			ScrollEnabled = true,
		},
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
			MinSize = Vec2(1, 1),
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
	}
	self:AddChild(self.Viewport)
	self.TrackY = self:AddChild(self:createTrack("y"))
	self.TrackX = self:AddChild(self:createTrack("x"))
	self.HandleY = self:AddChild(self:createHandle("y"))
	self.HandleX = self:AddChild(self:createHandle("x"))
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	self.Viewport:AddChild(child)
	return false
end

function META:PreRemoveChildren()
	self.Viewport:RemoveChildren()
	return false
end

function META:GetViewport()
	return self.Viewport
end

function META:ScrollChildIntoView(child, padding)
	assert(child.transform)
	self:updateDirtyLayout(child)
	self:updateDirtyLayout(self)
	local current = child
	local x = 0
	local y = 0

	while current and current:IsValid() and current ~= self.Viewport do
		if not current.transform then return false end

		local pos = current.transform:GetPosition()
		x = x + pos.x
		y = y + pos.y
		current = current:GetParent()
	end

	if current ~= self.Viewport then return false end

	local size = child.transform:GetSize()
	return self:ScrollRectIntoView(x, y, x + size.x, y + size.y, padding)
end

-- Scrollbar state computation
function META:computeScrollbarState(content_size, view_size)
	content_size = content_size or Vec2(0, 0)
	view_size = view_size or Vec2(0, 0)
	local always_shift_v = self.ScrollbarShiftMode == "always_shift" and
		self.ScrollY and
		self.ScrollbarVisible
	local always_shift_h = self.ScrollbarShiftMode == "always_shift" and
		self.ScrollX and
		self.ScrollbarVisible
	local auto_shift = self.ScrollbarShiftMode == "auto_shift"
	local show_y = false
	local show_x = false
	local reserve_y = always_shift_v
	local reserve_x = always_shift_h

	if auto_shift then
		for _ = 1, 2 do
			local available_w = math.max(0, view_size.x - (show_y and self.ScrollbarReserve or 0))
			local available_h = math.max(0, view_size.y - (show_x and self.ScrollbarReserve or 0))
			local can_scroll_v = content_size.y > available_h
			local can_scroll_h = content_size.x > available_w
			show_y = self.ScrollY and
				self.ScrollbarVisible and
				(
					not self.ScrollbarAutoHide or
					can_scroll_v
				)
			show_x = self.ScrollX and
				self.ScrollbarVisible and
				(
					not self.ScrollbarAutoHide or
					can_scroll_h
				)
		end

		reserve_y = show_y
		reserve_x = show_x
	else
		local can_scroll_v = content_size.y > view_size.y
		local can_scroll_h = content_size.x > view_size.x
		show_y = self.ScrollY and
			self.ScrollbarVisible and
			(
				not self.ScrollbarAutoHide or
				can_scroll_v
			)
		show_x = self.ScrollX and
			self.ScrollbarVisible and
			(
				not self.ScrollbarAutoHide or
				can_scroll_h
			)
	end

	return {
		content_size = content_size,
		view_size = view_size,
		show_y = show_y,
		show_x = show_x,
		reserve_y = reserve_y,
		reserve_x = reserve_x,
		available_w = math.max(0, view_size.x - (reserve_y and self.ScrollbarReserve or 0)),
		available_h = math.max(0, view_size.y - (reserve_x and self.ScrollbarReserve or 0)),
	}
end

-- Scrollbar handle update
function META:updateHandle()
	if not self.HandleY or not self.HandleX then return end

	local content_size = self.Viewport.layout.content_size
	local view_size = self.Viewport.transform.Size:Copy()
	local state = self:computeScrollbarState(content_size, view_size)
	-- Update viewport padding for scrollbar reserve
	local new_padding = Rect(
		self.Padding.x,
		self.Padding.y,
		self.Padding.w + (
				state.reserve_y and
				self.ScrollbarReserve or
				0
			),
		self.Padding.h + (
				state.reserve_x and
				self.ScrollbarReserve or
				0
			)
	)
	local current_padding = self.Viewport.layout:GetPadding()

	if
		not current_padding or
		current_padding.x ~= new_padding.x or
		current_padding.y ~= new_padding.y or
		current_padding.w ~= new_padding.w or
		current_padding.h ~= new_padding.h
	then
		self.Viewport.layout:SetPadding(new_padding)
		-- Recompute after layout may have shifted available dimensions
		view_size = self.Viewport.transform.Size:Copy()
		content_size = self.Viewport.layout.content_size
		state = self:computeScrollbarState(content_size, view_size)
	end

	if not content_size or not view_size then
		self:clampScrollToBounds(Vec2(0, 0), Vec2(0, 0))
		self.TrackY.visual:SetVisible(false)
		self.TrackX.visual:SetVisible(false)
		self.HandleY.visual:SetVisible(false)
		self.HandleX.visual:SetVisible(false)
		return
	end

	local scroll = self:clampScrollToBounds(content_size, view_size) or
		self.Viewport.transform:GetScroll()
	self:updateScrollbarAxis("y", state, scroll, content_size, view_size, self.Padding)
	self:updateScrollbarAxis("x", state, scroll, content_size, view_size, self.Padding)
end

function META:updateScrollbarAxis(axis, state, scroll, content_size, view_size, base_padding)
	local is_y = axis == "y"
	local handle = is_y and self.HandleY or self.HandleX
	local track = is_y and self.TrackY or self.TrackX
	local show = is_y and state.show_y or state.show_x
	local available = is_y and state.available_h or state.available_w
	local content_dim = content_size[axis]
	local scroll_dim = scroll[axis]

	if not show then
		if track then track.visual:SetVisible(false) end

		handle.visual:SetVisible(false)
		return
	end

	local max_scroll_view = math.max(1, available)
	local max_scroll = math.max(0, content_dim - max_scroll_view)

	if track then
		track.visual:SetVisible(true)

		if is_y then
			track.transform:SetSize(Vec2(6, available))
			track.transform:SetPosition(Vec2(self.transform:GetSize().x - 8, base_padding.y))
		else
			track.transform:SetSize(Vec2(available, 6))
			track.transform:SetPosition(Vec2(base_padding.x, self.transform:GetSize().y - 8))
		end
	end

	handle.visual:SetVisible(true)
	local ratio = math.min(1, max_scroll_view / math.max(content_dim, 1))
	local handle_len = math.max(20, available * ratio)
	local track_len = available
	local scroll_track_range = track_len - handle_len
	local handle_pos = 0

	if max_scroll > 0 then
		handle_pos = (scroll_dim / max_scroll) * scroll_track_range
	end

	if is_y then
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
	local scroll = self.Viewport.transform:GetScroll():Copy()
	local next_scroll = scroll:Copy()
	local max_scroll_x = math.max(0, (content_size and content_size.x or 0) - effective_view_size.x)
	local max_scroll_y = math.max(0, (content_size and content_size.y or 0) - effective_view_size.y)

	if self.ScrollX then
		next_scroll.x = math.clamp(next_scroll.x, 0, max_scroll_x)
	else
		next_scroll.x = 0
	end

	if self.ScrollY then
		next_scroll.y = math.clamp(next_scroll.y, 0, max_scroll_y)
	else
		next_scroll.y = 0
	end

	local changed = next_scroll.x ~= scroll.x or next_scroll.y ~= scroll.y

	if changed then self.Viewport.transform:SetScroll(next_scroll) end

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

	if (self.ScrollX and not self.ScrollY) or (self.ScrollX and is_shift) then
		local max_scroll = math.max(0, content_size.x - effective_view_size.x)

		if max_scroll <= 0 then return self.CaptureWheelAtExtents end

		next_scroll.x = math.clamp(scroll.x - delta, 0, max_scroll)
	else
		local max_scroll = math.max(0, content_size.y - effective_view_size.y)

		if max_scroll <= 0 then return self.CaptureWheelAtExtents end

		next_scroll.y = math.clamp(scroll.y - delta, 0, max_scroll)
	end

	if next_scroll.x == scroll.x and next_scroll.y == scroll.y then
		return self.CaptureWheelAtExtents
	end

	target.transform:SetScroll(next_scroll)
	return true
end

-- Scroll-into-view helpers
function META:ScrollRectIntoView(x1, y1, x2, y2, padding)
	padding = padding or self.Padding
	local content_size = self.Viewport.layout and self.Viewport.layout.content_size
	local view_size = self.Viewport.transform and self.Viewport.transform.Size

	if not content_size or not view_size then return false end

	local state = self:computeScrollbarState(content_size, view_size)
	local effective_view_size = Vec2(state.available_w, state.available_h)
	local scroll = self.Viewport.transform:GetScroll():Copy()
	local next_scroll = scroll:Copy()
	local pad = padding

	if type(padding) == "number" then
		pad = Rect(padding, padding, padding, padding)
	elseif not padding or not padding.x then
		pad = Rect(0, 0, 0, 0)
	end

	if self.ScrollX then
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

	if self.ScrollY then
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

	self.Viewport.transform:SetScroll(next_scroll)
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
		return Panel.New{
			IsInternal = true,
			Name = "scrollbar_track_" .. axis,
			Ref = function(s)
				s:SetState("color", self.TrackColor or "scrollbar_track")
			end,
			transform = {
				Size = axis == "y" and
					Vec2(theme.active:GetSize("M"), 40) or
					Vec2(40, theme.active:GetSize("M")),
			},
			visual = {
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
		local is_y = axis == "y"
		local scrollable_panel = self
		return Panel.New{
			IsInternal = true,
			Name = "scrollbar_handle_" .. axis,
			OnTransformChanged = function()
				self:updateHandle()
			end,
			Ref = function(s)
				s:SetState("color", scrollable_panel.HandleColor or "scrollbar")
			end,
			transform = {
				Size = is_y and
					Vec2(theme.active:GetSize("M"), 40) or
					Vec2(40, theme.active:GetSize("M")),
			},
			visual = {
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
				local content_size = scrollable_panel.Viewport.layout.content_size
				local view_size = scrollable_panel.Viewport.transform.Size

				if not content_size or not view_size then return end

				local state = scrollable_panel:computeScrollbarState(content_size, view_size)
				local effective_view_size = Vec2(state.available_w, state.available_h)
				local max_scroll = content_size[axis] - effective_view_size[axis]

				if max_scroll <= 0 then return end

				local handle_len = is_y and self.transform:GetHeight() or self.transform:GetWidth()
				local base_padding = scrollable_panel.Padding
				local track_len = is_y and
					(
						effective_view_size.y - base_padding.y - base_padding.h
					)
					or
					(
						effective_view_size.x - base_padding.x - base_padding.w
					)
				local scroll_track_range = track_len - handle_len

				if scroll_track_range <= 0 then return end

				local scroll = scrollable_panel.Viewport.transform:GetScroll():Copy()
				scroll[axis] = (self.scroll_start or 0) + (delta[axis] / scroll_track_range) * max_scroll
				scroll[axis] = math.clamp(scroll[axis], 0, max_scroll)
				scrollable_panel.Viewport.transform:SetScroll(scroll)
				return true
			end,
			OnDragStarted = function(self)
				self.scroll_start = scrollable_panel.Viewport.transform:GetScroll()[axis]
			end,
		}
	end
end

META:Register()
return META.New
