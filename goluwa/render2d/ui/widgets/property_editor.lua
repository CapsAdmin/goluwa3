local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local system = import("goluwa/system.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Collapsible = import("goluwa/render2d/ui/widgets/collapsible.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local ColorPicker = import("goluwa/render2d/ui/widgets/color_picker.lua")
local PropertyBoolean = import("goluwa/render2d/ui/widgets/properties/boolean.lua")
local PropertyEnum = import("goluwa/render2d/ui/widgets/properties/enum.lua")
local PropertyNumber = import("goluwa/render2d/ui/widgets/properties/number.lua")
local PropertyObject = import("goluwa/render2d/ui/widgets/properties/object.lua")
local PropertyString = import("goluwa/render2d/ui/widgets/properties/string.lua")
local PropertyVector = import("goluwa/render2d/ui/widgets/properties/vector.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local objects = import("goluwa/objects/objects.lua")

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

local function is_valid_object(obj)
	local obj_type = type(obj)

	if obj_type ~= "table" and obj_type ~= "userdata" and obj_type ~= "cdata" then
		return false
	end

	return obj and obj.IsValid and obj:IsValid() or false
end

local function get_object_label(obj)
	if not is_valid_object(obj) then return "object" end

	local name = obj.GetName and obj:GetName() or ""
	local key = obj.GetKey and obj:GetKey() or ""
	local base = name ~= "" and name or key ~= "" and key or (obj.Type or "object")

	if name ~= "" and key ~= "" and key ~= name then
		base = name .. " [" .. key .. "]"
	end

	return base
end

local property_types = {
	boolean = {widget = PropertyBoolean},
	enum = {widget = PropertyEnum},
	number = {widget = PropertyNumber, default_precision = 3},
	integer = {widget = PropertyNumber, default_precision = 0},
	vec2 = {
		widget = PropertyVector,
		components = {"x", "y"},
		factory = function(v)
			return Vec2(v[1], v[2])
		end,
	},
	vec3 = {
		widget = PropertyVector,
		components = {"x", "y", "z"},
		factory = function(v)
			return Vec3(v[1], v[2], v[3])
		end,
	},
	ang3 = {
		widget = PropertyVector,
		components = {"x", "y", "z"},
		factory = function(v)
			return Ang3(v[1], v[2], v[3])
		end,
	},
	rect = {
		widget = PropertyVector,
		components = {"x", "y", "w", "h"},
		factory = function(v)
			return Rect(v[1], v[2], v[3], v[4])
		end,
	},
	quat = {
		widget = PropertyVector,
		components = {"x", "y", "z", "w"},
		factory = function(v)
			return Quat(v[1], v[2], v[3], v[4])
		end,
	},
	color = {
		widget = PropertyVector,
		components = {"r", "g", "b", "a"},
		factory = function(v)
			return Color(v[1], v[2], v[3], v[4])
		end,
	},
	string = {widget = PropertyString},
	action = {widget = "button"},
	material = {
		widget = PropertyObject,
		get_display_text = function(material)
			if not material then return "None" end

			if material.vmt_path and material.vmt_path ~= "" then
				return material.vmt_path
			end

			return get_object_label(material)
		end,
		get_preview_texture = function(material)
			if not material then return nil end

			local texture = material.GetAlbedoTexture and material:GetAlbedoTexture() or nil

			if texture and texture.IsReady and not texture:IsReady() then return nil end

			return texture
		end,
	},
	texture = {widget = PropertyObject},
}
local property_type_aliases = {
	render3d_material = "material",
	render_texture = "texture",
}
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
	local value_width = props.ValueWidth or 10
	local compact_font_size = props.FontSize or "S"
	local compact_padding = props.Padding or props.RowPadding or "XS"
	local compact_gap = props.Gap or "none"
	local shared_key_width = props.KeyWidth or 180
	local divider_width = props.DividerWidth or 6
	local divider_draw_alpha = props.DividerDrawAlpha or 1
	local property_change_start = props.OnPropertyChangeStart
	local property_change_end = props.OnPropertyChangeEnd

	local function resolve_padding_rect(padding)
		if type(padding) == "string" then
			return Rect() + theme.active:GetPadding(padding)
		end

		if type(padding) == "number" then return Rect() + padding end

		if padding then return padding end

		return Rect()
	end

	local function get_padding_height(padding)
		local rect = resolve_padding_rect(padding)
		return rect.y + rect.h
	end

	local compact_padding_rect = resolve_padding_rect(compact_padding)
	local label_inset = props.LabelInset ~= nil and props.LabelInset or compact_padding_rect.x
	local editor_value_inset = props.ValueInset ~= nil and props.ValueInset or compact_padding_rect.x
	local header_gap = props.HeaderGap ~= nil and props.HeaderGap or "XXS"
	local compact_row_height = props.RowHeight or
		(
			theme.active:ResolveFontSize(compact_font_size) + get_padding_height(compact_padding)
		)
	local multiline_row_height = props.MultilineRowHeight or compact_row_height * 3
	local collapsed_state = {}
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
				theme.active:ResolveColor("text", "property_selection") or
				theme.active:GetColor("text")
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

		if property_change_start then property_change_start() end

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

		if property_change_end then property_change_end() end
	end

	local function trigger_action(node, key, path)
		sync_selection(key)

		if node.OnAction then node.OnAction(node, key, path) end

		if props.OnAction then props.OnAction(node, key, path) end
	end

	local function get_row_height(node)
		if node.RowHeight then return node.RowHeight end

		if node.Multiline then return node.MultilineHeight or multiline_row_height end

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

	local function open_property_context_menu(entry)
		local info = row_infos[entry.key]
		local panel = info and (info.editor_value_panel or info.editor_panel) or nil

		if not panel then return end

		if panel.IsValid and not panel:IsValid() then return end

		if panel.OpenContextMenu then return panel:OpenContextMenu() end
	end

	local function build_editor_panel(node, path, key)
		if has_entries(get_node_children(node)) then return nil, nil end

		local kind = node.Type or node.Editor
		local control_props = {
			node = node,
			key = key,
			path = path,
			kind = kind,
			commit_value = commit_value,
			trigger_action = trigger_action,
			value_width = value_width,
			row_height = get_row_height(node),
			multiline_row_height = multiline_row_height,
			padding = node.Padding or compact_padding,
			gap = node.Gap or compact_gap,
			font_size = compact_font_size,
			number_precision = number_precision,
			get_precision = get_precision,
			vector_info = nil,
			open_color_picker_window = open_color_picker_window,
			build_number_control = PropertyNumber,
			sync_selection = sync_selection,
		}
		local type_info = property_types[kind]

		if not type_info and type(node.Value) == "boolean" then
			type_info = property_types.boolean
		end

		if type_info then
			if type_info.components then
				control_props.vector_info = {components = type_info.components, factory = type_info.factory}
			end

			if type_info.widget == "button" then
				return Button{
					Text = node.ButtonText or node.ActionText or "Run",
					FontSize = compact_font_size,
					Mode = node.Mode or "outline",
					OnClick = function()
						trigger_action(node, key, path)
					end,
				}
			end

			return type_info.widget(control_props)
		end

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

	local function build_label_row(entry, is_alternate)
		local info = {
			key = entry.key,
			node = entry.node,
			path = entry.path,
			is_hovered = false,
		}
		row_infos[entry.key] = info
		return Panel.New{
			Ref = function(self)
				info.panel = self
			end,
			Name = "PropertyLabelRow",
			transform = true,
			layout = {
				Direction = "x",
				GrowWidth = 1,
				MinSize = Vec2(0, get_row_height(entry.node)),
				MaxSize = Vec2(0, get_row_height(entry.node)),
				Padding = Rect(label_inset, 0, 0, 0),
				AlignmentY = "center",
			},
			visual = {
				Clipping = true,
				OnDraw = function(self)
					self.Owner:SetState("selected", selected_key == entry.key)
					self.Owner:SetState("alternate", is_alternate)
					self.Owner:SetState("hovered", info.is_hovered)
					theme.active:Draw(self.Owner)
				end,
			},
			mouse_input = {
				Cursor = "pointer",
				OnHover = function(_, hovered)
					info.is_hovered = hovered
				end,
				OnMouseInput = function(self, button, press)
					if not press then return end

					if button == "button_2" then
						return open_property_context_menu(entry)
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
			transform = true,
			layout = {
				Direction = "x",
				GrowWidth = 1,
				MinSize = Vec2(0, get_row_height(entry.node)),
				MaxSize = Vec2(0, get_row_height(entry.node)),
				Padding = Rect(0, 0, 0, 0),
				AlignmentY = entry.node.Multiline and "start" or "center",
			},
			visual = {
				OnDraw = function(self)
					self.Owner:SetState("selected", false)
					self.Owner:SetState("alternate", is_alternate)
					self.Owner:SetState("hovered", info and info.is_hovered or false)
					theme.active:Draw(self.Owner)
				end,
			},
			mouse_input = {
				OnHover = function(_, hovered)
					if info then info.is_hovered = hovered end
				end,
				OnMouseInput = function(self, button, press)
					if button ~= "button_2" or not press then return end

					return open_property_context_menu(entry)
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
			if not panel or not panel:IsValid() or not panel.visual then return end

			panel.visual.DrawAlpha = state.is_dragging and 1 or state.is_hovered and 0.9 or divider_draw_alpha
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
			visual = {
				DrawAlpha = divider_draw_alpha,
				OnDraw = function(self)
					theme.active:Draw(self.Owner)
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
				transform = true,
				layout = {
					Direction = "x",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentY = "stretch",
					ChildGap = 0,
				},
				visual = true,
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
					visual = {
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
			HeaderButtonColor = "primary",
			HeaderMode = "filled",
			HeaderHeight = get_row_height(node),
			HeaderPadding = node.HeaderPadding or compact_padding,
			HeaderGap = node.HeaderGap ~= nil and node.HeaderGap or header_gap,
			HeaderFontName = "body",
			HeaderFontSize = compact_font_size,
			HeaderTextColor = "text_on_accent",
			HeaderIconColor = "text_on_accent",
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
			FitHeight = true,
			AlignmentX = "stretch",
			props.layout,
		},
	}{
		Panel.New{
			Name = "PropertyEditorContent",
			layout = {
				GrowWidth = 1,
				FitHeight = true,
			},
			transform = true,
			visual = true,
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
					ChildGap = 0,
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

		if not info then return false end

		if not info.node then return false end

		if not info.node.GetValue then return false end

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

	function editor:ExpandToKey(key)
		local _, _, category_key = find_node_by_key(items, key)

		if category_key then
			local category = category_refs[category_key]

			if category and category:IsValid() then category:SetCollapsed(false) end
		end

		return self
	end

	function editor:Rebuild()
		rebuild_categories()
		return self
	end

	local function get_component_name(entity, component)
		for name, value in pairs(entity.component_map or {}) do
			if value == component then return name end
		end

		return component.Type or "component"
	end

	local function build_property_node(target, category_key, category_name, info, hooks)
		local resolved_type = property_type_aliases[info.type] or info.type
		local node_type = info.enums and "enum" or resolved_type
		local value = objects.GetProperty(target, info.var_name)
		local node = {
			Type = node_type,
			Key = category_key .. "/" .. info.var_name,
			Text = info.var_name,
			Value = value,
			Default = info.copy and info.copy() or info.default,
			GetValue = function()
				return objects.GetProperty(target, info.var_name)
			end,
		}
		local display_type = node_type

		if info.validate == "integer" then display_type = "integer" end

		local type_info = property_types[display_type]

		if type_info then
			if type_info.default_precision then
				node.Precision = type_info.default_precision
			end

			if type_info.get_display_text then
				node.GetDisplayText = type_info.get_display_text
			end

			if type_info.get_preview_texture then
				node.GetPreviewTexture = type_info.get_preview_texture
			end
		end

		if node_type == "material" then
			node.OnActionButton = function(_, key, path, panel, commit_value)
				event.Call("PickObject", node_type, function(obj)
					commit_value(node, obj, key, path, panel)
				end)
			end
		elseif node_type == "texture" then
			node.OnActionButton = function(_, key, path, panel, commit_value)
				event.Call("PickObject", node_type, function(obj)
					commit_value(node, obj, key, path, panel)
				end)
			end
		end

		if node_type == "enum" and info.enums then
			node.Options = {}

			for _, option in ipairs(info.enums) do
				node.Options[#node.Options + 1] = {
					Text = tostring(option),
					Value = option,
				}
			end
		end

		node.OnChange = function(_, next_value)
			if node_type == "integer" or info.validate == "integer" then
				next_value = math.floor((tonumber(next_value) or 0) + 0.5)
			end

			if hooks and hooks.OnPropertyChangeStart then
				hooks.OnPropertyChangeStart(target, info, next_value)
			end

			local ok, err = pcall(function()
				objects.SetProperty(target, info.var_name, next_value)
			end)

			if hooks and hooks.OnPropertyChangeEnd then
				hooks.OnPropertyChangeEnd(target, info, next_value, ok, err)
			end

			if not ok then
				print(
					"editor failed to set property",
					target,
					category_name,
					info.var_name,
					err
				)
			end

			return ok
		end
		return node
	end

	local property_change_sync_blocked = 0
	local property_node_hooks = {
		OnPropertyChangeStart = function()
			property_change_sync_blocked = property_change_sync_blocked + 1
		end,
		OnPropertyChangeEnd = function()
			property_change_sync_blocked = math.max(0, property_change_sync_blocked - 1)
		end,
	}
	local listeners = {}

	function editor:SetObject(obj)
		do
			for i = 1, #listeners do
				listeners[i]()
			end

			list.clear(listeners)
		end

		local items = {}

		if is_valid_object(obj) then
			local categories = {}

			if obj.component_list then
				for _, component in ipairs(obj.component_list or {}) do
					if component and component.IsValid and component:IsValid() then
						local component_name = get_component_name(obj, component)
						categories[#categories + 1] = {
							object = component,
							key = obj:GetGUID() .. "/" .. component_name,
							name = component_name,
						}
					end
				end
			else
				categories[#categories + 1] = {
					object = obj,
					key = obj:GetGUID() .. "/properties",
					name = get_object_label(obj),
				}
			end

			table.sort(categories, function(a, b)
				return a.name < b.name
			end)

			for _, category in ipairs(categories) do
				local children = {}

				for _, info in ipairs(objects.GetStorableVariables(category.object)) do
					children[#children + 1] = build_property_node(category.object, category.key, category.name, info, property_node_hooks)
				end

				items[#items + 1] = {
					Key = category.key,
					Text = category.name,
					Expanded = true,
					Children = children,
				}
				listeners[#listeners + 1] = category.object:AddPropertyListener(function(_, key)
					if not self:IsValid() then return end

					if property_change_sync_blocked > 0 then return end

					self:RefreshValueForKey(category.key .. "/" .. key)
				end)
			end
		end

		self:SetItems(items)
	end

	if external_ref then external_ref(editor) end

	return editor
end
