local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local Panel = import("goluwa/ecs/panel.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")
local system = import("goluwa/system.lua")
local Button = import("lua/ui/elements/button.lua")
local Collapsible = import("lua/ui/elements/collapsible.lua")
local Column = import("lua/ui/elements/column.lua")
local ContextMenu = import("lua/ui/elements/context_menu.lua")
local MenuItem = import("lua/ui/elements/context_menu_item.lua")
local Text = import("lua/ui/elements/text.lua")
local Window = import("lua/ui/elements/window.lua")
local ColorPicker = import("lua/ui/elements/color_picker.lua")
local PropertyBoolean = import("lua/ui/elements/properties/boolean.lua")
local PropertyEnum = import("lua/ui/elements/properties/enum.lua")
local PropertyNumber = import("lua/ui/elements/properties/number.lua")
local PropertyObject = import("lua/ui/elements/properties/object.lua")
local PropertyString = import("lua/ui/elements/properties/string.lua")
local PropertyVector = import("lua/ui/elements/properties/vector.lua")
local theme = import("lua/ui/theme.lua")
local icon_sources = {
	copy = "https://api.iconify.design/material-symbols-light/content-copy.svg",
	paste = "https://api.iconify.design/material-symbols-light/content-paste-rounded.svg",
	reset = "https://api.iconify.design/material-symbols-light/reset-iso-rounded.svg",
}

local function has_entries(list)
	return list and next(list) ~= nil
end

local function build_path(parent_path, index)
	if parent_path then return parent_path .. "/" .. index end

	return tostring(index)
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

local vector_kinds = {
	vec2 = {
		components = {"x", "y"},
		factory = function(values)
			return Vec2(values[1], values[2])
		end,
	},
	vec3 = {
		components = {"x", "y", "z"},
		factory = function(values)
			return Vec3(values[1], values[2], values[3])
		end,
	},
	rect = {
		components = {"x", "y", "w", "h"},
		factory = function(values)
			return Rect(values[1], values[2], values[3], values[4])
		end,
	},
	quat = {
		components = {"x", "y", "z", "w"},
		factory = function(values)
			return Quat(values[1], values[2], values[3], values[4])
		end,
	},
	color = {
		components = {"r", "g", "b", "a"},
		factory = function(values)
			return Color(values[1], values[2], values[3], values[4])
		end,
	},
}

local function normalize_kind(kind)
	if kind == "Vec2" then return "vec2" end

	if kind == "Vec3" then return "vec3" end

	if kind == "Rect" then return "rect" end

	if kind == "Quat" then return "quat" end

	if kind == "Color" then return "color" end

	return kind
end

local function get_vector_kind_info(kind)
	return vector_kinds[normalize_kind(kind or "")]
end

local function format_vector(node, value, fallback_precision)
	local info = get_vector_kind_info(node.Type or node.Editor)

	if not info then return tostring(value) end

	local precision = get_precision(node, fallback_precision or 2)
	local values = {}

	for index, key in ipairs(info.components) do
		values[index] = format_number(
			{Precision = precision},
			tonumber(value and (value[key] or value[index])) or 0,
			precision
		)
	end

	return "(" .. table.concat(values, ", ") .. ")"
end

local open_color_picker_window
open_color_picker_window = function(node, value, key, path, panel, commit_value)
	local window_size = Vec2(380, 430)
	local world_size = Panel.World.transform:GetSize()
	local mouse_pos = system.GetWindow():GetMousePosition():Copy() + Vec2(16, 16)
	mouse_pos.x = math.min(mouse_pos.x, math.max(world_size.x - window_size.x, 0))
	mouse_pos.y = math.min(mouse_pos.y, math.max(world_size.y - window_size.y, 0))
	Panel.World:Ensure(
		Window{
			Key = "PropertyColorPickerWindow/" .. key,
			Title = "COLOR: " .. get_node_text(node, path),
			Size = window_size,
			Position = mouse_pos,
			OnClose = function(self)
				self:Remove()
			end,
		}{
			ColorPicker{
				Value = value,
				OnChange = function(next_value)
					commit_value(node, next_value, key, path, panel)
				end,
				layout = {
					GrowWidth = 1,
				},
			},
		}
	)
end

local function trim(text)
	return tostring(text or ""):match("^%s*(.-)%s*$")
end

local function decode_boolean(text)
	local normalized = trim(text):lower()

	if
		normalized == "true" or
		normalized == "1" or
		normalized == "yes" or
		normalized == "on"
	then
		return true, true
	end

	if
		normalized == "false" or
		normalized == "0" or
		normalized == "no" or
		normalized == "off"
	then
		return false, true
	end

	return nil, false
end

local function decode_enum(options, text)
	local normalized = trim(text)
	local normalized_lower = normalized:lower()

	for _, option in ipairs(options or {}) do
		local option_text
		local option_value

		if type(option) == "table" then
			option_text = tostring(option.Text or option.Label or option.Value)
			option_value = option.Value
		else
			option_text = tostring(option)
			option_value = option
		end

		if tostring(option_value) == normalized or option_text:lower() == normalized_lower then
			return option_value, true
		end
	end

	return nil, false
end

local function decode_vector(kind, text)
	local info = get_vector_kind_info(kind)

	if not info then return nil, false end

	local values = {}

	for number in tostring(text or ""):gmatch("[%+%-]?%d+%.?%d*") do
		values[#values + 1] = tonumber(number)

		if #values >= #info.components then break end
	end

	if #values ~= #info.components then return nil, false end

	return info.factory(values), true
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

	local kind = normalize_kind(node.Type or node.Editor)

	if kind == "boolean" then return node.Value and "enabled" or "disabled" end

	if kind == "enum" then return get_option_text(node.Options, node.Value) end

	if kind == "number" then
		return format_number(node, node.Value, fallback_precision)
	end

	if get_vector_kind_info(kind) then
		return format_vector(node, node.Value, fallback_precision)
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
	local compact_font_size = props.FontSize or "XS"
	local compact_padding = props.Padding or "XXXS"
	local compact_gap = props.ChildGapSize or "XXXS"
	local compact_row_height = props.RowHeight or 28
	local shared_key_width = props.KeyWidth or 180
	local divider_width = props.DividerWidth or 6
	local divider_draw_alpha = props.DividerDrawAlpha or 1
	local collapsed_state = {}
	local default_encoded_values = {}
	local category_refs = {}
	local category_key_columns = {}
	local category_dividers = {}
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

	local function commit_value(node, value, key, path, panel)
		local applied_value = value
		local applied = true
		node.Value = applied_value

		if panel then
			if panel.SetValue then
				panel:SetValue(applied_value, false)
			elseif panel.SetText then
				panel:SetText(applied_value == nil and "" or tostring(applied_value))
			end
		end

		sync_selection(key)

		if node.OnChange then
			applied = node.OnChange(node, value, key, path) ~= false
		end

		if not applied and node.GetValue then
			applied_value = node.GetValue(node, key, path)
			node.Value = applied_value

			if panel then
				if panel.SetValue then
					panel:SetValue(applied_value, false)
				elseif panel.SetText then
					panel:SetText(applied_value == nil and "" or tostring(applied_value))
				end
			end
		end

		if applied and props.OnChange then
			props.OnChange(node, applied_value, key, path)
		end
	end

	local function trigger_action(node, key, path)
		sync_selection(key)

		if node.OnAction then node.OnAction(node, key, path) end

		if props.OnAction then props.OnAction(node, key, path) end
	end

	local function get_row_height(node)
		if node.RowHeight then return node.RowHeight end

		if node.Multiline then return 86 end

		return compact_row_height
	end

	local function apply_shared_key_width()
		for _, column in ipairs(category_key_columns) do
			if column and column:IsValid() and column.layout then
				column.layout:SetMinSize(Vec2(shared_key_width, 0))
				column.layout:SetMaxSize(Vec2(shared_key_width, 0))
				column.layout:InvalidateLayout(true)
			end
		end

		for _, divider in ipairs(category_dividers) do
			if divider and divider:IsValid() and divider.UpdatePosition then
				divider:UpdatePosition()
			end
		end
	end

	local function encode_value_for_node(node, value, panel)
		if panel and panel.EncodeValue then return panel:EncodeValue() end

		local kind = normalize_kind(node.Type or node.Editor)

		if kind == "boolean" then return value and "true" or "false" end

		if kind == "enum" then return tostring(value) end

		if kind == "number" then return format_number(node, value, number_precision) end

		if get_vector_kind_info(kind) then
			return format_vector(node, value, number_precision)
		end

		if kind == "action" then return nil end

		if kind == "material" or kind == "texture" then return nil end

		if value == nil then return "" end

		return tostring(value)
	end

	local function decode_value_for_node(node, text, current_value, panel)
		if panel and panel.DecodeValue then return panel:DecodeValue(text) end

		local kind = normalize_kind(node.Type or node.Editor)

		if kind == "boolean" then return decode_boolean(text) end

		if kind == "enum" then return decode_enum(node.Options, text) end

		if kind == "number" then
			local numeric = tonumber(text)

			if numeric == nil then return nil, false end

			if node.Min ~= nil then numeric = math.max(node.Min, numeric) end

			if node.Max ~= nil then numeric = math.min(node.Max, numeric) end

			return numeric, true
		end

		if get_vector_kind_info(kind) then return decode_vector(kind, text) end

		if kind == "action" then return nil, false end

		if kind == "material" or kind == "texture" then return nil, false end

		return tostring(text or ""), true
	end

	local function get_default_encoded_value(node, key, panel)
		if node.DefaultEncoded ~= nil then return tostring(node.DefaultEncoded) end

		if node.Default ~= nil then
			return encode_value_for_node(node, node.Default, panel)
		end

		if default_encoded_values[key] == nil then
			default_encoded_values[key] = encode_value_for_node(node, node.Value, panel)
		end

		return default_encoded_values[key]
	end

	local function open_value_context_menu(entry, panel)
		local node = entry.node
		local kind = normalize_kind(node.Type or node.Editor)

		if kind == "action" or has_entries(get_node_children(node)) then return end

		sync_selection(entry.key)
		local current_encoded = encode_value_for_node(node, node.Value, panel)
		local default_encoded = get_default_encoded_value(node, entry.key, panel)
		local clipboard_text = clipboard.Get() or ""
		local _, can_paste = decode_value_for_node(node, clipboard_text, node.Value, panel)
		local can_reset = default_encoded ~= nil and default_encoded ~= current_encoded
		local active = Panel.World:GetKeyed("ActiveContextMenu")

		if active and active:IsValid() then active:Remove() end

		local function apply_encoded_value(encoded)
			local decoded, ok = decode_value_for_node(node, encoded, node.Value, panel)

			if not ok then return end

			commit_value(node, decoded, entry.key, entry.path, panel)
		end

		Panel.World:Ensure(
			ContextMenu{
				Key = "ActiveContextMenu",
				Position = system.GetWindow():GetMousePosition():Copy(),
				OnClose = function(ent)
					ent:Remove()
				end,
			}{
				MenuItem{
					Text = "Copy",
					IconSource = icon_sources.copy,
					Disabled = current_encoded == nil,
					OnClick = function()
						if current_encoded ~= nil then clipboard.Set(current_encoded) end
					end,
				},
				MenuItem{
					Text = "Paste",
					IconSource = icon_sources.paste,
					Disabled = not can_paste,
					OnClick = function()
						apply_encoded_value(clipboard_text)
					end,
				},
				MenuItem{
					Text = "Reset",
					IconSource = icon_sources.reset,
					Disabled = not can_reset,
					OnClick = function()
						if default_encoded ~= nil then apply_encoded_value(default_encoded) end
					end,
				},
			}
		)
	end

	local function build_editor_panel(node, path, key)
		if has_entries(get_node_children(node)) then return nil, nil end

		local kind = node.Type or node.Editor
		kind = normalize_kind(kind)
		local vector_info = get_vector_kind_info(kind)
		local control_props = {
			node = node,
			key = key,
			path = path,
			kind = kind,
			commit_value = commit_value,
			trigger_action = trigger_action,
			value_width = value_width,
			row_height = compact_row_height,
			font_size = compact_font_size,
			padding = compact_padding,
			gap = compact_gap,
			number_precision = number_precision,
			get_precision = get_precision,
			get_option_text = get_option_text,
			vector_info = vector_info,
			open_color_picker_window = open_color_picker_window,
			build_number_control = PropertyNumber,
		}

		if kind == "boolean" or type(node.Value) == "boolean" then
			return PropertyBoolean(control_props)
		end

		if kind == "enum" then return PropertyEnum(control_props) end

		if kind == "number" then return PropertyNumber(control_props) end

		if vector_info then return PropertyVector(control_props) end

		if kind == "action" then
			return Button{
				Text = node.ButtonText or node.ActionText or "Run",
				FontSize = compact_font_size,
				Mode = node.Mode or "outline",
				Padding = compact_padding,
				OnClick = function()
					trigger_action(node, key, path)
				end,
			}
		end

		if kind == "material" or kind == "texture" then return PropertyObject(control_props) end

		return PropertyString(control_props)
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

	local function draw_row_background(size, is_selected, is_alternate)
		render2d.SetTexture(nil)

		if is_selected then
			local color = theme.GetColor("property_selection")
			render2d.SetColor(color:Unpack())
			render2d.DrawRect(0, 0, size.x, size.y)
			return
		end

		local color = theme.GetColor(is_alternate and "surface_variant" or "surface")
		render2d.SetColor(color:Unpack())
		render2d.DrawRect(0, 0, size.x, size.y)
	end

	local function build_label_row(entry, is_alternate)
		local info = {
			key = entry.key,
			node = entry.node,
			path = entry.path,
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
				Padding = compact_padding,
			},
			gui_element = {
				Clipping = true,
				OnDraw = function(self)
					local size = self.Owner.transform:GetSize()
					draw_row_background(size, selected_key == entry.key, is_alternate)
				end,
			},
			mouse_input = {
				Cursor = "pointer",
				OnMouseInput = function(self, button, press)
					if not press then return end

					if button == "button_2" then
						open_value_context_menu(entry)
						return true
					end

					if button ~= "button_1" then return end

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
				FontSize = compact_font_size,
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
		local editor_panel, editor_value_panel = build_editor_panel(entry.node, entry.path, entry.key)
		local info = row_infos[entry.key]

		if info then
			info.editor_panel = editor_panel
			info.editor_value_panel = editor_value_panel
		end

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
				Padding = compact_padding,
			},
			gui_element = {
				OnDraw = function(self)
					local size = self.Owner.transform:GetSize()
					draw_row_background(size, false, is_alternate)
				end,
			},
			mouse_input = {
				OnMouseInput = function(self, button, press)
					if button ~= "button_2" or not press then return end

					open_value_context_menu(entry, editor_value_panel)
					return true
				end,
			},
			clickable = true,
		}{
			editor_panel,
		}
	end

	local function build_synced_divider(container)
		local state = {
			is_dragging = false,
			is_hovered = false,
		}

		local function update_draw_alpha(panel)
			if not panel or not panel:IsValid() or not panel.gui_element then return end

			panel.gui_element.DrawAlpha = state.is_dragging and 1 or state.is_hovered and 0.9 or divider_draw_alpha
		end

		local function update_position(panel)
			if not panel or not panel:IsValid() or not container or not container:IsValid() then
				return
			end

			panel.transform:SetPosition(Vec2(shared_key_width - divider_width / 2, 0))
			panel.transform:SetHeight(container.transform:GetHeight())
		end

		return Panel.New{
			Ref = function(self)
				category_dividers[#category_dividers + 1] = self
				self.UpdatePosition = function()
					update_position(self)
				end

				container:AddLocalListener("OnTransformChanged", function()
					update_position(self)
				end)

				container:AddLocalListener("OnLayoutUpdated", function()
					update_position(self)
				end)

				update_position(self)
				update_draw_alpha(self)
			end,
			Name = "PropertyEditorDivider",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = Vec2(divider_width, 0),
			},
			layout = {
				Floating = true,
				GrowWidth = 0,
				GrowHeight = 1,
			},
			mouse_input = {
				Cursor = "horizontal_resize",
				OnHover = function(self, hovered)
					state.is_hovered = hovered
					update_draw_alpha(self.Owner)
				end,
				OnMouseInput = function(self, button, press)
					if button ~= "button_1" then return end

					state.is_dragging = press
					update_draw_alpha(self.Owner)
					return true
				end,
				OnGlobalMouseInput = function(self, button, press)
					if button == "button_1" and not press and state.is_dragging then
						state.is_dragging = false
						update_draw_alpha(self.Owner)
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
					shared_key_width = math.max(10, lpos.x)
					apply_shared_key_width()
					self:SetCursor("horizontal_resize")
					return true
				end,
			},
			gui_element = {
				Color = theme.GetColor("frame_border"),
				DrawAlpha = divider_draw_alpha,
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
						ChildGap = 0,
					},
					gui_element = {
						Clipping = true,
					},
				}(left_children),
				Column{
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						FitWidth = false,
						AlignmentX = "stretch",
						ChildGap = 0,
					},
				}(right_children),
				build_synced_divider(split_row),
			}
		else
			children[#children + 1] = Text{
				Text = "No editable properties.",
				FontSize = compact_font_size,
				Color = "text_disabled",
				IgnoreMouseInput = true,
			}
		end

		return Collapsible{
			Title = get_node_text(node, path),
			Tooltip = node.Description,
			TooltipMaxWidth = 420,
			HeaderMode = "filled",
			HeaderColor = "primary",
			HeaderHeight = get_row_height(node),
			HeaderPadding = compact_padding,
			HeaderGap = compact_gap,
			HeaderFontName = "body",
			HeaderFontSize = compact_font_size,
			HeaderTextColor = "text_button",
			HeaderIconColor = "text_button",
			ContentPadding = "none",
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
		category_dividers = {}

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
			ChildGap = props.ChildGap or compact_gap,
			props.layout,
		},
	}{
		Panel.New{
			Name = "PropertyEditorContent",
			OnSetProperty = theme.OnSetProperty,
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
				FitHeight = true,
			},
			transform = true,
			gui_element = true,
			mouse_input = true,
			clickable = true,
			animation = true,
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
					ChildGap = compact_gap,
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

	function editor:UpdateValueForKey(key, value)
		local info = row_infos[key]

		if not info then return false end

		local node = info.node

		if not node then return false end

		node.Value = value
		local panel = info.editor_value_panel or info.editor_panel

		if panel and panel.IsValid and panel:IsValid() then
			if panel.SetValue then
				panel:SetValue(value, false)
			elseif panel.SetText then
				panel:SetText(value == nil and "" or tostring(value))
			end
		end

		return true
	end

	function editor:RefreshValueForKey(key)
		local info = row_infos[key]

		if not (info and info.node and info.node.GetValue) then return false end

		return self:UpdateValueForKey(key, info.node.GetValue(info.node, key, info.path))
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
