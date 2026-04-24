local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local Panel = import("goluwa/ecs/panel.lua")
local system = import("goluwa/system.lua")
local Text = import("lua/ui/elements/text.lua")
local theme = import("lua/ui/theme.lua")

local function has_entries(list)
	return list and next(list) ~= nil
end

local function build_path(parent_path, index)
	if parent_path then return parent_path .. "/" .. index end

	return tostring(index)
end

return function(props)
	local external_ref = props.Ref

	if external_ref then
		props = table.shallow_copy(props)
		props.Ref = nil
	end

	local items = props.Items or {}
	local selected_key = props.SelectedKey
	local expanded_state = {}
	local row_infos = {}
	local row_order = {}
	local indent_size = props.IndentSize or theme.GetSize("M")
	local toggle_size = props.ToggleSize or 16
	local guide_step = props.GuideStep or math.max(indent_size, toggle_size)
	local box_size = props.BoxSize or 10
	local custom_panel_position = props.CustomPanelPosition == "after_label" and "after_label" or "before_label"
	local label_grow = props.LabelGrow == true or custom_panel_position == "after_label"
	local toggle_on_row_click = props.ToggleOnRowClick == true
	local double_click_time = props.DoubleClickTime or 0.3
	local animation_time = props.AnimationTime or 0.18
	local drag_threshold = props.DragThreshold or 6
	local drag_enabled = props.OnDrop ~= nil
	local row_click_times = {}
	local tree
	local is_expanded
	local set_selected
	local drag_state = {
		active = false,
		source_key = nil,
		drop_info = nil,
	}

	local function update_layout_now(entity)
		if not entity or not entity:IsValid() or not entity.layout then return end

		entity.layout:InvalidateLayout()
		local root = entity.layout
		local parent = entity:GetParent()

		while parent and parent:IsValid() and parent.layout do
			root = parent.layout
			parent = parent:GetParent()
		end

		root:UpdateLayout()
	end

	local function get_text(node, path)
		if props.GetText then return tostring(props.GetText(node, path)) end

		return tostring(node.Text or node.Label or node.Name or node.Value or node.Id or "Item")
	end

	local function get_children(node, path)
		if props.GetChildren then return props.GetChildren(node, path) or {} end

		return node.Children or {}
	end

	local function get_key(node, path)
		if props.GetKey then return tostring(props.GetKey(node, path)) end

		return tostring(node.Key or node.Id or path)
	end

	local function get_node_panel(node, path, key, selected, has_children, expanded)
		if props.GetNodePanel then
			return props.GetNodePanel(node, path, key, selected, has_children, expanded)
		end

		return nil
	end

	local function can_drag_node(node, path, key)
		if props.CanDragNode then return not not props.CanDragNode(node, path, key) end

		return not node.Disabled
	end

	local function can_drop_inside(node, path, key, has_children)
		if props.CanDropInside then
			return not not props.CanDropInside(node, path, key, has_children)
		end

		return has_children
	end

	local function is_selected(node, path, key)
		if props.IsSelected then return not not props.IsSelected(node, path, key) end

		return selected_key ~= nil and selected_key == key
	end

	local function get_text_color(node, path, key)
		if node.Disabled then return theme.GetColor("text_disabled") end

		if is_selected(node, path, key) then return theme.GetColor("text_button") end

		return theme.GetColor("text_foreground")
	end

	local function refresh_row_text(info)
		if not info or not info.text or not info.text:IsValid() then return end

		info.text.text:SetColor(get_text_color(info.node, info.path, info.key))
	end

	local function clear_drag_state()
		drag_state.active = false
		drag_state.source_key = nil
		drag_state.drop_info = nil
	end

	local function is_key_in_branch(source_key, candidate_key)
		local current_key = candidate_key

		while current_key do
			if current_key == source_key then return true end

			local current_info = row_infos[current_key]

			if not current_info then break end

			current_key = current_info.parent_key
		end

		return false
	end

	local function find_drop_info(source_info, global_pos)
		if not source_info then return nil end

		for _, key in ipairs(row_order) do
			local target_info = row_infos[key]

			if
				target_info and
				target_info.clip and
				target_info.clip:IsValid() and
				target_info.clip.gui_element and
				target_info.clip.gui_element:GetVisible() and
				target_info.clip.gui_element:IsHovered(global_pos)
			then
				if target_info.key == source_info.key then return nil end

				local local_pos = target_info.clip.transform:GlobalToLocal(global_pos)
				local height = math.max(target_info.clip.transform:GetHeight(), 1)
				local position
				local allow_inside = can_drop_inside(target_info.node, target_info.path, target_info.key, target_info.has_children)

				if allow_inside then
					local edge_size = math.max(4, height * 0.25)

					if local_pos.y <= edge_size then
						position = "before"
					elseif local_pos.y >= height - edge_size then
						position = "after"
					else
						position = "inside"
					end
				else
					position = local_pos.y < height / 2 and "before" or "after"
				end

				local parent_info
				local parent_key

				if position == "inside" then
					parent_info = target_info
					parent_key = target_info.key
				else
					parent_key = target_info.parent_key
					parent_info = parent_key and row_infos[parent_key] or nil
				end

				if is_key_in_branch(source_info.key, parent_key) then return nil end

				local drop_info = {
					source_node = source_info.node,
					source_key = source_info.key,
					source_path = source_info.path,
					target_node = target_info.node,
					target_key = target_info.key,
					target_path = target_info.path,
					parent_node = parent_info and parent_info.node or nil,
					parent_key = parent_key,
					parent_path = parent_info and parent_info.path or nil,
					position = position,
				}

				if props.CanDrop and not props.CanDrop(drop_info) then return nil end

				return drop_info
			end
		end

		return nil
	end

	local function begin_drag(row_info)
		if not drag_enabled or not row_info then return end

		if
			row_info.toggle and
			row_info.toggle.mouse_input and
			row_info.toggle.mouse_input:GetHovered()
		then
			if
				row_info.body and
				row_info.body.draggable and
				row_info.body.draggable:IsDragging()
			then
				row_info.body.draggable:StopDragging()
			end

			return
		end

		drag_state.active = false
		drag_state.source_key = row_info.key
		drag_state.drop_info = nil
		set_selected(row_info.node, row_info.path, row_info.key)
	end

	local function update_drag(row_info, delta, global_pos)
		if not drag_enabled or not row_info or drag_state.source_key ~= row_info.key then
			return true
		end

		if not drag_state.active then
			if delta:GetLength() < drag_threshold then return true end

			drag_state.active = true
		end

		drag_state.drop_info = find_drop_info(row_info, global_pos)
		return true
	end

	local function finish_drag(row_info)
		if not drag_enabled or not row_info or drag_state.source_key ~= row_info.key then
			return
		end

		local drop_info = drag_state.active and drag_state.drop_info or nil
		clear_drag_state()

		if drop_info and props.OnDrop then props.OnDrop(drop_info) end
	end

	local function update_row_display(info)
		if
			not info or
			not info.clip or
			not info.clip:IsValid()
			or
			not info.body or
			not info.body:IsValid()
		then
			return
		end

		local clip_w = info.clip.transform:GetWidth()
		local open_fraction = info.open_fraction or 0

		if open_fraction > 0.001 then info.clip.gui_element:SetVisible(true) end

		if info.body.transform:GetWidth() ~= clip_w then
			info.body.transform:SetWidth(clip_w)
		end

		local body_h = info.body.transform:GetHeight()

		if open_fraction > 0.001 and body_h <= 0.001 then
			update_layout_now(info.clip)
			body_h = info.body.transform:GetHeight()
		end

		local target_h = body_h * open_fraction
		local target_y = -(body_h - target_h)
		local target_visible = target_h > 0.001
		local changed = false

		if info.clip.transform:GetHeight() ~= target_h then
			info.clip.transform:SetHeight(target_h)
			changed = true
		end

		if info.clip.gui_element:GetVisible() ~= target_visible then
			info.clip.gui_element:SetVisible(target_visible)
			changed = true
		end

		if info.body.transform:GetY() ~= target_y then
			info.body.transform:SetY(target_y)
			changed = true
		end

		if changed and tree and tree.layout then tree.layout:InvalidateLayout() end
	end

	local function is_row_visible(info)
		local parent_key = info and info.parent_key

		while parent_key do
			local parent_info = row_infos[parent_key]

			if not parent_info then break end

			if
				not is_expanded(parent_info.node, parent_info.path, parent_info.key, parent_info.has_children)
			then
				return false
			end

			parent_key = parent_info.parent_key
		end

		return true
	end

	local function refresh_visibility()
		for _, key in ipairs(row_order) do
			local info = row_infos[key]

			if info and info.clip and info.clip:IsValid() and info.clip.gui_element then
				local target = is_row_visible(info) and 1 or 0

				if info.open_fraction == nil then
					info.open_fraction = target
					update_row_display(info)
				elseif info.open_fraction ~= target then
					if animation_time <= 0 then
						info.open_fraction = target
						update_row_display(info)
					else
						if target > 0 then info.clip.gui_element:SetVisible(true) end

						tree.animation:Animate{
							id = "tree_row_open_" .. key,
							get = function()
								return info.open_fraction or 0
							end,
							set = function(v)
								info.open_fraction = v
								update_row_display(info)
							end,
							to = target,
							time = animation_time,
							interpolation = target > (info.open_fraction or 0) and "outExpo" or "outCubic",
						}
					end
				end
			end
		end

		update_layout_now(tree)
	end

	function is_expanded(node, path, key, has_children)
		if not has_children then return false end

		if props.IsExpanded then return not not props.IsExpanded(node, path, key) end

		local expanded = expanded_state[key]

		if expanded == nil then
			expanded = node.Expanded == true
			expanded_state[key] = expanded
		end

		return expanded
	end

	local function set_expanded(node, path, key, expanded)
		if props.IsExpanded then
			if props.OnToggle then props.OnToggle(node, expanded, key, path) end
		else
			expanded_state[key] = expanded

			if props.OnToggle then props.OnToggle(node, expanded, key, path) end
		end

		tree:RefreshBranchForKey(key)
	end

	function set_selected(node, path, key)
		local previous_key = selected_key

		if props.IsSelected then
			if props.OnSelect then props.OnSelect(node, key, path) end
		else
			selected_key = key

			if props.OnSelect then props.OnSelect(node, key, path) end
		end

		refresh_row_text(row_infos[previous_key])
		refresh_row_text(row_infos[key])
	end

	local function apply_branch_state(nodes, parent_path, expanded)
		for index, node in ipairs(nodes) do
			local path = build_path(parent_path, index)
			local key = get_key(node, path)
			local children = get_children(node, path)

			if has_entries(children) then
				if props.IsExpanded then
					if props.OnToggle then props.OnToggle(node, expanded, key, path) end
				else
					expanded_state[key] = expanded

					if props.OnToggle then props.OnToggle(node, expanded, key, path) end
				end

				apply_branch_state(children, path, expanded)
			end
		end
	end

	local function find_item_descriptor(nodes, parent_path, parent_key, level, continuations, target_key)
		for index, node in ipairs(nodes) do
			local path = build_path(parent_path, index)
			local key = get_key(node, path)
			local is_last = index == #nodes
			local meta = {
				level = level,
				index = index,
				is_last = is_last,
				parent_key = parent_key,
				continuations = continuations,
			}

			if key == target_key then
				return {
					node = node,
					path = path,
					key = key,
					meta = meta,
					parent_path = parent_path,
				}
			end

			local children = get_children(node, path)

			if has_entries(children) then
				local child_continuations = table.shallow_copy(continuations)
				child_continuations[level + 1] = not is_last
				local found = find_item_descriptor(
					children,
					path,
					key,
					level + 1,
					child_continuations,
					target_key
				)

				if found then return found end
			end
		end
	end

	local function expand_to_key(nodes, parent_path, target_key)
		for index, node in ipairs(nodes) do
			local path = build_path(parent_path, index)
			local key = get_key(node, path)
			local children = get_children(node, path)

			if key == target_key then return true end

			if has_entries(children) and expand_to_key(children, path, target_key) then
				if props.IsExpanded then
					if props.OnToggle then props.OnToggle(node, true, key, path) end
				else
					expanded_state[key] = true

					if props.OnToggle then props.OnToggle(node, true, key, path) end
				end

				return true
			end
		end

		return false
	end

	local function make_toggle(node, path, key, expanded, selected, meta, row_info)
		local center_x = meta.level * guide_step + math.floor(toggle_size / 2)
		local half_box = math.floor(box_size / 2)
		local box_x = center_x - half_box
		return Panel.New{
			IsInternal = true,
			Name = "TreeToggle",
			OnSetProperty = theme.OnSetProperty,
			Ref = function(self)
				row_info.toggle = self
			end,
			transform = {
				Size = Vec2(math.max(toggle_size, meta.level * guide_step + toggle_size + 6), toggle_size),
			},
			gui_element = {
				OnDraw = function(self)
					local current_selected = is_selected(node, path, key)
					local current_expanded = is_expanded(node, path, key, has_entries(get_children(node, path)))
					local size = self.Owner.transform:GetSize()
					local center_y = math.floor(size.y / 2)
					local box_y = center_y - half_box
					local line_color = theme.GetColor(props.LineColor or "frame_border")
					local box_fill = theme.GetColor(props.BoxFillColor or "surface")
					local box_outline = theme.GetColor(props.BoxOutlineColor or "frame_border")
					local glyph_color = theme.GetColor(current_selected and "text_button" or (props.GlyphColor or "text_foreground"))
					local line_start_x = has_entries(get_children(node, path)) and (center_x + half_box) or center_x
					render2d.SetTexture(nil)
					render2d.SetColor(line_color:Unpack())

					for level = 1, #meta.continuations do
						if meta.continuations[level] then
							local x = (level - 1) * guide_step + math.floor(toggle_size / 2)
							render2d.DrawRect(x, 0, 1, size.y)
						end
					end

					if meta.level > 0 then
						render2d.DrawRect(center_x, 0, 1, center_y + 1)
					end

					if not meta.is_last then
						render2d.DrawRect(center_x, center_y, 1, size.y - center_y)
					end

					render2d.DrawRect(line_start_x, center_y, math.max(1, size.x - line_start_x), 1)

					if has_entries(get_children(node, path)) then
						render2d.SetColor(box_fill:Unpack())
						render2d.DrawRect(box_x, box_y, box_size, box_size)
						render2d.SetColor(box_outline:Unpack())
						gfx.DrawOutlinedRect(box_x, box_y, box_size, box_size, 1)
						render2d.SetColor(glyph_color:Unpack())
						render2d.DrawRect(box_x + 2, center_y, math.max(1, box_size - 4), 1)

						if not current_expanded then
							render2d.DrawRect(center_x, box_y + 2, 1, math.max(1, box_size - 4))
						end
					end
				end,
			},
			mouse_input = {
				Cursor = "pointer",
			},
			OnClick = function()
				set_expanded(node, path, key, not is_expanded(node, path, key, true))
				return true
			end,
			clickable = true,
		}
	end

	local function make_label(node, path, key, selected, has_children, expanded, row_info)
		return Panel.New{
			IsInternal = true,
			Name = "TreeLabel",
			OnSetProperty = theme.OnSetProperty,
			transform = true,
			layout = {
				FitWidth = not label_grow,
				FitHeight = true,
				GrowWidth = label_grow and 1 or nil,
				Padding = props.LabelPadding or "XXS",
			},
			gui_element = {
				OnDraw = function(self)
					local size = self.Owner.transform:GetSize()
					render2d.SetTexture(nil)

					if is_selected(node, path, key) then
						local color = theme.GetColor(props.SelectedColor or "primary")
						render2d.SetColor(color:Unpack())
						render2d.DrawRect(0, 0, size.x, size.y)
					elseif row_info.hovered then
						local color = theme.GetColor(props.HoverColor or "surface_variant")
						render2d.SetColor(color:Unpack())
						render2d.DrawRect(0, 0, size.x, size.y)
					end
				end,
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
		}{
			Text{
				Ref = function(self)
					row_info.text = self
					refresh_row_text(row_info)
				end,
				Text = get_text(node, path),
				Font = node.Font or props.RowFont or "body",
				Color = node.Disabled and
					"text_disabled" or
					(
						selected and
						"text_button" or
						"text_foreground"
					),
				IgnoreMouseInput = true,
				layout = {
					FitWidth = true,
					FitHeight = true,
				},
			},
		}
	end

	local function make_toggle_placeholder(meta)
		return Panel.New{
			IsInternal = true,
			Name = "TreeTogglePlaceholder",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = Vec2(math.max(toggle_size, meta.level * guide_step + toggle_size + 6), toggle_size),
			},
			gui_element = {
				OnDraw = function(self)
					local size = self.Owner.transform:GetSize()
					local center_y = math.floor(size.y / 2)
					local center_x = meta.level * guide_step + math.floor(toggle_size / 2)
					local line_color = theme.GetColor(props.LineColor or "frame_border")
					render2d.SetTexture(nil)
					render2d.SetColor(line_color:Unpack())

					for level = 1, #meta.continuations do
						if meta.continuations[level] then
							local x = (level - 1) * guide_step + math.floor(toggle_size / 2)
							render2d.DrawRect(x, 0, 1, size.y)
						end
					end

					if meta.level > 0 then
						render2d.DrawRect(center_x, 0, 1, center_y + 1)
					end

					if not meta.is_last then
						render2d.DrawRect(center_x, center_y, 1, size.y - center_y)
					end

					render2d.DrawRect(center_x, center_y, math.max(1, size.x - center_x), 1)
				end,
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
		}
	end

	local function add_node(node, meta, parent_path, insert_index)
		local path = build_path(parent_path, meta.index)
		local key = get_key(node, path)
		local children = get_children(node, path)
		local has_children = has_entries(children)
		local expanded = is_expanded(node, path, key, has_children)
		local selected = is_selected(node, path, key)
		local custom_panel = get_node_panel(node, path, key, selected, has_children, expanded)
		local row_info = {
			node = node,
			path = path,
			key = key,
			parent_key = meta.parent_key,
			has_children = has_children,
			toggle = nil,
		}
		row_infos[key] = row_info
		table.insert(row_order, insert_index, key)
		local label = make_label(node, path, key, selected, has_children, expanded, row_info)
		local row_children = {
			has_children and
			make_toggle(node, path, key, expanded, selected, meta, row_info) or
			make_toggle_placeholder(meta),
		}

		if custom_panel_position == "before_label" then
			if custom_panel then row_children[#row_children + 1] = custom_panel end

			row_children[#row_children + 1] = label
		else
			row_children[#row_children + 1] = label

			if custom_panel then row_children[#row_children + 1] = custom_panel end
		end

		local row = Panel.New{
			IsInternal = true,
			Name = "TreeRowBody",
			OnSetProperty = theme.OnSetProperty,
			transform = true,
			layout = {
				Direction = "x",
				AlignmentY = "stretch",
				FitHeight = true,
				GrowWidth = 1,
				FitWidth = false,
				ChildGap = props.RowGap or 3,
				Floating = true,
			},
			gui_element = true,
			mouse_input = {
				Cursor = node.Disabled and "arrow" or "pointer",
				OnHover = function(self, is_hovered)
					row_info.hovered = is_hovered

					if props.OnNodeHover then
						props.OnNodeHover(node, key, path, row_info, is_hovered, self.Owner)
					end
				end,
			},
			draggable = drag_enabled and can_drag_node(node, path, key),
			OnDragStarted = function()
				begin_drag(row_info)
			end,
			OnDrag = function(self, delta, global_pos)
				return update_drag(row_info, delta, global_pos)
			end,
			OnDragStopped = function()
				finish_drag(row_info)
			end,
			clickable = {
				DoubleClickKey = key,
				DoubleClickTime = double_click_time,
			},
			OnClick = function(self)
				if node.Disabled then return end

				local now = system.GetElapsedTime()
				local last_click = row_click_times[key]
				local is_double_click = last_click and now - last_click <= double_click_time

				if is_double_click then
					row_click_times[key] = nil
				else
					row_click_times[key] = now
				end

				set_selected(node, path, key)

				if has_children and toggle_on_row_click then
					set_expanded(node, path, key, not is_expanded(node, path, key, has_children))
				elseif is_double_click and has_children then
					set_expanded(node, path, key, not is_expanded(node, path, key, has_children))
				end

				return true
			end,
			OnDoubleClick = function() end,
			OnRightClick = function(self)
				if not props.OnNodeContextMenu or node.Disabled then return end

				set_selected(node, path, key)
				return props.OnNodeContextMenu(node, key, path, row_info, self.Owner)
			end,
		}(row_children)
		row_info.body = row
		local clip = Panel.New{
			IsInternal = true,
			Name = "TreeRow",
			OnSetProperty = theme.OnSetProperty,
			Ref = function(self)
				row_info.clip = self

				self:AddLocalListener("OnTransformChanged", function()
					update_row_display(row_info)
				end)

				self:AddLocalListener("OnLayoutUpdated", function()
					update_row_display(row_info)
				end)
			end,
			transform = {
				Size = Vec2(0, 0),
			},
			layout = {
				GrowWidth = 1,
				FitHeight = false,
			},
			gui_element = {
				Clipping = true,
				Visible = false,
				OnPostDraw = function(self)
					local drop_info = drag_state.active and drag_state.drop_info or nil
					local is_source = drag_state.active and drag_state.source_key == key

					if not is_source and (not drop_info or drop_info.target_key ~= key) then
						return
					end

					local size = self.Owner.transform:GetSize()
					local color = theme.GetColor(props.DropIndicatorColor or "primary")
					render2d.SetTexture(nil)
					render2d.SetColor(color:Unpack())

					if is_source then
						gfx.DrawOutlinedRect(0, 0, math.max(1, size.x), math.max(1, size.y), 1)
					end

					if not drop_info or drop_info.target_key ~= key then return end

					if drop_info.position == "inside" then
						gfx.DrawOutlinedRect(0, 0, math.max(1, size.x), math.max(1, size.y), 2)
					elseif drop_info.position == "before" then
						render2d.DrawRect(0, 0, math.max(1, size.x), 2)
					else
						render2d.DrawRect(0, math.max(0, size.y - 2), math.max(1, size.x), 2)
					end
				end,
			},
			mouse_input = true,
			animation = true,
		}(row)

		row:AddLocalListener("OnTransformChanged", function()
			update_row_display(row_info)
		end)

		row:AddLocalListener("OnLayoutUpdated", function()
			update_row_display(row_info)
		end)

		tree:AddChild(clip, insert_index)
		insert_index = insert_index + 1

		if has_children and expanded then
			local child_continuations = table.shallow_copy(meta.continuations)
			child_continuations[meta.level + 1] = not meta.is_last

			for child_index, child in ipairs(children) do
				insert_index = add_node(
					child,
					{
						level = meta.level + 1,
						index = child_index,
						is_last = child_index == #children,
						parent_key = key,
						continuations = child_continuations,
					},
					path,
					insert_index
				)
			end
		end

		return insert_index
	end

	tree = Panel.New{
		props,
		{
			Name = "Tree",
			OnSetProperty = theme.OnSetProperty,
			layout = {
				Direction = "y",
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				ChildGap = props.ChildGap or 0,
				props.layout,
			},
			transform = true,
			gui_element = true,
			mouse_input = true,
			clickable = true,
			animation = true,
		},
	}

	function tree:SetItems(new_items)
		items = new_items or {}
		self:Rebuild()
		return self
	end

	function tree:GetItems()
		return items
	end

	function tree:SetSelectedKey(key)
		local previous_key = selected_key
		selected_key = key
		refresh_row_text(row_infos[previous_key])
		refresh_row_text(row_infos[key])
		return self
	end

	function tree:GetSelectedKey()
		return selected_key
	end

	function tree:ExpandAll()
		apply_branch_state(items, nil, true)
		self:Rebuild()
		return self
	end

	function tree:CollapseAll()
		apply_branch_state(items, nil, false)
		self:Rebuild()
		return self
	end

	function tree:ExpandToKey(key)
		expand_to_key(items, nil, key)
		self:Rebuild()
		return self
	end

	function tree:Rebuild()
		clear_drag_state()
		row_infos = {}
		row_order = {}
		self:RemoveChildren()
		local insert_index = 1

		for index, node in ipairs(items) do
			insert_index = add_node(
				node,
				{
					level = 0,
					index = index,
					is_last = index == #items,
					parent_key = nil,
					continuations = {},
				},
				nil,
				insert_index
			)
		end

		refresh_visibility()
		return self
	end

	function tree:RefreshBranchForKey(key)
		if key == nil then return self:Rebuild() end

		local descriptor = find_item_descriptor(items, nil, nil, 0, {}, key)

		if not descriptor then return self:Rebuild() end

		local start_index
		local end_index

		for i, row_key in ipairs(row_order) do
			if row_key == key then
				start_index = i
				end_index = i

				break
			end
		end

		if not start_index then return self:Rebuild() end

		for i = start_index + 1, #row_order do
			local info = row_infos[row_order[i]]

			if not (info and is_key_in_branch(key, info.key)) then break end

			end_index = i
		end

		clear_drag_state()

		for i = end_index, start_index, -1 do
			local row_key = row_order[i]
			local info = row_infos[row_key]

			if info and info.clip and info.clip:IsValid() then info.clip:Remove() end

			row_infos[row_key] = nil
			table.remove(row_order, i)
		end

		add_node(descriptor.node, descriptor.meta, descriptor.parent_path, start_index)
		refresh_visibility()
		return self
	end

	tree:Rebuild()

	if external_ref then external_ref(tree) end

	return tree
end
