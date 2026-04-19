local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Button = import("lua/ui/elements/button.lua")
local Checkbox = import("lua/ui/elements/checkbox.lua")
local Collapsible = import("lua/ui/elements/collapsible.lua")
local Column = import("lua/ui/elements/column.lua")
local Dropdown = import("lua/ui/elements/dropdown.lua")
local Frame = import("lua/ui/elements/frame.lua")
local Row = import("lua/ui/elements/row.lua")
local Slider = import("lua/ui/elements/slider.lua")
local Text = import("lua/ui/elements/text.lua")
local TextEdit = import("lua/ui/elements/text_edit.lua")
local theme = import("lua/ui/theme.lua")

local function has_entries(list)
	return list and next(list) ~= nil
end

local function build_path(parent_path, index)
	if parent_path then return parent_path .. "/" .. index end

	return tostring(index)
end

local function set_text(panel, value)
	if panel and panel:IsValid() and panel.text then
		panel.text:SetText(value or "")
	end
end

local function get_node_text(node, path)
	return tostring(node.Text or node.Label or node.Name or node.Key or path or "Property")
end

local function get_node_key(node, path)
	return tostring(node.Key or node.Id or path)
end

local function get_node_children(node)
	return node.Children or {}
end

local function find_node_by_key(nodes, target_key, parent_path, category_key)
	for index, node in ipairs(nodes or {}) do
		local path = build_path(parent_path, index)
		local key = get_node_key(node, path)
		local top_category_key = category_key or key

		if key == target_key then return node, path, top_category_key end

		local found_node, found_path, found_category_key = find_node_by_key(get_node_children(node), target_key, path, top_category_key)

		if found_node then return found_node, found_path, found_category_key end
	end

	return nil, nil, nil
end

local function find_first_leaf(nodes, parent_path, category_key)
	for index, node in ipairs(nodes or {}) do
		local path = build_path(parent_path, index)
		local key = get_node_key(node, path)
		local top_category_key = category_key or key

		if not has_entries(get_node_children(node)) then
			return node, path, top_category_key
		end

		local found_node, found_path, found_category_key = find_first_leaf(get_node_children(node), path, top_category_key)

		if found_node then return found_node, found_path, found_category_key end
	end

	return nil, nil, nil
end

local function get_precision(node, fallback)
	if node.Precision ~= nil then return node.Precision end

	return fallback
end

local function format_number(node, value, fallback_precision)
	local numeric = tonumber(value) or 0
	local precision = get_precision(node, fallback_precision or 2)

	if precision <= 0 then return tostring(math.floor(numeric + 0.5)) end

	return string.format("%." .. precision .. "f", numeric)
end

local function get_option_text(options, value)
	for _, option in ipairs(options or {}) do
		if type(option) == "table" then
			if option.Value == value then
				return tostring(option.Text or option.Label or option.Value)
			end
		elseif option == value then
			return tostring(option)
		end
	end

	if value == nil then return "Select..." end

	return tostring(value)
end

local function describe_value(node, fallback_precision)
	if has_entries(get_node_children(node)) then
		local child_count = #get_node_children(node)
		return child_count .. " child" .. (child_count == 1 and "" or "ren")
	end

	local kind = node.Type or node.Editor

	if kind == "boolean" then return node.Value and "enabled" or "disabled" end

	if kind == "enum" then return get_option_text(node.Options, node.Value) end

	if kind == "number" then
		return format_number(node, node.Value, fallback_precision)
	end

	if kind == "action" then
		return node.ActionText or node.ButtonText or "Action"
	end

	if node.Value == nil then return "" end

	return tostring(node.Value)
end

return function(props)
	props = props or {}
	local external_ref = props.Ref

	if external_ref then
		props = table.shallow_copy(props)
		props.Ref = nil
	end

	local items = props.Items or {}
	local selected_key = props.SelectedKey
	local number_precision = props.NumberPrecision or 2
	local slider_width = props.SliderWidth or 150
	local value_width = props.ValueWidth or 220
	local shared_key_width = props.KeyWidth or 180
	local divider_width = props.DividerWidth or 6
	local collapsed_state = {}
	local category_refs = {}
	local category_key_columns = {}
	local row_infos = {}
	local content_column
	local editor

	local function refresh_row_text(info)
		if not info or not info.text or not info.text:IsValid() then return end

		info.text.text:SetColor(
			selected_key == info.key and
				theme.GetColor("text_button") or
				theme.GetColor("text_foreground")
		)
	end

	local function sync_selection(key)
		if not key then
			selected_key = nil

			if props.OnSelect then props.OnSelect(nil, nil, nil) end

			return
		end

		local previous_key = selected_key
		selected_key = key
		local node, path, category_key = find_node_by_key(items, key)

		if category_key then
			local category = category_refs[category_key]

			if category and category:IsValid() then category:SetCollapsed(false) end
		end

		refresh_row_text(row_infos[previous_key])
		refresh_row_text(row_infos[key])

		if props.OnSelect then props.OnSelect(node, key, path) end
	end

	local function commit_value(node, value, key, path)
		node.Value = value
		sync_selection(key)

		if node.OnChange then node.OnChange(node, value, key, path) end

		if props.OnChange then props.OnChange(node, value, key, path) end
	end

	local function trigger_action(node, key, path)
		sync_selection(key)

		if node.OnAction then node.OnAction(node, key, path) end

		if props.OnAction then props.OnAction(node, key, path) end
	end

	local function get_row_height(node)
		if node.RowHeight then return node.RowHeight end

		if node.Multiline then return 86 end

		return 36
	end

	local function apply_shared_key_width()
		for _, column in ipairs(category_key_columns) do
			if column and column:IsValid() and column.layout then
				column.layout:SetMinSize(Vec2(shared_key_width, 0))
				column.layout:SetMaxSize(Vec2(shared_key_width, 0))
				column.layout:InvalidateLayout(true)
			end
		end
	end

	local function build_editor_panel(node, path, key)
		if has_entries(get_node_children(node)) then return nil end

		local kind = node.Type or node.Editor

		if kind == "boolean" or type(node.Value) == "boolean" then
			return Checkbox{
				Value = node.Value == true,
				OnChange = function(value)
					commit_value(node, value, key, path)
				end,
			}
		end

		if kind == "enum" then
			return Dropdown{
				Text = get_option_text(node.Options, node.Value),
				Options = node.Options or {},
				GetText = function()
					return get_option_text(node.Options, node.Value)
				end,
				OnSelect = function(value)
					commit_value(node, value, key, path)
				end,
				Padding = node.Padding or "XS",
				layout = {
					MinSize = Vec2(value_width, 0),
					MaxSize = Vec2(value_width, 0),
				},
			}
		end

		if kind == "number" and node.Min ~= nil and node.Max ~= nil then
			local value_label
			return Row{
				layout = {
					FitWidth = true,
					ChildGap = 8,
					AlignmentY = "center",
				},
			}{
				Slider{
					Value = tonumber(node.Value) or tonumber(node.Min) or 0,
					Min = node.Min,
					Max = node.Max,
					OnChange = function(value)
						commit_value(node, value, key, path)
						set_text(value_label, format_number(node, value, number_precision))
					end,
					layout = {
						MinSize = Vec2(slider_width, 0),
						MaxSize = Vec2(slider_width, 0),
					},
				},
				Text{
					Ref = function(self)
						value_label = self
						set_text(self, format_number(node, node.Value, number_precision))
					end,
					Text = format_number(node, node.Value, number_precision),
					Color = "text_disabled",
					IgnoreMouseInput = true,
					layout = {
						FitWidth = true,
					},
				},
			}
		end

		if kind == "action" then
			return Button{
				Text = node.ButtonText or node.ActionText or "Run",
				Mode = node.Mode or "outline",
				OnClick = function()
					trigger_action(node, key, path)
				end,
			}
		end

		local input
		local multiline = node.Multiline == true
		local input_height = multiline and 72 or 34
		return Row{
			layout = {
				FitWidth = true,
				ChildGap = 8,
				AlignmentY = "center",
			},
		}{
			TextEdit{
				Ref = function(self)
					input = self
				end,
				Text = node.Value == nil and "" or tostring(node.Value),
				Size = Vec2(value_width, input_height),
				MinSize = Vec2(value_width, input_height),
				MaxSize = Vec2(value_width, input_height),
				Wrap = multiline,
				ScrollY = multiline,
				layout = {
					FitWidth = false,
				},
			},
			Button{
				Text = node.ApplyText or "Apply",
				Mode = "outline",
				OnClick = function()
					if not input or not input:IsValid() then return end

					local next_value = input:GetText()

					if kind == "number" then
						next_value = tonumber(next_value)

						if next_value == nil then return end
					end

					commit_value(node, next_value, key, path)
				end,
				layout = {
					SelfAlignmentY = multiline and "start" or "center",
				},
			},
		}
	end

	local function build_property_rows(nodes, parent_path, label_prefix, out)
		for index, node in ipairs(nodes or {}) do
			local path = build_path(parent_path, index)
			local key = get_node_key(node, path)
			local label = label_prefix and
				(
					label_prefix .. " / " .. get_node_text(node, path)
				)
				or
				get_node_text(node, path)

			if has_entries(get_node_children(node)) then
				build_property_rows(get_node_children(node), path, label, out)
			else
				out[#out + 1] = {
					node = node,
					path = path,
					key = key,
					label = label,
				}
			end
		end
	end

	local function draw_row_background(size, is_selected, hovered, is_alternate)
		render2d.SetTexture(nil)

		if is_selected then
			local color = theme.GetColor("primary")
			render2d.SetColor(color:Unpack())
			render2d.DrawRect(0, 0, size.x, size.y)
			return
		end

		if hovered then
			local color = theme.GetColor("surface_variant")
			render2d.SetColor(color:Unpack())
			render2d.DrawRect(0, 0, size.x, size.y)
			return
		end

		local color = theme.GetColor(is_alternate and "surface_variant" or "surface")
		render2d.SetColor(color:Unpack())
		render2d.DrawRect(0, 0, size.x, size.y)
	end

	local function build_label_row(entry, is_alternate)
		local hovered = false
		local info = {
			key = entry.key,
		}
		row_infos[entry.key] = info
		return Panel.New{
			Ref = function(self)
				info.panel = self
			end,
			Name = "PropertyLabelRow",
			OnSetProperty = theme.OnSetProperty,
			transform = true,
			layout = {
				Direction = "x",
				GrowWidth = 1,
				MinSize = Vec2(0, get_row_height(entry.node)),
				MaxSize = Vec2(0, get_row_height(entry.node)),
				AlignmentY = "center",
				Padding = "XS",
			},
			gui_element = {
				Clipping = true,
				OnDraw = function(self)
					local size = self.Owner.transform:GetSize()
					draw_row_background(size, selected_key == entry.key, hovered, is_alternate)
				end,
			},
			mouse_input = {
				Cursor = "pointer",
				OnHover = function(self, value)
					hovered = value
				end,
				OnMouseInput = function(self, button, press)
					if button ~= "button_1" or not press then return end

					sync_selection(entry.key)
					return true
				end,
			},
			clickable = true,
		}{
			Text{
				Ref = function(self)
					info.text = self
					refresh_row_text(info)
				end,
				Text = entry.label,
				Elide = true,
				ElideString = "...",
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
					MinSize = Vec2(10, 0),
					FitWidth = false,
					FitHeight = true,
				},
			},
		}
	end

	local function build_editor_row(entry, is_alternate)
		return Panel.New{
			Name = "PropertyEditorRow",
			OnSetProperty = theme.OnSetProperty,
			transform = true,
			layout = {
				Direction = "x",
				GrowWidth = 1,
				MinSize = Vec2(0, get_row_height(entry.node)),
				MaxSize = Vec2(0, get_row_height(entry.node)),
				AlignmentY = entry.node.Multiline and "start" or "center",
				Padding = "XS",
			},
			gui_element = {
				OnDraw = function(self)
					local size = self.Owner.transform:GetSize()
					draw_row_background(size, selected_key == entry.key, false, is_alternate)
				end,
			},
		}{
			build_editor_panel(entry.node, entry.path, entry.key),
		}
	end

	local function build_synced_divider(container)
		local state = {
			is_dragging = false,
			is_hovered = false,
		}
		return Panel.New{
			Name = "PropertyEditorDivider",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = Vec2(divider_width, 0),
			},
			layout = {
				GrowWidth = 0,
				GrowHeight = 1,
			},
			mouse_input = {
				Cursor = "horizontal_resize",
				OnHover = function(self, hovered)
					state.is_hovered = hovered

					if not state.is_dragging and self.Owner.gui_element then
						self.Owner.gui_element:SetColor(Color(0, 0, 0, hovered and 0.5 or 0.2))
					end
				end,
				OnMouseInput = function(self, button, press)
					if button ~= "button_1" then return end

					state.is_dragging = press

					if self.Owner.gui_element then
						if press then
							self.Owner.gui_element:SetColor(theme.GetColor("primary"):Copy():SetAlpha(0.8))
						else
							self.Owner.gui_element:SetColor(Color(0, 0, 0, state.is_hovered and 0.5 or 0.2))
						end
					end

					return true
				end,
				OnGlobalMouseInput = function(self, button, press)
					if button == "button_1" and not press and state.is_dragging then
						state.is_dragging = false

						if self.Owner.gui_element then
							self.Owner.gui_element:SetColor(Color(0, 0, 0, state.is_hovered and 0.5 or 0.2))
						end
					end
				end,
				OnGlobalMouseMove = function(self, pos)
					if not state.is_dragging then
						if self:GetHovered() then
							self:SetCursor("horizontal_resize")
							return true
						end

						return
					end

					local lpos = container.transform:GlobalToLocal(pos)
					shared_key_width = math.max(10, lpos.x - divider_width / 2)
					apply_shared_key_width()
					self:SetCursor("horizontal_resize")
					return true
				end,
			},
			gui_element = {
				Color = Color(0, 0, 0, 0.2),
				OnDraw = function(self)
					theme.panels.divider(self.Owner)
				end,
			},
			animation = true,
			clickable = true,
		}
	end

	local function build_category_panel(node, path, key)
		local entries = {}
		build_property_rows(get_node_children(node), path, nil, entries)
		local left_children = {}
		local right_children = {}

		for i, entry in ipairs(entries) do
			local is_alternate = i % 2 == 0
			left_children[#left_children + 1] = build_label_row(entry, is_alternate)
			right_children[#right_children + 1] = build_editor_row(entry, is_alternate)
		end

		local collapsed = collapsed_state[key]
		local children = {}

		if collapsed == nil then
			collapsed = node.Collapsed == true or node.Expanded == false
		end

		if node.Description then
			children[#children + 1] = Text{
				Text = node.Description,
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			}
		end

		if #entries > 0 then
			local split_row = Panel.New{
				Name = "PropertyEditorSplitRow",
				OnSetProperty = theme.OnSetProperty,
				transform = true,
				layout = {
					Direction = "x",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentY = "stretch",
					ChildGap = 0,
				},
				gui_element = true,
			}
			children[#children + 1] = split_row{
				Column{
					Ref = function(self)
						category_key_columns[#category_key_columns + 1] = self

						if self.layout then
							self.layout:SetMinSize(Vec2(shared_key_width, 0))
							self.layout:SetMaxSize(Vec2(shared_key_width, 0))
						end
					end,
					layout = {
						GrowWidth = 0,
						FitHeight = true,
						FitWidth = false,
						AlignmentX = "stretch",
						ChildGap = 2,
					},
					gui_element = {
						Clipping = true,
					},
				}(left_children),
				build_synced_divider(split_row),
				Column{
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						FitWidth = false,
						AlignmentX = "stretch",
						ChildGap = 2,
					},
				}(right_children),
			}
		else
			children[#children + 1] = Text{
				Text = "No editable properties.",
				Color = "text_disabled",
				IgnoreMouseInput = true,
			}
		end

		return Collapsible{
			Title = get_node_text(node, path),
			Collapsed = collapsed,
			OnToggle = function(value)
				collapsed_state[key] = value
			end,
			Ref = function(self)
				category_refs[key] = self
			end,
		}(children)
	end

	local function rebuild_categories()
		row_infos = {}
		category_refs = {}
		category_key_columns = {}

		if not content_column or not content_column:IsValid() then return end

		content_column:RemoveChildren()

		for index, node in ipairs(items) do
			local path = build_path(nil, index)
			local key = get_node_key(node, path)
			content_column:AddChild(build_category_panel(node, path, key))
		end

		if selected_key then
			local node = find_node_by_key(items, selected_key)

			if not node then selected_key = nil end
		end

		if not selected_key then
			local first_node, first_path = find_first_leaf(items)
			selected_key = first_node and get_node_key(first_node, first_path) or nil
		end

		if selected_key then
			sync_selection(selected_key)
		else
			if props.OnSelect then props.OnSelect(nil, nil, nil) end
		end

		apply_shared_key_width()
	end

	editor = Column{
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
			FitHeight = false,
			AlignmentX = "stretch",
			ChildGap = props.ChildGap or 8,
			props.layout,
		},
	}{
		Frame{
			Padding = "XXS",
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
				FitHeight = true,
			},
		}{
			Column{
				Ref = function(self)
					content_column = self
					rebuild_categories()
				end,
				layout = {
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
					ChildGap = 6,
				},
			},
		},
	}

	function editor:SetItems(new_items)
		items = new_items or {}
		rebuild_categories()
		return self
	end

	function editor:GetItems()
		return items
	end

	function editor:SetSelectedKey(key)
		sync_selection(key)
		return self
	end

	function editor:GetSelectedKey()
		return selected_key
	end

	function editor:GetPanelForKey(key)
		local info = row_infos[key]
		return info and info.panel or nil
	end

	function editor:ExpandAll()
		for _, category in pairs(category_refs) do
			if category and category:IsValid() then category:SetCollapsed(false) end
		end

		return self
	end

	function editor:CollapseAll()
		for _, category in pairs(category_refs) do
			if category and category:IsValid() then category:SetCollapsed(true) end
		end

		return self
	end

	function editor:ExpandToKey(key, instant)
		local _, _, category_key = find_node_by_key(items, key)

		if category_key then
			local category = category_refs[category_key]

			if category and category:IsValid() then category:SetCollapsed(false, instant) end
		end

		return self
	end

	function editor:Rebuild()
		rebuild_categories()
		return self
	end

	if external_ref then external_ref(editor) end

	return editor
end
