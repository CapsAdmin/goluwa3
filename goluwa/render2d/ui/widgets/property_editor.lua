local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Collapsible = import("goluwa/render2d/ui/widgets/collapsible.lua")
local ColorPicker = import("goluwa/render2d/ui/widgets/color_picker.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local PropertyAsset = import("goluwa/render2d/ui/widgets/properties/asset.lua")
local PropertyBoolean = import("goluwa/render2d/ui/widgets/properties/boolean.lua")
local PropertyCode = import("goluwa/render2d/ui/widgets/properties/code.lua")
local PropertyDivider = import("goluwa/render2d/ui/widgets/properties/divider.lua")
local PropertyEnum = import("goluwa/render2d/ui/widgets/properties/enum.lua")
local PropertyNumber = import("goluwa/render2d/ui/widgets/properties/number.lua")
local PropertyObject = import("goluwa/render2d/ui/widgets/properties/object.lua")
local PropertyRow = import("goluwa/render2d/ui/widgets/properties/row.lua")
local PropertyText = import("goluwa/render2d/ui/widgets/properties/text.lua")
local PropertyValue = import("goluwa/render2d/ui/widgets/properties/value.lua")
local PropertyVector = import("goluwa/render2d/ui/widgets/properties/vector.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("property_editor")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentX = "stretch",
}
META.CMP.visual = {}
META.CMP.mouse_input = {}
META.CMP.clickable = {}
META.CMP.animation = {}
META:StartStorable()
META:GetSet("Items", nil)
META:GetSet("CategoryOrder", nil)
META:GetSet("SelectedKey", nil)
META:GetSet("NumberPrecision", 2)
META:GetSet("ValueWidth", 10)
META:GetSet("FontSize", nil)
META:GetSet("RowPadding", nil)
META:GetSet("Gap", nil)
META:GetSet("KeyWidth", 180)
META:GetSet("DividerWidth", nil)
META:GetSet("DividerDrawAlpha", 1)
META:GetSet("RowHeight", nil)
META:GetSet("MultilineRowHeight", nil)
META:GetSet("LabelInset", nil)
META:GetSet("HeaderGap", nil)
META:EndStorable()

function META.OnChange(node, value, key, path) end

function META.OnSelect(node, key, path) end

function META.OnAction(node, key, path) end

-- extra right click items for a property of an object, a list of {Text, OnClick} or nothing
function META.OnContextActions(object, info) end

-- a small label for the header of a component, {Text, Color, HeaderColor, Tooltip} or nothing
function META.OnGetCategoryBadge(object, name) end

-- a small label and a label color for a property of an object, {Text, Color, Tooltip} or nothing
function META.OnGetPropertyBadge(object, info) end

function META.OnPropertyChangeStart() end

function META.OnPropertyChangeEnd() end

local function build_path(parent_path, index)
	if parent_path then return parent_path .. "/" .. index end

	return tostring(index)
end

local function has_entries(list)
	return list and next(list) ~= nil
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
end

local function find_first_leaf(nodes, parent_path)
	for index, node in ipairs(nodes or {}) do
		local path = build_path(parent_path, index)

		if not has_entries(get_node_children(node)) then return node, path end

		local found_node, found_path = find_first_leaf(get_node_children(node), path)

		if found_node then return found_node, found_path end
	end
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

local function get_material_display_text(material)
	if not material then return "None" end

	if material.vmt_path and material.vmt_path ~= "" then
		return material.vmt_path
	end

	return get_object_label(material)
end

local function get_material_preview_texture(material)
	if not material then return nil end

	local texture = material.GetAlbedoTexture and material:GetAlbedoTexture() or nil

	if texture and texture.IsReady and not texture:IsReady() then return nil end

	return texture
end

local function on_control_change(value, old_value, control)
	control.Editor:commit_value(control.Node, value, control.PropertyKey, control.PropertyPath, control)
end

local function on_before_context_menu(control)
	control.Editor:sync_selection(control.PropertyKey)
end

local function on_action_click(button)
	local editor = button.Editor
	editor:trigger_action(button.Node, button.PropertyKey, button.PropertyPath)
end

local function on_object_action(control)
	local node = control.Node
	node.OnActionButton(
		node,
		control.PropertyKey,
		control.PropertyPath,
		control,
		control.Editor.commit_value_callback
	)
end

local function on_object_draw_action(control, button, size)
	local node = control.Node
	node.OnDrawActionButton(node, button, size, node.Value, control.PropertyKey, control.PropertyPath)
end

local function on_swatch_click(control)
	local node = control.Node
	local editor = control.Editor

	if node.OnSwatchClick then
		node.OnSwatchClick(node, control:GetValue(), control.PropertyKey, control.PropertyPath, control)
	else
		editor:open_color_picker_window(control)
	end
end

local function on_category_toggle(collapsed, category)
	category.Editor._collapsed_state[category.CategoryKey] = collapsed
end

local function get_string_tooltip(control)
	local value = control.Node.Value

	if value == nil then return "" end

	return tostring(value)
end

local property_types = {
	boolean = {},
	enum = {},
	number = {},
	integer = {},
	string = {},
	asset = {},
	action = {},
	vec2 = {
		components = {"x", "y"},
		factory = function(v)
			return Vec2(v[1], v[2])
		end,
	},
	vec3 = {
		components = {"x", "y", "z"},
		factory = function(v)
			return Vec3(v[1], v[2], v[3])
		end,
	},
	vec4 = {
		components = {"x", "y", "z", "w"},
		factory = function(v)
			return Vec4(v[1], v[2], v[3], v[4])
		end,
	},
	ang3 = {
		components = {"x", "y", "z"},
		factory = function(v)
			return Ang3(v[1], v[2], v[3])
		end,
	},
	rect = {
		components = {"x", "y", "w", "h"},
		factory = function(v)
			return Rect(v[1], v[2], v[3], v[4])
		end,
	},
	quat = {
		components = {"x", "y", "z", "w"},
		factory = function(v)
			return Quat(v[1], v[2], v[3], v[4])
		end,
	},
	color = {
		components = {"r", "g", "b", "a"},
		factory = function(v)
			return Color(v[1], v[2], v[3], v[4])
		end,
	},
	material = {
		object = true,
		default_precision = nil,
		get_display_text = get_material_display_text,
		get_preview_texture = get_material_preview_texture,
	},
	texture = {object = true},
}
property_types.number.default_precision = 3
property_types.integer.default_precision = 0
local property_type_aliases = {
	render3d_material = "material",
	render_texture = "texture",
}

function META.PropDefaults()
	return {Items = {}}
end

function META:update_metrics()
	local font_size = self.FontSize or "S"
	local padding = self.RowPadding or "XS"
	self._font_size = font_size
	self._padding = padding
	self._gap = self.Gap or "none"
	self._padding_rect = type(padding) == "string" and
		Rect() + theme.active:GetPadding(padding)
		or
		type(padding) == "number" and
		Rect() + padding or
		padding
	self._row_height = self.RowHeight or
		(
			theme.active:ResolveFontSize(font_size) + self._padding_rect.y + self._padding_rect.h
		)
	self._multiline_row_height = self.MultilineRowHeight or self._row_height * 3
	self._label_inset = self.LabelInset or self._padding_rect.x
	self._key_width = self.KeyWidth
	self._divider_width = theme.active:ResolveSize(self.DividerWidth or "XS")
end

function META:OnThemeChanged()
	self:update_metrics()
	self:rebuild_categories()
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self:update_metrics()
	self._collapsed_state = {}
	self._category_refs = {}
	self._category_key_columns = {}
	self._category_dividers = {}
	self._row_infos = {}
	self._listeners = {}
	self._property_change_sync_blocked = 0
	self._selected_key = self.SelectedKey
	self._tab_buttons = {}
	self._tab_bar = Row{
		Parent = self,
		IsInternal = true,
		layout = {
			GrowWidth = 1,
			FitHeight = true,
			ChildGap = "XXS",
			Padding = "XXS",
		},
	}
	self._content = Column{
		Parent = self,
		IsInternal = true,
		layout = {
			GrowWidth = 1,
			FitHeight = true,
			AlignmentX = "stretch",
			ChildGap = 0,
		},
	}
	self.commit_value_callback = function(node, value, key, path, panel)
		return self:commit_value(node, value, key, path, panel)
	end
	self:rebuild_categories()
end

function META:SetItems(items)
	self._items = items or {}

	if self._content then self:rebuild_categories() end

	return self
end

function META:GetItems()
	return self._items
end

function META:GetKeyWidth()
	return self._key_width
end

function META:SetKeyWidth(width)
	self._key_width = width
	self:apply_shared_key_width()
	return self
end

function META:SetSelectedKey(key)
	self:sync_selection(key)
	return self
end

function META:GetSelectedKey()
	return self._selected_key
end

function META:GetPanelForKey(key)
	local info = self._row_infos[key]
	return info and info.panel or nil
end

function META:Rebuild()
	self:rebuild_categories()
	return self
end

function META:ExpandAll()
	for _, category in pairs(self._category_refs) do
		category:SetCollapsed(false)
	end

	return self
end

function META:CollapseAll()
	for _, category in pairs(self._category_refs) do
		category:SetCollapsed(true)
	end

	return self
end

function META:ExpandToKey(key)
	local _, _, category_key = find_node_by_key(self._items, key)

	if category_key then
		local category = self._category_refs[category_key]

		if category then category:SetCollapsed(false) end

		for _, item in ipairs(self._items) do
			if get_node_key(item) == category_key then
				for _, child in ipairs(get_node_children(item)) do
					if child.IsGroup and find_node_by_key(child.Children, key) then
						self._category_refs[child.Key]:SetCollapsed(false)
					end
				end
			end
		end
	end

	return self
end

function META:UpdateValueForKey(key, value)
	local info = self._row_infos[key]

	if not info then return false end

	info.node.Value = value
	local control = info.editor_panel

	if control and control.SetValue then control:SetValue(value, false) end

	return true
end

function META:RefreshValueForKey(key)
	local info = self._row_infos[key]

	if not (info and info.node.GetValue) then return false end

	return self:UpdateValueForKey(key, info.node.GetValue(info.node, key, info.path))
end

function META:refresh_row_text(info)
	if not info or not info.text then return end

	local node = info.node
	local color

	if self._selected_key == info.key then
		color = theme.active:ResolveColor("text", "property_selection")
	elseif node.IsEnabled and not node.IsEnabled() then
		color = theme.active:GetColor("text_disabled")
	else
		color = theme.active:GetColor(node.LabelColor or "text")
	end

	info.text.text:SetColor(color)
end

function META:refresh_all_row_text()
	for _, info in pairs(self._row_infos) do
		self:refresh_row_text(info)
	end
end

function META:sync_selection(key)
	if not key then
		self._selected_key = nil
		self.OnSelect(nil, nil, nil)
		return
	end

	local previous_key = self._selected_key
	self._selected_key = key
	local node, path, category_key = find_node_by_key(self._items, key)

	if category_key then
		local category = self._category_refs[category_key]

		if category then category:SetCollapsed(false) end
	end

	self:refresh_row_text(self._row_infos[previous_key])
	self:refresh_row_text(self._row_infos[key])
	self.OnSelect(node, key, path)
end

function META:commit_value(node, value, key, path, panel)
	local applied_value = value
	local applied = true
	self.OnPropertyChangeStart()
	node.Value = applied_value

	if panel and panel.SetValue then panel:SetValue(applied_value, false) end

	self:sync_selection(key)

	if node.OnChange then
		applied = node.OnChange(node, value, key, path) ~= false
	end

	if not applied and node.GetValue then
		applied_value = node.GetValue(node, key, path)
		node.Value = applied_value

		if panel and panel.SetValue then panel:SetValue(applied_value, false) end
	end

	if applied then self.OnChange(node, applied_value, key, path) end

	self.OnPropertyChangeEnd()
end

function META:trigger_action(node, key, path)
	self:sync_selection(key)

	if node.OnAction then node.OnAction(node, key, path) end

	self.OnAction(node, key, path)
end

function META:open_context_menu(info)
	local control = info.editor_panel

	if control and control.OpenContextMenu then return control:OpenContextMenu() end
end

function META:get_row_height(node)
	if node.RowHeight then return node.RowHeight end

	if node.Multiline then
		return node.MultilineHeight or self._multiline_row_height
	end

	return self._row_height
end

function META:apply_shared_key_width()
	for _, column in ipairs(self._category_key_columns) do
		column.layout:SetMinSize(Vec2(self._key_width, 0))
		column.layout:SetMaxSize(Vec2(self._key_width, 0))
		column.layout:InvalidateLayout(true)
	end

	for _, divider in ipairs(self._category_dividers) do
		divider:update_position()
	end
end

function META:open_color_picker_window(control)
	local node = control.Node
	local window_size = Vec2(380, 430)
	local world_size = Panel.World.transform:GetSize()
	local mouse_pos = system.GetWindow():GetMousePosition():Copy() + Vec2(16, 16)
	mouse_pos.x = math.min(mouse_pos.x, math.max(world_size.x - window_size.x, 0))
	mouse_pos.y = math.min(mouse_pos.y, math.max(world_size.y - window_size.y, 0))
	Panel.World:Ensure(
		Window{
			Key = "PropertyColorPickerWindow/" .. control.PropertyKey,
			Title = "COLOR: " .. get_node_text(node, control.PropertyPath),
			Size = window_size,
			Position = mouse_pos,
		}{
			ColorPicker{
				Value = control:GetValue(),
				Control = control,
				OnChange = function(color, old_color, picker)
					picker.Control:SetValue(picker.Control.Factory(color), true)
				end,
				layout = {GrowWidth = 1},
			},
		}
	)
end

function META:create_control(node, path, key)
	local kind = node.Type or node.Editor
	kind = property_type_aliases[kind] or kind
	local type_info = property_types[kind]

	if not type_info and type(node.Value) == "boolean" then
		kind = "boolean"
		type_info = property_types.boolean
	end

	local padding = node.Padding or self._padding
	local gap = node.Gap or self._gap
	local row_height = self:get_row_height(node)
	local size = Vec2(self.ValueWidth, row_height)
	local shared = {
		Editor = self,
		Node = node,
		PropertyKey = key,
		PropertyPath = path,
		Default = node.Default,
		DefaultEncoded = node.DefaultEncoded,
		OnChange = on_control_change,
		OnBeforeContextMenu = on_before_context_menu,
	}
	local control

	if kind == "action" then
		return Button{
			Editor = self,
			Node = node,
			PropertyKey = key,
			PropertyPath = path,
			Text = node.ButtonText or node.ActionText or "Run",
			FontSize = self._font_size,
			Padding = padding,
			Mode = node.Mode or "outline",
			OnClick = on_action_click,
		}
	elseif kind == "boolean" then
		shared.Value = node.Value == true
		shared.FontSize = self._font_size
		shared.Padding = padding
		shared.ChildGap = node.Gap
		control = PropertyBoolean(shared)
	elseif kind == "enum" then
		shared.Value = node.Value
		shared.Options = node.Options or {}
		shared.Text = node.Value == nil and "Select..." or tostring(node.Value)
		shared.FontSize = self._font_size
		shared.Searchable = node.Searchable ~= false
		shared.Padding = padding
		shared.layout = {
			MinSize = size,
			MaxSize = Vec2(0, size.y),
			GrowWidth = 1,
		}
		control = PropertyEnum(shared)
	elseif kind == "number" or kind == "integer" then
		local is_integer = (node.NumberType or "float") == "int" or kind == "integer"
		shared.Value = tonumber(node.Value) or 0
		shared.Min = node.Min
		shared.Max = node.Max
		shared.Step = node.Step or (is_integer and 1 or 0.1)
		shared.Integer = is_integer
		shared.Precision = node.Precision ~= nil and node.Precision or self.NumberPrecision
		shared.DragStep = node.DragStep
		shared.DragPrecisionBoost = node.DragPrecisionBoost
		shared.ShowStepper = node.ShowStepper == true
		shared.ShowSlider = node.ShowSlider == true
		shared.Cursor = node.Cursor or "vertical_resize"
		shared.Size = size
		shared.MinSize = size
		shared.MaxSize = Vec2(0, size.y)
		shared.Padding = padding
		shared.FontSize = self._font_size
		shared.layout = {FitWidth = false}
		control = PropertyNumber(shared)
	elseif type_info and type_info.components then
		shared.Value = node.Value
		shared.Components = type_info.components
		shared.Factory = type_info.factory
		shared.Min = node.Min
		shared.Max = node.Max
		shared.Precision = node.Precision ~= nil and node.Precision or self.NumberPrecision
		shared.DragStep = node.DragStep
		shared.DragPrecisionBoost = node.DragPrecisionBoost
		shared.Cursor = node.Cursor
		shared.Swatch = kind == "color"
		shared.SwatchSize = node.SwatchSize
		shared.ComponentWidth = node.ComponentWidth
		shared.ValueWidth = self.ValueWidth
		shared.RowHeight = row_height
		shared.FontSize = self._font_size
		shared.FieldPadding = padding
		shared.ChildGap = gap
		shared.OnSwatchClick = on_swatch_click
		shared.layout = {
			MinSize = size,
			MaxSize = Vec2(0, size.y),
		}
		control = PropertyVector(shared)
	elseif type_info and type_info.object then
		shared.Value = node.Value
		shared.RowHeight = row_height
		shared.FontSize = self._font_size
		shared.FieldPadding = padding
		shared.ChildGap = gap
		shared.ActionButtonSize = node.ActionButtonSize
		shared.ActionPreviewPadding = node.ActionPreviewPadding
		shared.GetDisplayText = node.GetDisplayText or type_info.get_display_text
		shared.GetActionTexture = node.GetActionTexture or node.GetPreviewTexture or type_info.get_preview_texture
		shared.OnDrawActionButton = node.OnDrawActionButton and on_object_draw_action or nil
		shared.OnActionButton = on_object_action
		shared.layout = {
			MinSize = size,
			MaxSize = Vec2(0, size.y),
		}
		control = PropertyObject(shared)
	elseif kind == "asset" then
		shared.Value = node.Value == nil and "" or tostring(node.Value)
		shared.AssetCategory = node.AssetCategory
		shared.Tooltip = get_string_tooltip
		shared.TooltipMaxWidth = 360
		shared.FontSize = self._font_size
		shared.Padding = padding
		shared.Size = size
		shared.MinSize = size
		shared.MaxSize = Vec2(0, size.y)
		control = PropertyAsset(shared)
	elseif kind == "code" then
		shared.Value = node.Value == nil and "" or tostring(node.Value)
		shared.Language = node.CodeLanguage
		shared.OnGetStatus = node.GetStatus
		shared.FontSize = self._font_size
		shared.FieldPadding = padding
		shared.RowHeight = row_height
		shared.layout = {
			MinSize = size,
			MaxSize = Vec2(0, size.y),
		}
		control = PropertyCode(shared)
	elseif node.Multiline then
		shared.Value = node.Value == nil and "" or tostring(node.Value)
		shared.ApplyText = node.ApplyText
		shared.FontSize = self._font_size
		shared.FieldPadding = padding
		shared.ValueWidth = self.ValueWidth
		shared.RowHeight = row_height
		shared.Tooltip = kind == "string" and get_string_tooltip or nil
		shared.TooltipMaxWidth = 360
		shared.ChildGap = gap
		control = PropertyText(shared)
	else
		shared.Value = node.Value == nil and "" or tostring(node.Value)
		shared.Tooltip = kind == "string" and get_string_tooltip or nil
		shared.TooltipMaxWidth = 360
		shared.FontSize = self._font_size
		shared.Padding = padding
		shared.Size = size
		shared.MinSize = size
		shared.MaxSize = Vec2(0, size.y)
		shared.layout = {FitWidth = false}
		control = PropertyValue(shared)
	end

	if control.DefaultEncoded == nil and control.Default == nil then
		control:SetDefaultEncoded(control:EncodeValue())
	end

	return control
end

function META:collect_rows(nodes, parent_path, label_prefix, out, first, last)
	for index = first or 1, last or #nodes do
		local node = nodes[index]
		local path = build_path(parent_path, index)
		local label = label_prefix and
			(
				label_prefix .. " / " .. get_node_text(node, path)
			)
			or
			get_node_text(node, path)

		if has_entries(get_node_children(node)) then
			self:collect_rows(get_node_children(node), path, label, out)
		else
			out[#out + 1] = {
				node = node,
				path = path,
				key = get_node_key(node, path),
				label = label,
			}
		end
	end
end

function META:build_rows_panel(entries)
	local left_children = {}
	local right_children = {}

	for i, entry in ipairs(entries) do
		local alternate = i % 2 == 0
		local info = {
			key = entry.key,
			node = entry.node,
			path = entry.path,
			is_hovered = false,
		}
		self._row_infos[entry.key] = info
		local height = self:get_row_height(entry.node)
		info.panel = PropertyRow{
			Name = "property_label_row",
			Editor = self,
			Info = info,
			Alternate = alternate,
			Selectable = true,
			Tooltip = entry.node.Description,
			TooltipMaxWidth = 420,
			layout = {
				MinSize = Vec2(0, height),
				MaxSize = Vec2(0, height),
				Padding = Rect(self._label_inset, 0, 0, 0),
			},
		}
		info.text = Text{
			Parent = info.panel,
			Text = entry.label,
			FontSize = self._font_size,
			Elide = true,
			ElideString = "...",
			IgnoreMouseInput = true,
			layout = {
				GrowWidth = 1,
				MinSize = Vec2(10, 0),
				FitWidth = false,
				FitHeight = true,
			},
		}
		local badge = entry.node.Badge

		if badge then
			Text{
				Parent = info.panel,
				Text = badge.Text,
				FontSize = self._font_size,
				Color = badge.Color,
				IgnoreMouseInput = true,
				layout = {FitWidth = true, FitHeight = true},
			}
		end

		self:refresh_row_text(info)
		left_children[i] = info.panel
		info.editor_panel = self:create_control(entry.node, entry.path, entry.key)
		local editor_row = PropertyRow{
			Name = "property_editor_row",
			Editor = self,
			Info = info,
			Alternate = alternate,
			Tooltip = entry.node.Description,
			TooltipMaxWidth = 420,
			layout = {
				MinSize = Vec2(0, height),
				MaxSize = Vec2(0, height),
				AlignmentY = entry.node.Multiline and "start" or "center",
			},
		}
		editor_row:AddChild(info.editor_panel)
		right_children[i] = editor_row
	end

	local split_row = Panel.New{
		Name = "property_split_row",
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
	local key_column = Column{
		layout = {
			GrowWidth = 0,
			FitHeight = true,
			FitWidth = false,
			AlignmentX = "stretch",
			ChildGap = 0,
			MinSize = Vec2(self._key_width, 0),
			MaxSize = Vec2(self._key_width, 0),
		},
		visual = {Clipping = true},
	}(left_children)
	self._category_key_columns[#self._category_key_columns + 1] = key_column
	split_row{
		key_column,
		Column{
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				FitWidth = false,
				AlignmentX = "stretch",
				ChildGap = 0,
			},
		}(right_children),
	}
	self._category_dividers[#self._category_dividers + 1] = PropertyDivider{
		Parent = split_row,
		Editor = self,
		Container = split_row,
		Thickness = self._divider_width,
		RestAlpha = self.DividerDrawAlpha,
	}
	return split_row
end

function META:build_group_panel(node, path)
	local key = get_node_key(node, path)
	local entries = {}
	self:collect_rows(get_node_children(node), path, nil, entries)
	local collapsed = self._collapsed_state[key]

	if collapsed == nil then collapsed = node.Collapsed == true end

	local group = Collapsible{
		Editor = self,
		CategoryKey = key,
		Title = get_node_text(node, path),
		HeaderButtonColor = "purple",
		HeaderMode = "filled",
		HeaderHeight = self:get_row_height(node),
		HeaderPadding = node.HeaderPadding or self._padding,
		HeaderGap = self.HeaderGap or "XXS",
		HeaderFontSize = self._font_size,
		HeaderTextColor = "text_on_accent",
		Padding = "none",
		Collapsed = collapsed,
		OnToggle = on_category_toggle,
	}{self:build_rows_panel(entries)}
	self._category_refs[key] = group
	return group
end

function META:build_category_panel(node, path, key)
	local collapsed = self._collapsed_state[key]
	local children = {}

	if collapsed == nil then
		collapsed = node.Collapsed == true or node.Expanded == false
	end

	local nodes = get_node_children(node)
	local run_start = 1

	for index = 1, #nodes + 1 do
		local group = nodes[index]

		if index == #nodes + 1 or group.IsGroup then
			if index > run_start then
				local entries = {}
				self:collect_rows(nodes, path, nil, entries, run_start, index - 1)
				children[#children + 1] = self:build_rows_panel(entries)
			end

			run_start = index + 1

			if group then
				children[#children + 1] = self:build_group_panel(group, build_path(path, index))
			end
		end
	end

	if #children == 0 then
		children[1] = Text{
			Text = "No editable properties.",
			FontSize = self._font_size,
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
	end

	-- a badge that only says which tab the category is on has nothing to add once the tabs are shown
	local badge = node.Badge

	if badge and badge.HideWithTabs and self._tabs_visible then badge = nil end

	local category = Collapsible{
		Editor = self,
		CategoryKey = key,
		Title = get_node_text(node, path),
		Tooltip = node.Description,
		TooltipMaxWidth = 420,
		Badge = badge and badge.Text,
		BadgeColor = badge and badge.Color,
		HeaderButtonColor = node.Badge and node.Badge.HeaderColor or "primary",
		HeaderMode = "filled",
		HeaderHeight = self:get_row_height(node),
		HeaderPadding = node.HeaderPadding or self._padding,
		HeaderGap = node.HeaderGap ~= nil and node.HeaderGap or self.HeaderGap or "XXS",
		HeaderFontSize = self._font_size,
		HeaderTextColor = "text_on_accent",
		Padding = "none",
		Collapsed = collapsed,
		OnToggle = on_category_toggle,
	}(children)
	self._category_refs[key] = category
	return category
end

local function on_tab_click(button)
	button.Editor:SetActiveTab(button.Tab)
	return true
end

function META:SetActiveTab(name)
	self._active_tab = name
	self:rebuild_categories()
	return self
end

function META:GetActiveTab()
	return self._active_tab
end

-- categories can name a Tab, with more than one name the tabs are shown above and only the categories of the active one are listed
function META:update_tabs()
	local tabs = {}
	local seen = {}

	for _, node in ipairs(self._items) do
		if node.Tab and not seen[node.Tab] then
			seen[node.Tab] = true
			tabs[#tabs + 1] = node.Tab
		end
	end

	self._tabs_visible = #tabs >= 2

	if #tabs < 2 then
		self._tab_bar:RemoveChildren()
		self._tab_buttons = {}
		self._tab_key = nil
		return nil
	end

	-- the tab that was chosen last is kept for the next object that has it, until then the first one is shown
	local active = seen[self._active_tab] and self._active_tab or tabs[1]
	local key = table.concat(tabs, "\0")

	-- the buttons are kept while the tabs stay the same, a click must not remove the button it came from
	if key ~= self._tab_key then
		self._tab_key = key
		self._tab_bar:RemoveChildren()
		self._tab_buttons = {}

		for _, name in ipairs(tabs) do
			self._tab_buttons[name] = Button{
				Editor = self,
				Tab = name,
				Text = name,
				Mode = "outline",
				FontSize = self._font_size,
				OnClick = on_tab_click,
			}
			self._tab_bar:AddChild(self._tab_buttons[name])
		end
	end

	for name, button in pairs(self._tab_buttons) do
		button:SetActive(name == active)
	end

	return active
end

function META:rebuild_categories()
	self._row_infos = {}
	self._category_refs = {}
	self._category_key_columns = {}
	self._category_dividers = {}
	self._content:RemoveChildren()
	local active_tab = self:update_tabs()
	local visible = {}

	for index, node in ipairs(self._items) do
		if not active_tab or node.Tab == active_tab then
			local path = build_path(nil, index)
			visible[#visible + 1] = node
			self._content:AddChild(self:build_category_panel(node, path, get_node_key(node, path)))
		end
	end

	if self._selected_key and not find_node_by_key(visible, self._selected_key) then
		self._selected_key = nil
	end

	if not self._selected_key then
		local first_node, first_path = find_first_leaf(visible)
		self._selected_key = first_node and get_node_key(first_node, first_path) or nil
	end

	if self._selected_key then
		self:sync_selection(self._selected_key)
	else
		self.OnSelect(nil, nil, nil)
	end

	self:apply_shared_key_width()
end

do
	local function get_component_name(entity, component)
		for name, value in pairs(entity.component_map or {}) do
			if value == component then return name end
		end

		return component.Type or "component"
	end

	local function set_target_property(target, info, value)
		if info.set then
			info.set(target, value)
		else
			objects.SetProperty(target, info.var_name, value)
		end
	end

	local function is_property_active(value)
		return value ~= nil and
			value ~= false and
			value ~= 0 and
			value ~= "none" and
			value ~= ""
	end

	local function add_to_category(children, groups, category_key, info, node)
		if not info.category then
			children[#children + 1] = node
			return
		end

		local group = groups[info.category]

		if not group then
			group = {
				Key = category_key .. "/#" .. info.category,
				Text = info.category,
				IsGroup = true,
				Children = {},
			}
			groups[info.category] = group
			children[#children + 1] = group
		end

		group.Children[#group.Children + 1] = node
	end

	-- an info can list extra right click items as {Text, action = function(target)}, the editor can add more
	local function build_context_actions(editor, info, target)
		local out

		if info.context_actions then
			out = {}

			for _, action in ipairs(info.context_actions) do
				out[#out + 1] = {
					Text = action.Text,
					OnClick = function()
						action.action(target)
					end,
				}
			end
		end

		local extra = editor.OnContextActions(target, info)

		if extra then
			out = out or {}

			for _, action in ipairs(extra) do
				out[#out + 1] = action
			end
		end

		return out
	end

	local function build_property_node(editor, target, category_key, category_name, info)
		if info.type == "action" then
			return {
				Type = "action",
				Key = category_key .. "/" .. info.var_name,
				Text = info.var_name,
				ButtonText = info.button_text,
				OnAction = function()
					info.action(target)
				end,
			}
		end

		local resolved_type = property_type_aliases[info.type] or info.type
		local enums = info.enums or info.get_enums and info.get_enums(target)
		local node_type = enums and "enum" or info.asset and "asset" or info.code and "code" or resolved_type
		local get_value

		if info.get then
			get_value = function()
				return info.get(target)
			end
		else
			get_value = function()
				return objects.GetProperty(target, info.var_name)
			end
		end

		local requires = info.requires
		local badge = editor.OnGetPropertyBadge(target, info)
		local node = {
			Type = node_type,
			IsEnabled = info.ReadOnly and
				function()
					return false
				end or
				requires and
				function()
					if type(requires) == "string" then
						return is_property_active(target[requires])
					end

					for i = 1, #requires do
						if not is_property_active(target[requires[i]]) then return false end
					end

					return true
				end,
			Key = category_key .. "/" .. info.var_name,
			Text = info.var_name,
			Value = get_value(),
			Default = info.copy and info.copy() or info.default,
			GetValue = get_value,
			Min = info.min,
			Max = info.max,
			ShowSlider = info.slider,
			Multiline = info.multiline,
			AssetCategory = info.asset,
			CodeLanguage = info.code,
			ContextActions = build_context_actions(editor, info, target),
			Badge = badge,
			LabelColor = badge and badge.Color,
			Description = badge and badge.Tooltip,
			GetStatus = info.status and
				function()
					return info.status(target)
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

		if node_type == "material" or node_type == "texture" then
			node.OnActionButton = function(_, key, path, panel, commit_value)
				event.Call("PickObject", node_type, function(obj)
					commit_value(node, obj, key, path, panel)
				end)
			end
		end

		if node_type == "enum" and enums then
			node.Options = {}

			for _, option in ipairs(enums) do
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

			editor._property_change_sync_blocked = editor._property_change_sync_blocked + 1
			local ok, err = pcall(set_target_property, target, info, next_value)
			editor._property_change_sync_blocked = math.max(0, editor._property_change_sync_blocked - 1)

			if not ok then
				print("editor failed to set property", target, category_name, info.var_name, err)
			end

			return ok
		end
		return node
	end

	function META:SetObject(obj)
		for i = 1, #self._listeners do
			self._listeners[i]()
		end

		list.clear(self._listeners)
		local items = {}

		if is_valid_object(obj) then
			local categories = {}

			if obj.component_list then
				for _, component in ipairs(obj.component_list) do
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

			local order = {}

			for index, name in ipairs(self.CategoryOrder or {}) do
				order[name] = index
			end

			table.sort(categories, function(a, b)
				local rank_a, rank_b = order[a.name] or math.huge, order[b.name] or math.huge

				if rank_a ~= rank_b then return rank_a < rank_b end

				return a.name < b.name
			end)

			for _, category in ipairs(categories) do
				local children = {}
				local groups = {}

				for _, info in ipairs(objects.GetStorableVariables(category.object)) do
					if info.Hidden then goto continue end

					local node = build_property_node(self, category.object, category.key, category.name, info)
					add_to_category(children, groups, category.key, info, node)

					::continue::
				end

				for _, info in ipairs(category.object:GetDynamicProperties()) do
					add_to_category(
						children,
						groups,
						category.key,
						info,
						build_property_node(self, category.object, category.key, category.name, info)
					)
				end

				local badge = self.OnGetCategoryBadge(category.object, category.name)
				items[#items + 1] = {
					Key = category.key,
					Text = category.name,
					Expanded = true,
					Children = children,
					Badge = badge,
					Tab = badge and badge.Tab,
					Description = badge and badge.Tooltip,
				}
				self._listeners[#self._listeners + 1] = category.object:AddPropertyListener(function(_, key)
					if not self:IsValid() then return end

					if key == "DynamicProperties" then
						timer.Delay(0, function()
							if self:IsValid() then self:SetObject(obj) end
						end)

						return
					end

					self:refresh_all_row_text()

					if self._property_change_sync_blocked > 0 then return end

					self:RefreshValueForKey(category.key .. "/" .. key)
				end)
			end
		end

		self:SetItems(items)
	end
end

return META:Register()
