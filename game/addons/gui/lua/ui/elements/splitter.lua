local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
local timer = import("goluwa/timer.lua")
return function(props)
	local external_ref = props.Ref

	if external_ref then
		props = table.shallow_copy(props)
		props.Ref = nil
	end

	local divider_width = props.DividerWidth or 6
	local initial_size = props.InitialSize or props.InitialWidth or props.InitialHeight or 220
	local min_split_size = props.MinSplitSize or 50
	local is_vertical = props.Vertical or false
	props.InitialWidth = nil
	props.InitialHeight = nil
	props.InitialSize = nil
	props.DividerWidth = nil
	props.MinSplitSize = nil
	props.Vertical = nil
	local splitter
	local divider
	local state = {
		is_dragging = false,
		is_hovered = false,
		size = initial_size,
		drag_start_mouse = nil,
		drag_start_size = initial_size,
	}

	local function get_first_panel()
		for _, child in ipairs(splitter:GetChildren()) do
			if not child.IsInternal then return child end
		end

		return nil
	end

	local function get_second_panel()
		local found_first = false

		for _, child in ipairs(splitter:GetChildren()) do
			if not child.IsInternal then
				if found_first then return child end

				found_first = true
			end
		end

		return nil
	end

	local function get_split_limits()
		local min_size = min_split_size
		local max_size = math.huge
		local first_panel = get_first_panel()
		local second_panel = get_second_panel()
		local divider_size = divider_width
		local current_total = nil

		if divider and divider.transform then
			local size = divider.transform:GetSize()
			divider_size = is_vertical and size.y or size.x
		end

		if first_panel and first_panel.transform and second_panel and second_panel.transform then
			local first_size = is_vertical and
				first_panel.transform:GetHeight() or
				first_panel.transform:GetWidth()
			local second_size = is_vertical and
				second_panel.transform:GetHeight() or
				second_panel.transform:GetWidth()
			current_total = first_size + divider_size + second_size
		elseif splitter and splitter.transform then
			local splitter_size = splitter.transform:GetSize()
			current_total = is_vertical and splitter_size.y or splitter_size.x
		end

		if current_total then
			local second_min_size = 0

			if second_panel and second_panel.layout then
				local min = second_panel.layout:GetMinSize()
				second_min_size = is_vertical and min.y or min.x
			end

			local available = current_total - divider_size - second_min_size
			max_size = math.max(min_size, available)
		end

		return min_size, max_size
	end

	local function apply_size(new_size, emit_change)
		local min_size, max_size = get_split_limits()
		state.size = math.clamp(new_size, min_size, max_size)
		local first_panel = get_first_panel()

		if first_panel and first_panel.layout then
			if is_vertical then
				first_panel.layout:SetMinSize(Vec2(0, state.size))
				first_panel.layout:SetMaxSize(Vec2(0, state.size))
			else
				first_panel.layout:SetMinSize(Vec2(state.size, 0))
				first_panel.layout:SetMaxSize(Vec2(state.size, 0))
			end

			first_panel.layout:InvalidateLayout(true)
		end

		if emit_change and props.OnChange then props.OnChange(state.size, splitter) end
	end

	splitter = Panel.New{
		props,
		{
			Name = is_vertical and "VerticalSplitter" or "HorizontalSplitter",
			OnSetProperty = theme.OnSetProperty,
			layout = {
				Direction = is_vertical and "y" or "x",
				GrowWidth = 1,
				GrowHeight = 1,
				ChildGap = 0,
				AlignmentX = is_vertical and "stretch" or nil,
				AlignmentY = is_vertical and nil or "stretch",
				props.layout,
			},
			PreChildAdd = function(self, child)
				if child.IsInternal then return true end

				local children = self:GetChildren()
				local actual_children_count = 0

				for _, c in ipairs(children) do
					if not c.IsInternal then actual_children_count = actual_children_count + 1 end
				end

				if actual_children_count >= 2 then
					error("Splitter can only have 2 children, but attempted to add a third")
				end

				if actual_children_count == 0 then
					-- First child is the left/top panel
					if child.layout then
						if is_vertical then
							child.layout:SetMinSize(Vec2(0, initial_size))
							child.layout:SetMaxSize(Vec2(0, initial_size))
							child.layout:SetGrowHeight(0)
							child.layout:SetGrowWidth(1)
							child.layout:SetFitHeight(false)
						else
							child.layout:SetMinSize(Vec2(initial_size, 0))
							child.layout:SetMaxSize(Vec2(initial_size, 0))
							child.layout:SetGrowWidth(0)
							child.layout:SetGrowHeight(1)
							child.layout:SetFitWidth(false)
						end
					end
				elseif actual_children_count == 1 then
					-- Second child is the right/bottom panel
					if child.layout then
						child.layout:SetGrowWidth(1)
						child.layout:SetGrowHeight(1)
					end

					self:AddChild(divider, 2)
				end

				return true
			end,
			PreRemoveChildren = function(self)
				local children = self:GetChildren()

				for i = #children, 1, -1 do
					local child = children[i]

					if not child.IsInternal then
						child:UnParent()
						child:Remove()
					end
				end

				return false
			end,
			transform = true,
			gui_element = true,
			mouse_input = true,
			clickable = true,
			animation = true,
		},
	}
	divider = Panel.New{
		IsInternal = true,
		Name = "Divider",
		OnSetProperty = theme.OnSetProperty,
		transform = {
			Size = is_vertical and Vec2(0, divider_width) or Vec2(divider_width, 0),
		},
		layout = {
			GrowHeight = is_vertical and 0 or 1,
			GrowWidth = is_vertical and 1 or 0,
		},
		mouse_input = {
			Cursor = is_vertical and "vertical_resize" or "horizontal_resize",
			OnHover = function(self, hovered)
				state.is_hovered = hovered
			end,
			OnMouseInput = function(self, button, press, local_pos)
				if button == "button_1" then
					state.is_dragging = press

					if press then
						state.drag_start_mouse = self.Owner.mouse_input:GetGlobalMousePosition():Copy()
						state.drag_start_size = state.size
					else
						state.drag_start_mouse = nil
					end

					return true
				end
			end,
			OnGlobalMouseInput = function(self, button, press)
				if button == "button_1" and not press and state.is_dragging then
					state.is_dragging = false
					state.drag_start_mouse = nil
				end
			end,
			OnGlobalMouseMove = function(self, pos)
				if state.is_dragging then
					local drag_start_mouse = state.drag_start_mouse or pos
					local delta = pos - drag_start_mouse
					local new_size = state.drag_start_size + (is_vertical and delta.y or delta.x)
					apply_size(new_size, true)
					self:SetCursor(is_vertical and "vertical_resize" or "horizontal_resize")
					return true
				end

				if self:GetHovered() then
					self:SetCursor(is_vertical and "vertical_resize" or "horizontal_resize")
					return true
				end
			end,
		},
		gui_element = {
			OnDraw = function(self)
				theme.active:DrawDivider(theme.GetDrawContext(self))
			end,
		},
		animation = true,
		clickable = true,
	}

	function splitter:SetSplitSize(size, emit_change)
		apply_size(size, emit_change == true)
		return self
	end

	function splitter:GetSplitSize()
		return state.size
	end

	if external_ref then external_ref(splitter) end

	return splitter
end
