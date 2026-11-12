local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local input = import("goluwa/input.lua")
local META = Panel:CreateTemplate("tree_table")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	GrowHeight = 1,
	FitHeight = false,
	AlignmentX = "stretch",
}
META.CMP.visual = {}
META:StartStorable()
META:GetSet("Mode", "tree")
META:GetSet("SortKey", nil)
META:GetSet("SortDescending", false)
META:GetSet("FoldersFirst", true)
META:GetSet("ShowHeader", true)
META:GetSet("AlternateRows", true)
META:GetSet("RowHeight", nil)
META:GetSet("IndentSize", "XL")
META:GetSet("DoubleClickTime", 0.3)
META:EndStorable()
META:GetSet("Columns", nil)
META:GetSet("Items", nil)
META:GetSet("SelectedKey", nil)
local MIN_COLUMN_WIDTH = 40
local MIN_GROW_WIDTH = 80
local RESIZE_GRAB = 4
local SCROLL_RETRIES = 10
local ICON_NAMES = {folder = "folder", folder_open = "folder_open", file = "file"}

function META.OnGetChildren(node)
	return node.Children
end

function META.OnGetCell(node, column)
	return node[column.Key]
end

function META.OnSelect(node) end

function META.OnActivate(node) end

function META.OnContextMenu(node) end

function META.OnToggle(node, expanded) end

function META.OnSort(column, descending) end

local function get_key(node)
	local key = node.Key

	if key == nil then return node end

	return key
end

local function draw_text(font, text, x, y, color)
	render2d.SetTexture(nil)
	render2d.PushColor(color.r, color.g, color.b, 1)
	render2d.PushAlphaMultiplier(color.a)
	font:DrawText(text, x, y, 0)
	render2d.PopAlphaMultiplier()
	render2d.PopColor()
end

local icon_box = Vec2()

local function draw_icon(name, x, y, size, color)
	icon_box.x = size
	icon_box.y = size
	render2d.PushMatrix()
	render2d.Translatef(x, y)
	theme.active:DrawIcon(name, icon_box, {color = color, inset = 0})
	render2d.PopMatrix()
end

local function get_icon_size()
	return theme.active:ResolveSize("icon")
end

local function get_row_height(self)
	if self.RowHeight then return theme.active:ResolveSize(self.RowHeight) end

	return get_icon_size() + theme.active:ResolveSize("XXS") * 2
end

local function on_header_draw(header)
	header.Table:draw_header(header)
end

local function on_header_mouse_move(header, local_pos)
	local self = header.Table
	local divider = self:get_divider_at(local_pos.x)
	local column = not divider and self:get_column_at(local_pos.x) or nil
	self._hovered_header = column
	header.mouse_input:SetCursor(divider and "horizontal_resize" or "arrow")
end

local function on_header_mouse_leave(header)
	header.Table._hovered_header = nil
end

local function on_header_mouse_input(header, button, press, local_pos)
	if button ~= "button_1" or not press then return end

	local self = header.Table
	local divider = self:get_divider_at(local_pos.x)

	if divider then
		self._resize = {
			index = divider,
			grow_index = self._grow_index,
			start_x = system.GetWindow():GetMousePosition().x,
			widths = {table.unpack(self._widths)},
		}
		return true
	end

	local column = self:get_column_at(local_pos.x)

	if column and column.Sortable ~= false then
		self:SetSort(column.Key, self.SortKey == column.Key and not self.SortDescending)
	end

	return true
end

local function on_content_draw(content)
	content.Table:draw_rows(content)
end

local function on_content_mouse_move(content, local_pos)
	local self = content.Table
	local index = self:get_row_at(local_pos.y)

	if index ~= self._hovered_index then self._hovered_index = index end
end

local function on_content_mouse_leave(content)
	content.Table._hovered_index = nil
end

local function on_content_mouse_input(content, button, press, local_pos)
	if not press then return end

	if button ~= "button_1" and button ~= "button_2" then return end

	local self = content.Table
	local index = self:get_row_at(local_pos.y)

	if not index then return end

	local row = self._rows[index]

	if
		button == "button_1" and
		self.Mode == "tree" and
		self:is_foldable(row.node) and
		local_pos.x >= self:get_toggle_x(row.depth)
		and
		local_pos.x < self:get_toggle_x(row.depth) + self:get_toggle_size()
	then
		self:Toggle(row.node)
		return true
	end

	self:SetSelectedIndex(index)

	if button == "button_2" then
		self.OnContextMenu(row.node)
		return true
	end

	local now = system.GetUnscaledElapsedTime()

	if
		self._last_click_index == index and
		now - self._last_click_time <= self.DoubleClickTime
	then
		self._last_click_index = nil
		self:activate(row.node)
	else
		self._last_click_index = index
		self._last_click_time = now
	end

	return true
end

local function on_content_key_input(content, key, press)
	local self = content.Table

	if not press or not self._selected_index then return end

	local row = self._rows[self._selected_index]
	local target = self._selected_index
	local page = math.max(1, math.floor(self._scroll.Viewport.transform:GetHeight() / get_row_height(self)))

	if key == "up" then
		target = target - 1
	elseif key == "down" then
		target = target + 1
	elseif key == "home" then
		target = 1
	elseif key == "end" then
		target = #self._rows
	elseif key == "page_up" then
		target = target - page
	elseif key == "page_down" then
		target = target + page
	elseif key == "right" and self.Mode == "tree" then
		if self:is_foldable(row.node) and not self:IsExpanded(row.node) then
			self:Expand(row.node)
			return true
		end

		target = target + 1
	elseif key == "left" and self.Mode == "tree" then
		if self:is_foldable(row.node) and self:IsExpanded(row.node) then
			self:Collapse(row.node)
			return true
		end

		for index = target - 1, 1, -1 do
			if self._rows[index].depth < row.depth then
				target = index

				break
			end
		end
	elseif key == "enter" or key == "numpad_enter" then
		self:activate(row.node)
		return true
	else
		return
	end

	self:SetSelectedIndex(math.clamp(target, 1, #self._rows))
	return true
end

function META:OnCreate()
	self._rows = {}
	self._expanded = {}
	self._sorted = {}
	self._sort_serial = 0
	self._cache = setmetatable({}, {__mode = "k"})
	self._widths = {}
	self._overrides = {}
	self._positions = {}
	self._last_click_time = -math.huge
	self.Items = self.Items or {}
	self.Columns = self.Columns or {{Key = "Text", Text = "Name", Grow = true}}
	META.BaseClass.OnCreate(self)
	self._header = Panel.New{
		Parent = self,
		Name = "tree_table_header",
		Table = self,
		transform = true,
		visual = true,
		mouse_input = {Cursor = "arrow"},
		layout = {
			GrowWidth = 1,
			MinSize = Vec2(0, self.ShowHeader and get_row_height(self) or 0),
			MaxSize = Vec2(0, self.ShowHeader and get_row_height(self) or 0),
		},
		OnDraw = on_header_draw,
		OnMouseMove = on_header_mouse_move,
		OnMouseLeave = on_header_mouse_leave,
		OnMouseInput = on_header_mouse_input,
	}
	self._scroll = ScrollablePanel{
		Parent = self,
		ScrollX = false,
		ScrollY = true,
		ScrollbarShiftMode = "always_shift",
		Padding = Rect(),
		layout = {GrowWidth = 1, GrowHeight = 1},
	}
	self._content = Panel.New{
		Parent = self._scroll,
		Name = "tree_table_content",
		Table = self,
		transform = true,
		visual = true,
		mouse_input = {Cursor = "arrow", FocusOnClick = true},
		key_input = true,
		layout = {GrowWidth = 1, MinSize = Vec2(0, 1), MaxSize = Vec2(0, 1)},
		OnDraw = on_content_draw,
		OnMouseMove = on_content_mouse_move,
		OnMouseLeave = on_content_mouse_leave,
		OnMouseInput = on_content_mouse_input,
		OnKeyInput = on_content_key_input,
	}
	self:AddGlobalEvent("Update")
	self._ready = true
	self:rebuild_rows()
end

function META:OnUpdate()
	if self._pending_scroll then
		local index = self._selected_index

		if not index then
			self._pending_scroll = nil
		else
			local row_height = get_row_height(self)
			local scrolled = self._scroll:ScrollRectIntoView(0, (index - 1) * row_height, 1, index * row_height, 0)
			self._pending_scroll = not scrolled and self._pending_scroll > 1 and self._pending_scroll - 1 or nil
		end
	end

	if self._resize and not input.IsMouseDown("button_1") then self._resize = nil end

	if self._resize then
		self:resize_column(self._resize, system.GetWindow():GetMousePosition().x - self._resize.start_x)
	end
end

function META:resize_column(resize, delta)
	local target = resize.index

	if resize.grow_index and resize.grow_index <= resize.index then
		target = resize.index + 1
		delta = -delta
	end

	local column = self.Columns[target]
	local start = resize.widths[target]
	local minimum = column.MinWidth or MIN_COLUMN_WIDTH
	local maximum = math.huge

	if resize.grow_index then
		local grow = self.Columns[resize.grow_index]
		maximum = start + resize.widths[resize.grow_index] - (grow.MinWidth or MIN_GROW_WIDTH)
	end

	self._overrides[column.Key] = math.clamp(start + delta, minimum, math.max(maximum, minimum))
end

function META:GetContentPanel()
	return self._content
end

function META:is_foldable(node)
	if node.HasChildren ~= nil then return node.HasChildren end

	return node.IsFolder == true
end

function META:get_toggle_size()
	return get_icon_size()
end

function META:get_toggle_x(depth)
	return 4 + depth * theme.active:ResolveSize(self.IndentSize)
end

function META:SetColumns(columns)
	self.Columns = columns

	if self._ready then self._cache = setmetatable({}, {__mode = "k"}) end

	return self
end

function META:SetItems(items)
	self.Items = items

	if not self._ready then return self end

	self._sorted = {}
	self._sort_serial = self._sort_serial + 1
	self._hovered_index = nil
	self._last_click_index = nil
	self:rebuild_rows()
	return self
end

function META:SetMode(mode)
	self.Mode = mode

	if self._ready then self:rebuild_rows() end

	return self
end

function META:SetSort(key, descending)
	self.SortKey = key
	self.SortDescending = descending == true

	if not self._ready then return self end

	self._sort_serial = self._sort_serial + 1
	self:rebuild_rows()

	for _, column in ipairs(self.Columns) do
		if column.Key == key then
			self.OnSort(column, self.SortDescending)

			break
		end
	end

	return self
end

function META:get_column(key)
	for _, column in ipairs(self.Columns) do
		if column.Key == key then return column end
	end
end

do
	local function get_sort_value(self, column, node)
		local value = column.SortValue and column.SortValue(node) or self.OnGetCell(node, column)

		if type(value) == "string" then return string.natural_key(value) end

		return value or 0
	end

	function META:get_sorted(parent_key, nodes)
		local cached = self._sorted[parent_key]

		if cached and cached.serial == self._sort_serial and cached.source == nodes then
			return cached.list
		end

		local column = self.SortKey and self:get_column(self.SortKey)
		local folders_first = self.FoldersFirst
		local decorated = {}

		for index, node in ipairs(nodes) do
			decorated[index] = {
				node = node,
				index = index,
				folder = folders_first and self:is_foldable(node) or false,
				value = column and get_sort_value(self, column, node) or nil,
			}
		end

		local descending = self.SortDescending

		table.sort(decorated, function(a, b)
			if a.folder ~= b.folder then return a.folder end

			if a.value ~= nil and a.value ~= b.value then
				if type(a.value) ~= type(b.value) then
					return tostring(a.value) < tostring(b.value)
				end

				if descending then return a.value > b.value end

				return a.value < b.value
			end

			return a.index < b.index
		end)

		local sorted = {}

		for index, entry in ipairs(decorated) do
			sorted[index] = entry.node
		end

		self._sorted[parent_key] = {serial = self._sort_serial, source = nodes, list = sorted}
		return sorted
	end
end

function META:rebuild_rows()
	local rows = {}
	local tree = self.Mode == "tree"

	local function add(nodes, parent_key, depth)
		for _, node in ipairs(self:get_sorted(parent_key, nodes)) do
			rows[#rows + 1] = {node = node, depth = depth}

			if tree and self:is_foldable(node) and self._expanded[get_key(node)] then
				local children = self.OnGetChildren(node)

				if children then add(children, node, depth + 1) end
			end
		end
	end

	add(self.Items, self, 0)
	self._rows = rows
	local wanted = self._selected_key
	self._selected_index = nil

	if wanted ~= nil then
		for index, row in ipairs(rows) do
			if get_key(row.node) == wanted then
				self._selected_index = index
				self._pending_scroll = SCROLL_RETRIES

				break
			end
		end
	end

	if self._content then
		local height = math.max(1, #rows * get_row_height(self))
		self._content.layout:SetMinSize(Vec2(0, height))
		self._content.layout:SetMaxSize(Vec2(0, height))
	end
end

function META:IsExpanded(node)
	return self._expanded[get_key(node)] == true
end

function META:Expand(node)
	if self:IsExpanded(node) then return self end

	self._expanded[get_key(node)] = true
	self.OnToggle(node, true)
	self:rebuild_rows()
	return self
end

function META:Collapse(node)
	if not self:IsExpanded(node) then return self end

	self._expanded[get_key(node)] = nil
	self.OnToggle(node, false)
	self:rebuild_rows()
	return self
end

function META:Toggle(node)
	if self:IsExpanded(node) then return self:Collapse(node) end

	return self:Expand(node)
end

function META:activate(node)
	if self.Mode == "tree" and self:is_foldable(node) then self:Toggle(node) end

	self.OnActivate(node)
end

function META:GetRows()
	return self._rows
end

function META:GetSelectedNode()
	local row = self._selected_index and self._rows[self._selected_index]
	return row and row.node
end

function META:SetSelectedKey(key)
	self._selected_key = key

	if not self._ready then return self end

	self._selected_index = nil
	self._pending_scroll = SCROLL_RETRIES

	for index, row in ipairs(self._rows) do
		if get_key(row.node) == key then
			self._selected_index = index

			break
		end
	end

	return self
end

function META:GetSelectedKey()
	return self._selected_key
end

function META:GetSelectedIndex()
	return self._selected_index
end

function META:SetSelectedIndex(index)
	if index == self._selected_index then return self end

	self._selected_index = index

	if index then
		local row = self._rows[index]
		self._selected_key = get_key(row.node)
		local row_height = get_row_height(self)
		self._scroll:ScrollRectIntoView(0, (index - 1) * row_height, 1, index * row_height, 0)
		self.OnSelect(row.node)
	else
		self._selected_key = nil
		self.OnSelect(nil)
	end

	return self
end

function META:SelectNode(node)
	self._selected_key = get_key(node)

	for index, row in ipairs(self._rows) do
		if get_key(row.node) == self._selected_key then
			self._selected_index = index
			local row_height = get_row_height(self)
			self._scroll:ScrollRectIntoView(0, (index - 1) * row_height, 1, index * row_height, 0)
			return self
		end
	end

	self._selected_index = nil
	return self
end

-- the rows drawn now, for automation: {node, index, text, x, y, w, h} with screen rects
function META:GetDrawnItems()
	local out = {}
	local content = self._scroll and self:GetContentPanel()
	local _, y1, _, y2 = content and content.transform:GetVisibleLocalRect()

	if not y1 then return out end

	local row_height = get_row_height(self)
	local width = content.transform:GetWidth()

	for index = math.max(1, math.floor(y1 / row_height) + 1), math.min(#self._rows, math.floor(y2 / row_height) + 1) do
		local node = self._rows[index].node
		local pos = content.transform:LocalToGlobal(Vec2(0, (index - 1) * row_height))
		out[#out + 1] = {
			node = node,
			index = index,
			text = node.Text,
			x = pos.x,
			y = pos.y,
			w = width,
			h = row_height,
		}
	end

	return out
end

function META:get_row_at(y)
	local index = math.floor(y / get_row_height(self)) + 1

	if index < 1 or index > #self._rows then return nil end

	return index
end

function META:update_columns(width)
	local columns = self.Columns
	local fixed = 0
	local grow_index

	for index, column in ipairs(columns) do
		if column.Grow and not grow_index then
			grow_index = index
		else
			self._widths[index] = self._overrides[column.Key] or column.Width or 100
			fixed = fixed + self._widths[index]
		end
	end

	if grow_index then
		self._widths[grow_index] = math.max(columns[grow_index].MinWidth or 80, width - fixed)
	end

	local x = 0

	for index = 1, #columns do
		self._positions[index] = x
		x = x + self._widths[index]
	end

	self._grow_index = grow_index
end

function META:get_column_at(x)
	for index = 1, #self.Columns do
		if x >= self._positions[index] and x < self._positions[index] + self._widths[index] then
			return self.Columns[index], index
		end
	end
end

function META:get_divider_at(x)
	for index = 1, #self.Columns - 1 do
		if math.abs(x - (self._positions[index] + self._widths[index])) <= RESIZE_GRAB then
			return index
		end
	end
end

function META:draw_header(header)
	local size = header.transform:GetSize()
	local active = theme.active
	local font = active:GetFont("body_strong", "S")
	local border = active:GetColor("border")
	local text_color = active:GetColor("text")
	local disabled = active:GetColor("text_disabled")
	self:update_columns(self._content.transform:GetWidth())
	active:DrawRoundRect(0, 0, size.x, size.y, 0, active:GetColor("surface_alt"), 1)
	local _, text_height = font:GetTextSize("Ag")
	local icon_size = math.floor(size.y * 0.5)

	for index, column in ipairs(self.Columns) do
		local x, width = self._positions[index], self._widths[index]

		if self._hovered_header == column then
			active:DrawRoundRect(x, 0, width, size.y, 0, active:GetColor("primary"), 0.12)
		end

		local text_x = x + 8
		local avail = width - 16
		local sorted = self.SortKey == column.Key

		if sorted then avail = avail - icon_size - 2 end

		local text = font:ElideText(column.Text, math.max(avail, 1))
		local text_width = font:GetTextSize(text)
		draw_text(font, text, text_x, (size.y - text_height) / 2, sorted and text_color or disabled)

		if sorted then
			draw_icon(
				self.SortDescending and "chevron_down" or "chevron_up",
				text_x + text_width + 2,
				(size.y - icon_size) / 2,
				icon_size,
				text_color
			)
		end

		if index < #self.Columns then
			active:DrawRoundRect(x + width - 1, 3, 1, size.y - 6, 0, border, 0.7)
		end
	end

	active:DrawRoundRect(0, size.y - 1, size.x, 1, 0, border, 1)
end

function META:draw_rows(content)
	local _, y1, _, y2 = content.transform:GetVisibleLocalRect()

	if not y1 then return end

	local active = theme.active
	local font = active:GetFont("body", "S")
	local text_color = active:GetColor("text")
	local disabled = active:GetColor("text_disabled")
	local folder_color = active:GetColor("yellow")
	local selected_color = active:GetColor("primary")
	local alternate_color = active:GetColor("surface_alt")
	local width = content.transform:GetWidth()
	local row_height = get_row_height(self)
	local rows = self._rows
	local first = math.max(1, math.floor(y1 / row_height) + 1)
	local last = math.min(#rows, math.floor(y2 / row_height) + 1)
	local tree = self.Mode == "tree"
	local toggle_size = self:get_toggle_size()
	local icon_size = get_icon_size()
	local _, text_height = font:GetTextSize("Ag")
	local text_y = (row_height - text_height) / 2
	local cache = self._cache
	self:update_columns(width)

	for index = first, last do
		local row = rows[index]
		local node = row.node
		local y = (index - 1) * row_height
		local selected = index == self._selected_index

		if selected then
			active:DrawRoundRect(0, y, width, row_height, 0, selected_color, 0.35)
		elseif index == self._hovered_index then
			active:DrawRoundRect(0, y, width, row_height, 0, selected_color, 0.15)
		elseif self.AlternateRows and index % 2 == 0 then
			active:DrawRoundRect(0, y, width, row_height, 0, alternate_color, 0.35)
		end

		local node_cache = cache[node]

		if not node_cache then
			node_cache = {}
			cache[node] = node_cache
		end

		for column_index, column in ipairs(self.Columns) do
			local x, column_width = self._positions[column_index], self._widths[column_index]
			local text_x = x + 8
			local avail = column_width - 16

			if column_index == 1 then
				text_x = x + self:get_toggle_x(tree and row.depth or 0)

				if tree then
					if self:is_foldable(node) then
						draw_icon(
							self._expanded[get_key(node)] and "chevron_down" or "chevron_right",
							text_x + (toggle_size - icon_size) / 2,
							y + (row_height - icon_size) / 2,
							icon_size,
							disabled
						)
					end

					text_x = text_x + toggle_size
				end

				local foldable = self:is_foldable(node)
				local icon = node.Icon

				if type(icon) == "function" then
					icon = icon(node, self._expanded[get_key(node)] == true)
				end

				icon = icon or
					(
						foldable and
						(
							self._expanded[get_key(node)] and
							"folder_open" or
							"folder"
						)
						or
						"file"
					)
				draw_icon(
					icon,
					text_x,
					y + (row_height - icon_size) / 2,
					icon_size,
					foldable and folder_color or disabled
				)
				text_x = text_x + icon_size + 6
				avail = x + column_width - 8 - text_x
			end

			if column.Draw then
				column.Draw(node, x, y, column_width, row_height)
			else
				local raw = self.OnGetCell(node, column)
				local text = raw == nil and "" or tostring(column.Format and column.Format(raw, node) or raw)
				local cell = node_cache[column_index]

				if not cell or cell.text ~= text or cell.width ~= avail then
					cell = {text = text, width = avail, elided = font:ElideText(text, math.max(avail, 1))}
					node_cache[column_index] = cell
				end

				draw_text(
					font,
					cell.elided,
					text_x,
					y + text_y,
					column_index == 1 and text_color or disabled
				)
			end
		end
	end
end

return META:Register()
