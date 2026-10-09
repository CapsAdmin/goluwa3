local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local system = import("goluwa/system.lua")
local META = Panel:CreateTemplate("virtual_grid")
META.Base = ScrollablePanel
META:StartStorable()
META:GetSet("CellWidth", 128)
META:GetSet("ExtraHeight", 32)
META:GetSet("Gap", 8)
META:GetSet("ContentPadding", 8)
META:GetSet("DoubleClickTime", 0.3)
META:GetSet("StretchCells", true)
META:EndStorable()

function META.OnDrawItem(item, index, x, y, width, height, selected, hovered) end

function META.OnHoverItem(item, index) end

function META.OnContextMenu(item, index) end

function META.OnActivate(item, index) end

function META.OnSelect(item, index) end

local function on_content_draw(content)
	content.Grid:draw_items(content)
end

local function on_content_mouse_move(content, local_pos)
	local grid = content.Grid
	local index = grid:get_index_at(local_pos.x, local_pos.y)

	if index ~= grid._hovered_index then
		grid._hovered_index = index
		content.mouse_input:SetCursor(index and "hand" or "arrow")
		grid.OnHoverItem(grid._items[index], index)
	end
end

local function on_content_mouse_leave(content)
	local grid = content.Grid

	if grid._hovered_index then
		grid._hovered_index = nil
		grid.OnHoverItem(nil, nil)
	end
end

local function on_content_mouse_input(content, button, press, local_pos)
	if not press then return end

	if button ~= "button_1" and button ~= "button_2" then return end

	local grid = content.Grid
	local index = grid:get_index_at(local_pos.x, local_pos.y)

	if not index then return end

	grid:SetSelectedIndex(index)

	if button == "button_2" then
		grid.OnContextMenu(grid._items[index], index)
		return true
	end

	local now = system.GetElapsedTime()

	if
		grid._last_click_index == index and
		now - grid._last_click_time <= grid.DoubleClickTime
	then
		grid._last_click_index = nil
		grid.OnActivate(grid._items[index], index)
	else
		grid._last_click_index = index
		grid._last_click_time = now
	end

	return true
end

local function on_content_key_input(content, key, press)
	local grid = content.Grid

	if not press or not grid._selected_index then return end

	local columns = grid._columns
	local target = grid._selected_index
	local page = columns * math.max(1, math.floor(grid.Viewport.transform:GetHeight() / grid._pitch_y))

	if key == "left" then
		target = target - 1
	elseif key == "right" then
		target = target + 1
	elseif key == "up" then
		target = target - columns
	elseif key == "down" then
		target = target + columns
	elseif key == "home" then
		target = 1
	elseif key == "end" then
		target = #grid._items
	elseif key == "page_up" then
		target = target - page
	elseif key == "page_down" then
		target = target + page
	elseif key == "enter" or key == "numpad_enter" then
		grid.OnActivate(grid._items[grid._selected_index], grid._selected_index)
		return true
	else
		return
	end

	grid:SetSelectedIndex(math.clamp(target, 1, #grid._items))
	return true
end

function META.PropDefaults()
	return {ScrollbarShiftMode = "always_shift"}
end

function META:OnCreate()
	self._items = self._items or {}
	META.BaseClass.OnCreate(self)
	self._columns = 1
	self._pitch_x = self.CellWidth + self.Gap
	self._cell_height = self.CellWidth + self.ExtraHeight
	self._pitch_y = self._cell_height + self.Gap
	self._laid_out_width = -1
	self._laid_out_count = -1
	self._laid_out_cell_width = -1
	self._last_click_time = -math.huge
	self._content = Panel.New{
		Parent = self,
		Name = "virtual_grid_content",
		Grid = self,
		transform = true,
		layout = {
			GrowWidth = 1,
			MinSize = Vec2(0, 1),
			MaxSize = Vec2(0, 1),
		},
		visual = true,
		mouse_input = {
			Cursor = "arrow",
			FocusOnClick = true,
		},
		key_input = true,
		OnDraw = on_content_draw,
		OnMouseMove = on_content_mouse_move,
		OnMouseLeave = on_content_mouse_leave,
		OnMouseInput = on_content_mouse_input,
		OnKeyInput = on_content_key_input,
	}
end

function META:SetCellWidth(width)
	self.CellWidth = width

	if self._content then self:relayout() end

	return self
end

function META:GetContentPanel()
	return self._content
end

function META:GetColumns()
	return self._columns
end

function META:GetPitch()
	return self._pitch_x, self._pitch_y
end

function META:GetItems()
	return self._items
end

function META:GetSelectedIndex()
	return self._selected_index
end

function META:GetHoveredIndex()
	return self._hovered_index
end

function META:SetItems(items, keep_scroll)
	self._items = items
	self._selected_index = nil
	self._hovered_index = nil
	self._last_click_index = nil
	self._laid_out_count = -1

	if not self.Viewport then return self end

	if not keep_scroll then self.Viewport.transform:SetScroll(Vec2(0, 0)) end

	self:relayout()
	return self
end

function META:get_index_at(x, y)
	local padding = self.ContentPadding
	local column = math.floor((x - padding) / self._pitch_x)
	local row = math.floor((y - padding) / self._pitch_y)

	if column < 0 or column >= self._columns or row < 0 then return nil end

	local gap = self.Gap

	if (x - padding) - column * self._pitch_x > self._pitch_x - gap then
		return nil
	end

	if (y - padding) - row * self._pitch_y > self._pitch_y - gap then return nil end

	local index = row * self._columns + column + 1

	if index > #self._items then return nil end

	return index
end

function META:relayout()
	local content = self._content
	local width = content.transform:GetWidth()
	local count = #self._items

	if
		width == self._laid_out_width and
		count == self._laid_out_count and
		self.CellWidth == self._laid_out_cell_width
	then
		return
	end

	self._laid_out_width = width
	self._laid_out_count = count
	self._laid_out_cell_width = self.CellWidth
	local padding = self.ContentPadding
	local gap = self.Gap
	local usable = math.max(width - padding * 2, 1)
	self._columns = math.max(1, math.floor((usable + gap) / (self.CellWidth + gap)))
	self._pitch_x = self.StretchCells and (usable + gap) / self._columns or (self.CellWidth + gap)
	self._cell_height = self._pitch_x - gap + self.ExtraHeight
	self._pitch_y = self._cell_height + gap
	local rows = math.ceil(count / self._columns)
	local height = math.max(1, padding * 2 + rows * self._pitch_y - (rows > 0 and gap or 0))
	content.layout:SetMinSize(Vec2(0, height))
	content.layout:SetMaxSize(Vec2(0, height))
end

function META:draw_items(content)
	local _, y1, _, y2 = content.transform:GetVisibleLocalRect()

	if not y1 then return end

	self:relayout()
	local padding = self.ContentPadding
	local columns = self._columns
	local pitch_x = self._pitch_x
	local pitch_y = self._pitch_y
	local items = self._items
	local first = math.max(0, math.floor((y1 - padding) / pitch_y)) * columns + 1
	local last = math.min(#items, (math.floor((y2 - padding) / pitch_y) + 1) * columns)
	local cell_width = pitch_x - self.Gap
	local cell_height = self._cell_height

	for index = first, last do
		local zero = index - 1
		self.OnDrawItem(
			items[index],
			index,
			padding + (zero % columns) * pitch_x,
			padding + math.floor(zero / columns) * pitch_y,
			cell_width,
			cell_height,
			index == self._selected_index,
			index == self._hovered_index
		)
	end
end

function META:GetRange()
	local _, y1, _, y2 = self._content.transform:GetVisibleLocalRect()

	if not y1 then return 1, 0 end

	local padding = self.ContentPadding
	return math.max(1, math.max(0, math.floor((y1 - padding) / self._pitch_y)) * self._columns + 1),
	math.min(#self._items, (math.floor((y2 - padding) / self._pitch_y) + 1) * self._columns)
end

function META:ScrollToIndex(index)
	local zero = index - 1
	local padding = self.ContentPadding
	local x = padding + (zero % self._columns) * self._pitch_x
	local y = padding + math.floor(zero / self._columns) * self._pitch_y
	self:ScrollRectIntoView(x, y, x + self._pitch_x - self.Gap, y + self._cell_height, self.Gap)
	return self
end

function META:SetSelectedIndex(index)
	if index == self._selected_index then return self end

	self._selected_index = index

	if index then
		self:ScrollToIndex(index)
		self.OnSelect(self._items[index], index)
	else
		self.OnSelect(nil, nil)
	end

	return self
end

function META:SelectItem(item)
	for index = 1, #self._items do
		if self._items[index] == item then
			self:SetSelectedIndex(index)
			return self
		end
	end

	return self
end

return META:Register()
