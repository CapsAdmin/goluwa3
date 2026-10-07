local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
return function(props)
	local items = props.Items or {}
	local cell_width = props.CellWidth or 128
	local cell_extra_height = props.ExtraHeight or 32
	local cell_height = cell_width + cell_extra_height
	local gap = props.Gap or 8
	local padding = props.ContentPadding or 8
	local double_click_time = props.DoubleClickTime or 0.3
	local columns = 1
	local pitch_x = cell_width + gap
	local pitch_y = cell_height + gap
	local laid_out_width = -1
	local laid_out_count = -1
	local laid_out_cell_width = -1
	local selected_index
	local hovered_index
	local last_click_index
	local last_click_time = -math.huge
	local content
	local grid

	local function get_index_at(x, y)
		local column = math.floor((x - padding) / pitch_x)
		local row = math.floor((y - padding) / pitch_y)

		if column < 0 or column >= columns or row < 0 then return nil end

		local cell_x = (x - padding) - column * pitch_x

		if cell_x > pitch_x - gap then return nil end

		local cell_y = (y - padding) - row * pitch_y

		if cell_y > pitch_y - gap then return nil end

		local index = row * columns + column + 1

		if index > #items then return nil end

		return index
	end

	local function relayout()
		local width = content.transform:GetWidth()

		if
			width == laid_out_width and
			#items == laid_out_count and
			cell_width == laid_out_cell_width
		then
			return
		end

		laid_out_width = width
		laid_out_count = #items
		laid_out_cell_width = cell_width
		local usable = math.max(width - padding * 2, 1)
		columns = math.max(1, math.floor((usable + gap) / (cell_width + gap)))
		pitch_x = props.StretchCells == false and (cell_width + gap) or (usable + gap) / columns
		cell_height = pitch_x - gap + cell_extra_height
		pitch_y = cell_height + gap
		local rows = math.ceil(#items / columns)
		local height = math.max(1, padding * 2 + rows * pitch_y - (rows > 0 and gap or 0))
		content.layout:SetMinSize(Vec2(0, height))
		content.layout:SetMaxSize(Vec2(0, height))
	end

	content = Panel.New{
		Name = "VirtualGridContent",
		transform = true,
		layout = {
			GrowWidth = 1,
			MinSize = Vec2(0, 1),
			MaxSize = Vec2(0, 1),
		},
		visual = {
			OnDraw = function(self)
				if not props.OnDrawItem then return end

				local _, y1, _, y2 = self.Owner.transform:GetVisibleLocalRect()

				if not y1 then return end

				relayout()
				local first_row = math.max(0, math.floor((y1 - padding) / pitch_y))
				local last_row = math.floor((y2 - padding) / pitch_y)
				local first = first_row * columns + 1
				local last = math.min(#items, (last_row + 1) * columns)
				local cell_draw_width = pitch_x - gap

				for index = first, last do
					local zero = index - 1
					props.OnDrawItem(
						items[index],
						index,
						padding + (zero % columns) * pitch_x,
						padding + math.floor(zero / columns) * pitch_y,
						cell_draw_width,
						cell_height,
						index == selected_index,
						index == hovered_index
					)
				end
			end,
		},
		mouse_input = {
			Cursor = "arrow",
			FocusOnClick = true,
		},
		key_input = true,
		OnMouseMove = function(self, local_pos)
			local index = get_index_at(local_pos.x, local_pos.y)

			if index ~= hovered_index then
				hovered_index = index
				self.mouse_input:SetCursor(index and "hand" or "arrow")

				if props.OnHoverItem then props.OnHoverItem(items[index], index) end
			end
		end,
		OnMouseLeave = function()
			if hovered_index then
				hovered_index = nil

				if props.OnHoverItem then props.OnHoverItem(nil, nil) end
			end
		end,
		OnMouseInput = function(self, button, press, local_pos)
			if not press then return end

			if button ~= "button_1" and button ~= "button_2" then return end

			local index = get_index_at(local_pos.x, local_pos.y)

			if not index then return end

			grid:SetSelectedIndex(index)

			if button == "button_2" then
				if props.OnContextMenu then props.OnContextMenu(items[index], index) end

				return true
			end

			local now = system.GetElapsedTime()

			if last_click_index == index and now - last_click_time <= double_click_time then
				last_click_index = nil

				if props.OnActivate then props.OnActivate(items[index], index) end
			else
				last_click_index = index
				last_click_time = now
			end

			return true
		end,
		OnKeyInput = function(self, key, press)
			if not press or not selected_index then return end

			local target = selected_index

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
				target = #items
			elseif key == "page_up" then
				target = target - columns * math.max(1, math.floor(grid:GetViewport().transform:GetHeight() / pitch_y))
			elseif key == "page_down" then
				target = target + columns * math.max(1, math.floor(grid:GetViewport().transform:GetHeight() / pitch_y))
			elseif key == "enter" or key == "numpad_enter" then
				if props.OnActivate then
					props.OnActivate(items[selected_index], selected_index)
				end

				return true
			else
				return
			end

			grid:SetSelectedIndex(math.clamp(target, 1, #items))
			return true
		end,
	}
	grid = ScrollablePanel{
		Padding = Rect(),
		ScrollX = false,
		ScrollY = true,
		layout = props.layout,
		Key = props.Key,
		Ref = props.Ref,
	}
	grid:AddChild(content)

	function grid:SetItems(next_items, keep_scroll)
		items = next_items
		selected_index = nil
		hovered_index = nil
		last_click_index = nil
		laid_out_count = -1

		if not keep_scroll then self.Viewport.transform:SetScroll(Vec2(0, 0)) end

		relayout()
		return self
	end

	function grid:GetItems()
		return items
	end

	function grid:SetCellWidth(width)
		cell_width = width
		relayout()
		return self
	end

	function grid:GetColumns()
		return columns
	end

	function grid:GetPitch()
		return pitch_x, pitch_y
	end

	function grid:GetSelectedIndex()
		return selected_index
	end

	function grid:GetHoveredIndex()
		return hovered_index
	end

	function grid:GetRange()
		local _, y1, _, y2 = content.transform:GetVisibleLocalRect()

		if not y1 then return 1, 0 end

		return math.max(1, math.max(0, math.floor((y1 - padding) / pitch_y)) * columns + 1),
		math.min(#items, (math.floor((y2 - padding) / pitch_y) + 1) * columns)
	end

	function grid:ScrollToIndex(index)
		local zero = index - 1
		local x = padding + (zero % columns) * pitch_x
		local y = padding + math.floor(zero / columns) * pitch_y
		self:ScrollRectIntoView(x, y, x + pitch_x - gap, y + cell_height, gap)
		return self
	end

	function grid:SetSelectedIndex(index)
		if index == selected_index then return self end

		selected_index = index

		if index then
			self:ScrollToIndex(index)

			if props.OnSelect then props.OnSelect(items[index], index) end
		elseif props.OnSelect then
			props.OnSelect(nil, nil)
		end

		return self
	end

	function grid:SelectItem(item)
		for index = 1, #items do
			if items[index] == item then
				self:SetSelectedIndex(index)
				return self
			end
		end

		return self
	end

	function grid:GetContentPanel()
		return content
	end

	return grid
end
