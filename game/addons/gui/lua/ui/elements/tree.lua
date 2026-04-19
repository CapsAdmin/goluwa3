local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local system = import("goluwa/system.lua")
local Panel = import("goluwa/ecs/panel.lua")
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
	local toggle_on_row_click = props.ToggleOnRowClick == true
	local double_click_time = props.DoubleClickTime or 0.3
	local animation_time = props.AnimationTime or 0.18
	local tree
	local is_expanded

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

		if info.body.transform:GetWidth() ~= clip_w then
			info.body.transform:SetWidth(clip_w)
		end

		local body_h = info.body.transform:GetHeight()
		local open_fraction = info.open_fraction or 0
		local target_h = body_h * open_fraction
		info.clip.transform:SetHeight(target_h)
		info.clip.gui_element:SetVisible(target_h > 0.001)
		info.body.transform:SetY(-(body_h - target_h))

		if tree and tree.layout then tree.layout:InvalidateLayout() end
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

		refresh_visibility()
	end

	local function set_selected(node, path, key)
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

	local function make_toggle(node, path, key, expanded, selected, meta)
		return Panel.New{
			IsInternal = true,
			Name = "TreeToggle",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = Vec2(math.max(toggle_size, meta.level * guide_step + toggle_size + 6), toggle_size),
			},
			gui_element = {
				OnDraw = function(self)
					local current_selected = is_selected(node, path, key)
					local current_expanded = is_expanded(node, path, key, has_entries(get_children(node, path)))
					local size = self.Owner.transform:GetSize()
					local center_y = math.floor(size.y / 2)
					local center_x = meta.level * guide_step + math.floor(toggle_size / 2)
					local line_color = theme.GetColor(props.LineColor or "frame_border")
					local box_fill = theme.GetColor(props.BoxFillColor or "surface")
					local box_outline = theme.GetColor(props.BoxOutlineColor or "frame_border")
					local glyph_color = theme.GetColor(current_selected and "text_button" or (props.GlyphColor or "text_foreground"))
					local half_box = math.floor(box_size / 2)
					local box_x = center_x - half_box
					local box_y = center_y - half_box
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
				Cursor = has_entries(get_children(node, path)) and "pointer" or "arrow",
				OnMouseInput = function(self, button, press, local_pos)
					if button ~= "button_1" or not press then return end

					if not has_entries(get_children(node, path)) then return end

					local current_expanded = is_expanded(node, path, key, true)
					local center_x = meta.level * guide_step + math.floor(toggle_size / 2)
					local center_y = math.floor(self.Owner.transform:GetHeight() / 2)
					local half_box = math.floor(box_size / 2)

					if local_pos.x < center_x - half_box or local_pos.x > center_x + half_box then
						return
					end

					if local_pos.y < center_y - half_box or local_pos.y > center_y + half_box then
						return
					end

					set_expanded(node, path, key, not current_expanded)
					return true
				end,
			},
			clickable = has_entries(get_children(node, path)),
		}
	end

	local function make_label(node, path, key, selected, has_children, expanded, row_info)
		local hovered = false
		local last_click_time = -math.huge
		return Panel.New{
			IsInternal = true,
			Name = "TreeLabel",
			OnSetProperty = theme.OnSetProperty,
			transform = true,
			layout = {
				FitWidth = true,
				FitHeight = true,
				Padding = props.LabelPadding or "XXS",
			},
			gui_element = {
				OnDraw = function(self)
					local current_selected = is_selected(node, path, key)
					local size = self.Owner.transform:GetSize()
					render2d.SetTexture(nil)

					if current_selected then
						local color = theme.GetColor(props.SelectedColor or "primary")
						render2d.SetColor(color:Unpack())
						render2d.DrawRect(0, 0, size.x, size.y)
					elseif hovered then
						local color = theme.GetColor(props.HoverColor or "surface_variant")
						render2d.SetColor(color:Unpack())
						render2d.DrawRect(0, 0, size.x, size.y)
					end
				end,
			},
			mouse_input = {
				Cursor = node.Disabled and "arrow" or "pointer",
				OnHover = function(self, is_hovered)
					hovered = is_hovered
				end,
				OnMouseInput = function(self, button, press)
					if node.Disabled or button ~= "button_1" or not press then return end

					local current_expanded = is_expanded(node, path, key, has_children)
					local now = system.GetElapsedTime()
					local is_double_click = now - last_click_time <= double_click_time
					last_click_time = now
					set_selected(node, path, key)

					if has_children and (toggle_on_row_click or is_double_click) then
						set_expanded(node, path, key, not current_expanded)
					end

					return true
				end,
			},
			clickable = true,
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

	local function add_node(node, meta, parent_path)
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
		}
		row_infos[key] = row_info
		row_order[#row_order + 1] = key
		local row_children = {
			has_children and
			make_toggle(node, path, key, expanded, selected, meta) or
			make_toggle_placeholder(meta),
		}

		if custom_panel then row_children[#row_children + 1] = custom_panel end

		row_children[#row_children + 1] = make_label(node, path, key, selected, has_children, expanded, row_info)
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
			mouse_input = true,
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

		tree:AddChild(clip)

		if has_children then
			local child_continuations = table.shallow_copy(meta.continuations)
			child_continuations[meta.level + 1] = not meta.is_last

			for child_index, child in ipairs(children) do
				add_node(
					child,
					{
						level = meta.level + 1,
						index = child_index,
						is_last = child_index == #children,
						parent_key = key,
						continuations = child_continuations,
					},
					path
				)
			end
		end
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
		refresh_visibility()
		return self
	end

	function tree:CollapseAll()
		apply_branch_state(items, nil, false)
		refresh_visibility()
		return self
	end

	function tree:ExpandToKey(key)
		expand_to_key(items, nil, key)
		refresh_visibility()
		return self
	end

	function tree:Rebuild()
		row_infos = {}
		row_order = {}
		self:RemoveChildren()

		for index, node in ipairs(items) do
			add_node(
				node,
				{
					level = 0,
					index = index,
					is_last = index == #items,
					parent_key = nil,
					continuations = {},
				},
				nil
			)
		end

		refresh_visibility()
		return self
	end

	tree:Rebuild()

	if external_ref then external_ref(tree) end

	return tree
end
