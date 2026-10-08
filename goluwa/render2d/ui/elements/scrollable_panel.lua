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
	self:update_handle()
end)

META:GetSet("ScrollX", false, function(self, val)
	self.Viewport.layout:SetAlignmentX(val and "start" or "stretch")
	self.Viewport.layout:SetMaxSize(Vec2(val and 1 or 0, self.ScrollY and 1 or 0))
	self.TrackX.visual:SetVisible(val)
	self:update_handle()
end)

META:GetSet("ScrollbarVisible", true, function(self, val)
	self:update_handle()
end)

META:GetSet("ScrollbarAutoHide", true, function(self, val)
	self:update_handle()
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
	"auto",
	{
		enums = {"auto", "always_shift", "auto_shift", "no_shift"},
	}
)
META:GetSet("ScrollbarReserve", nil)
META:GetSet("CaptureWheelAtExtents", true)

META:GetSet("Padding", Rect(), function(self, val)
	self.Viewport.layout:SetPadding(val)
end)

META:GetSet("Cursor", "arrow", function(self, val)
	self.Viewport.mouse_input:SetCursor(val)
end)

META:EndStorable()

local function on_viewport_changed(viewport)
	viewport.Scrollable:update_handle()
end

local function on_viewport_mouse_input(viewport, button, press)
	if not press then return end

	if button == "mwheel_up" or button == "mwheel_down" then
		return viewport.Scrollable:handle_wheel_scroll(viewport, button)
	end
end

local function on_track_draw(track)
	theme.active:Draw(track)
end

local function on_handle_changed(handle)
	handle.Scrollable:update_handle()
end

local function on_handle_drag_started(handle)
	handle._scroll_start = handle.Scrollable.Viewport.transform:GetScroll()[handle.Axis]
end

local function on_handle_drag(handle, delta)
	local scrollable = handle.Scrollable
	local axis = handle.Axis
	local viewport = scrollable.Viewport
	local content_size = viewport.layout.content_size
	local view_size = viewport.transform.Size

	if not content_size or not view_size then return end

	local state = scrollable:compute_scrollbar_state(content_size, view_size)
	local effective_view_size = Vec2(state.available_w, state.available_h)
	local max_scroll = content_size[axis] - effective_view_size[axis]

	if max_scroll <= 0 then return end

	local is_y = axis == "y"
	local handle_len = is_y and handle.transform:GetHeight() or handle.transform:GetWidth()
	local track_len = math.max(0, effective_view_size[axis] - theme.active:GetScrollbarMargin() * 2)
	local scroll_track_range = track_len - handle_len

	if scroll_track_range <= 0 then return end

	local scroll = viewport.transform:GetScroll():Copy()
	scroll[axis] = math.clamp(
		(handle._scroll_start or 0) + (delta[axis] / scroll_track_range) * max_scroll,
		0,
		max_scroll
	)
	viewport.transform:SetScroll(scroll)
	return true
end

function META:OnCreate(props)
	META.BaseClass.OnCreate(self, props)
	self.ScrollbarReserve = theme.active:ResolveSize(
		props.ScrollbarReserve or
			(
				theme.active:GetScrollbarWidth() + theme.active:GetScrollbarMargin()
			)
	)
	self.Viewport = Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "viewport",
		Scrollable = self,
		visual = {Clipping = true},
		transform = {ScrollEnabled = true},
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
			MinSize = Vec2(1, 1),
		},
		mouse_input = {Cursor = self.Cursor},
		clickable = true,
		animation = true,
		OnTransformChanged = on_viewport_changed,
		OnLayoutUpdated = on_viewport_changed,
		OnMouseInput = on_viewport_mouse_input,
	}
	self.TrackY = self:create_track("y")
	self.TrackX = self:create_track("x")
	self.HandleY = self:create_handle("y")
	self.HandleX = self:create_handle("x")
	self:apply_scroll_configuration()
end

function META:apply_scroll_configuration()
	local layout = self.Viewport.layout
	layout:SetDirection(self.Direction)
	layout:SetAlignmentX(self.ScrollX and "start" or "stretch")
	layout:SetAlignmentY(self.ScrollY and "start" or "stretch")
	layout:SetMaxSize(Vec2(self.ScrollX and 1 or 0, self.ScrollY and 1 or 0))
	layout:SetPadding(self.Padding)
	self.TrackY.visual:SetVisible(self.ScrollY)
	self.TrackX.visual:SetVisible(self.ScrollX)
	self:update_handle()
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
	self:update_dirty_layout(child)
	self:update_dirty_layout(self)
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

function META:compute_scrollbar_state(content_size, view_size)
	content_size = content_size or Vec2(0, 0)
	view_size = view_size or Vec2(0, 0)
	local mode_y = self.ScrollbarShiftMode
	local mode_x = mode_y

	if mode_y == "auto" then
		local panel_size = self.transform.Size
		local threshold = theme.active:GetScrollbarAutoShiftSize()
		mode_y = panel_size.x >= threshold and "auto_shift" or "no_shift"
		mode_x = panel_size.y >= threshold and "auto_shift" or "no_shift"
	end

	local enabled_y = self.ScrollY and self.ScrollbarVisible
	local enabled_x = self.ScrollX and self.ScrollbarVisible
	local shift_y = mode_y == "auto_shift"
	local shift_x = mode_x == "auto_shift"
	local show_y = false
	local show_x = false
	local reserve_y = mode_y == "always_shift" and enabled_y
	local reserve_x = mode_x == "always_shift" and enabled_x

	for _ = 1, 2 do
		local available_w = math.max(0, view_size.x - (show_y and shift_y and self.ScrollbarReserve or 0))
		local available_h = math.max(0, view_size.y - (show_x and shift_x and self.ScrollbarReserve or 0))
		show_y = enabled_y and (not self.ScrollbarAutoHide or content_size.y > available_h)
		show_x = enabled_x and (not self.ScrollbarAutoHide or content_size.x > available_w)
	end

	if shift_y then reserve_y = show_y end

	if shift_x then reserve_x = show_x end

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

function META:update_handle()
	if not self.HandleY or not self.HandleX then return end

	local content_size = self.Viewport.layout.content_size
	local view_size = self.Viewport.transform.Size:Copy()
	local state = self:compute_scrollbar_state(content_size, view_size)
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
		view_size = self.Viewport.transform.Size:Copy()
		content_size = self.Viewport.layout.content_size
		state = self:compute_scrollbar_state(content_size, view_size)
	end

	if not content_size or not view_size then
		self:clamp_scroll_to_bounds(Vec2(0, 0), Vec2(0, 0))
		self.TrackY.visual:SetVisible(false)
		self.TrackX.visual:SetVisible(false)
		self.HandleY.visual:SetVisible(false)
		self.HandleX.visual:SetVisible(false)
		return
	end

	local scroll = self:clamp_scroll_to_bounds(content_size, view_size) or
		self.Viewport.transform:GetScroll()
	self:update_scrollbar_axis("y", state, scroll, content_size, view_size)
	self:update_scrollbar_axis("x", state, scroll, content_size, view_size)
end

function META:update_scrollbar_axis(axis, state, scroll, content_size, view_size)
	local is_y = axis == "y"
	local handle = is_y and self.HandleY or self.HandleX
	local track = is_y and self.TrackY or self.TrackX
	local show = state.show_x

	if is_y then show = state.show_y end

	local margin = theme.active:GetScrollbarMargin()
	local available = math.max(0, (is_y and state.available_h or state.available_w) - margin * 2)
	local content_dim = content_size[axis]
	local scroll_dim = scroll[axis]

	if not show then
		if track then track.visual:SetVisible(false) end

		handle.visual:SetVisible(false)
		return
	end

	local max_scroll_view = math.max(1, is_y and state.available_h or state.available_w)
	local max_scroll = math.max(0, content_dim - max_scroll_view)
	local sb_width = theme.active:GetScrollbarWidth()
	local sb_offset = sb_width + margin

	if track then
		track.visual:SetVisible(true)

		if is_y then
			track.transform:SetSize(Vec2(sb_width, available))
			track.transform:SetPosition(Vec2(self.transform:GetSize().x - sb_offset, margin))
		else
			track.transform:SetSize(Vec2(available, sb_width))
			track.transform:SetPosition(Vec2(margin, self.transform:GetSize().y - sb_offset))
		end
	end

	handle.visual:SetVisible(true)
	local ratio = math.min(1, max_scroll_view / math.max(content_dim, 1))
	local handle_len = math.max(theme.active:GetSize("L"), available * ratio)
	local track_len = available
	local scroll_track_range = track_len - handle_len
	local handle_pos = 0

	if max_scroll > 0 then
		handle_pos = (scroll_dim / max_scroll) * scroll_track_range
	end

	if is_y then
		handle.transform:SetSize(Vec2(sb_width, handle_len))
		handle.transform:SetPosition(Vec2(self.transform:GetSize().x - sb_offset, handle_pos + margin))
	else
		handle.transform:SetSize(Vec2(handle_len, sb_width))
		handle.transform:SetPosition(Vec2(handle_pos + margin, self.transform:GetSize().y - sb_offset))
	end
end

function META:clamp_scroll_to_bounds(content_size, view_size)
	local state = self:compute_scrollbar_state(content_size, view_size)
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

function META:handle_wheel_scroll(target, button)
	local content_size = target.layout and target.layout.content_size
	local view_size = target.transform and target.transform.Size

	if not content_size or not view_size then return end

	local state = self:compute_scrollbar_state(content_size, view_size)
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

function META:ScrollRectIntoView(x1, y1, x2, y2, padding)
	padding = padding or self.Padding
	local content_size = self.Viewport.layout and self.Viewport.layout.content_size
	local view_size = self.Viewport.transform and self.Viewport.transform.Size

	if not content_size or not view_size then return false end

	local state = self:compute_scrollbar_state(content_size, view_size)
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

function META:update_dirty_layout(entity)
	local current = entity
	local root_layout = nil

	while current and current:IsValid() do
		local layout = current.layout

		if layout and layout:GetDirty() then root_layout = layout end

		current = current:GetParent()
	end

	if root_layout then root_layout:UpdateLayout() end
end

function META:create_track(axis)
	local width = theme.active:GetScrollbarWidth()
	return Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "scrollbar_track_" .. axis,
		transform = {
			Size = axis == "y" and Vec2(width, 40) or Vec2(40, width),
		},
		visual = {Visible = false},
		layout = {Floating = true},
		OnDraw = on_track_draw,
	}
end

function META:create_handle(axis)
	local width = theme.active:GetScrollbarWidth()
	local handle = Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "scrollbar_handle_" .. axis,
		Scrollable = self,
		Axis = axis,
		transform = {
			Size = axis == "y" and Vec2(width, 40) or Vec2(40, width),
		},
		visual = {Visible = false},
		layout = {Floating = true},
		draggable = true,
		mouse_input = true,
		clickable = true,
		animation = true,
		OnDraw = on_track_draw,
		OnTransformChanged = on_handle_changed,
		OnDrag = on_handle_drag,
		OnDragStarted = on_handle_drag_started,
	}
	return handle
end

return META:Register()
