local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("../theme.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local PropertyEditor = import("../widgets/property_editor.lua")
local ScrollablePanel = import("../elements/scrollable_panel.lua")
local Splitter = import("../elements/splitter.lua")
local Column = import("../elements/column.lua")
local Row = import("../elements/row.lua")
local Text = import("../elements/text.lua")
local Frame = import("../elements/frame.lua")
local Dropdown = import("../widgets/dropdown.lua")
local DRAW_ELEMENTS = {
	{
		key = "button",
		label = "Button",
		state_fields = {
			{key = "hovered", type = "boolean", default = false},
			{key = "pressed", type = "boolean", default = false},
			{key = "disabled", type = "boolean", default = false},
			{key = "active", type = "boolean", default = false},
			{
				key = "mode",
				type = "enum",
				default = "filled",
				options = {
					{Text = "Filled", Value = "filled"},
					{Text = "Outline", Value = "outline"},
				},
			},
		},
		draw = function(size, state)
			theme.active:DrawButton(size, state)
		end,
		draw_post = function(size, state)
			theme.active:DrawButtonPost(size, state)
		end,
		update_animations = function(pnl, state)
			theme.UpdateButtonAnimations(pnl, state)
		end,
		preview_size = Vec2(180, 40),
	},
	{
		key = "checkbox",
		label = "Checkbox",
		state_fields = {
			{key = "hovered", type = "boolean", default = false},
			{key = "value", type = "boolean", default = false},
		},
		draw = function(size, state)
			theme.active:DrawCheckbox(size, state)
		end,
		update_animations = function(pnl, state)
			theme.UpdateCheckboxAnimations(pnl, state)
		end,
		preview_size = Vec2(40, 40),
	},
	{
		key = "radio",
		label = "Radio Button",
		state_fields = {
			{key = "hovered", type = "boolean", default = false},
			{key = "value", type = "boolean", default = false},
		},
		draw = function(size, state)
			theme.active:DrawButtonRadio(size, state)
		end,
		update_animations = function(pnl, state)
			theme.UpdateCheckboxAnimations(pnl, state)
		end,
		preview_size = Vec2(40, 40),
	},
	{
		key = "slider_horizontal",
		label = "Slider (Horizontal)",
		state_fields = {
			{key = "hovered", type = "boolean", default = false},
			{key = "value", type = "number", default = 0.5, min = 0, max = 1, precision = 2},
			{key = "min", type = "number", default = 0, min = 0, max = 1, precision = 2},
			{key = "max", type = "number", default = 1, min = 0, max = 2, precision = 2},
		},
		draw = function(size, state)
			state.mode = "horizontal"
			theme.active:DrawSlider(size, state)
		end,
		update_animations = function(pnl, state)
			theme.UpdateSliderAnimations(pnl, state)
		end,
		preview_size = Vec2(200, 30),
	},
	{
		key = "slider_vertical",
		label = "Slider (Vertical)",
		state_fields = {
			{key = "hovered", type = "boolean", default = false},
			{key = "value", type = "number", default = 0.5, min = 0, max = 1, precision = 2},
			{key = "min", type = "number", default = 0, min = 0, max = 1, precision = 2},
			{key = "max", type = "number", default = 1, min = 0, max = 2, precision = 2},
		},
		draw = function(size, state)
			state.mode = "vertical"
			theme.active:DrawSlider(size, state)
		end,
		update_animations = function(pnl, state)
			theme.UpdateSliderAnimations(pnl, state)
		end,
		preview_size = Vec2(30, 160),
	},
	{
		key = "slider_2d",
		label = "Slider (2D)",
		state_fields = {
			{key = "hovered", type = "boolean", default = false},
			{
				key = "value",
				type = "vec2",
				default = Vec2(0.5, 0.5),
				min = Vec2(0, 0),
				max = Vec2(1, 1),
				precision = 2,
			},
			{
				key = "min",
				type = "vec2",
				default = Vec2(0, 0),
				min = Vec2(0, 0),
				max = Vec2(1, 1),
				precision = 2,
			},
			{
				key = "max",
				type = "vec2",
				default = Vec2(1, 1),
				min = Vec2(0, 0),
				max = Vec2(2, 2),
				precision = 2,
			},
		},
		draw = function(size, state)
			state.mode = "2d"
			theme.active:DrawSlider(size, state)
		end,
		update_animations = function(pnl, state)
			theme.UpdateSliderAnimations(pnl, state)
		end,
		preview_size = Vec2(160, 160),
	},
	{
		key = "progress_bar",
		label = "Progress Bar",
		state_fields = {
			{key = "value", type = "number", default = 0.6, min = 0, max = 1, precision = 2},
		},
		draw = function(size, state)
			theme.active:DrawProgressBar(size, state)
		end,
		preview_size = Vec2(200, 20),
	},
	{
		key = "frame",
		label = "Frame",
		state_fields = {
			{
				key = "emphasis",
				type = "number",
				default = 1,
				min = 0,
				max = 10,
				precision = 0,
			},
		},
		draw = function(size, state)
			local draw = {size = size, alpha = 1, radius = theme.active:GetSize("XS")}
			theme.active:DrawFrame(draw, state.emphasis)
		end,
		draw_post = function(size, state)
			local draw = {size = size, alpha = 1, radius = theme.active:GetSize("XS")}
			theme.active:DrawFramePost(draw)
		end,
		preview_size = Vec2(200, 80),
	},
	{
		key = "menu_button",
		label = "Menu Button",
		state_fields = {
			{key = "hovered", type = "boolean", default = false},
			{key = "pressed", type = "boolean", default = false},
			{key = "disabled", type = "boolean", default = false},
			{key = "active", type = "boolean", default = false},
		},
		draw = function(size, state)
			theme.active:DrawMenuButton(size, state)
		end,
		preview_size = Vec2(180, 32),
	},
	{
		key = "panel_fill_outline",
		label = "Panel Fill + Outline",
		state_fields = {
			{
				key = "fill_color",
				type = "enum",
				default = "surface",
				options = {
					{Text = "Surface", Value = "surface"},
					{Text = "Surface Alt", Value = "surface_alt"},
					{Text = "Primary", Value = "primary"},
					{Text = "Secondary", Value = "secondary"},
				},
			},
			{
				key = "outline_color",
				type = "enum",
				default = "border",
				options = {
					{Text = "Border", Value = "border"},
					{Text = "Primary", Value = "primary"},
					{Text = "Secondary", Value = "secondary"},
				},
			},
			{key = "radius", type = "number", default = 8, min = 0, max = 32, precision = 0},
			{
				key = "fill_alpha",
				type = "number",
				default = 1,
				min = 0,
				max = 1,
				precision = 2,
			},
			{
				key = "outline_alpha",
				type = "number",
				default = 1,
				min = 0,
				max = 1,
				precision = 2,
			},
			{
				key = "thickness",
				type = "number",
				default = 1,
				min = 1,
				max = 4,
				precision = 0,
			},
		},
		draw = function(size, state)
			theme.active:DrawPanelFillOutline(
				size,
				state.fill_color,
				state.outline_color,
				{
					radius = state.radius,
					fill_alpha = state.fill_alpha,
					outline_alpha = state.outline_alpha,
					thickness = state.thickness,
				}
			)
		end,
		preview_size = Vec2(200, 80),
	},
	{
		key = "selection_fill",
		label = "Selection Fill",
		state_fields = {
			{
				key = "color",
				type = "enum",
				default = "property_selection",
				options = {
					{Text = "Property Selection", Value = "property_selection"},
					{Text = "Primary", Value = "primary"},
					{Text = "Surface Alt", Value = "surface_alt"},
				},
			},
			{key = "alpha", type = "number", default = 1, min = 0, max = 1, precision = 2},
		},
		draw = function(size, state)
			theme.active:DrawSelectionFill(size, state.color, state.alpha)
		end,
		preview_size = Vec2(200, 50),
	},
	{
		key = "tree_guides",
		label = "Tree Guides",
		state_fields = {
			{key = "level", type = "number", default = 2, min = 0, max = 5, precision = 0},
			{key = "is_last", type = "boolean", default = false},
			{key = "continuation_1", type = "boolean", default = true},
			{key = "continuation_2", type = "boolean", default = true},
			{key = "continuation_3", type = "boolean", default = false},
			{
				key = "guide_step",
				type = "number",
				default = 14,
				min = 8,
				max = 24,
				precision = 0,
			},
			{
				key = "toggle_size",
				type = "number",
				default = 12,
				min = 8,
				max = 20,
				precision = 0,
			},
		},
		draw = function(size, state)
			theme.active:DrawTreeGuideLines(
				size,
				{
					level = state.level,
					is_last = state.is_last,
					continuations = {state.continuation_1, state.continuation_2, state.continuation_3},
				},
				{
					guide_step = state.guide_step,
					toggle_size = state.toggle_size,
				}
			)
		end,
		preview_size = Vec2(220, 28),
	},
	{
		key = "tree_toggle",
		label = "Tree Toggle",
		state_fields = {
			{key = "level", type = "number", default = 2, min = 0, max = 5, precision = 0},
			{key = "is_last", type = "boolean", default = false},
			{key = "expanded", type = "boolean", default = false},
			{key = "continuation_1", type = "boolean", default = true},
			{key = "continuation_2", type = "boolean", default = true},
			{key = "continuation_3", type = "boolean", default = false},
			{
				key = "guide_step",
				type = "number",
				default = 14,
				min = 8,
				max = 24,
				precision = 0,
			},
			{
				key = "toggle_size",
				type = "number",
				default = 12,
				min = 8,
				max = 20,
				precision = 0,
			},
			{
				key = "box_size",
				type = "number",
				default = 10,
				min = 6,
				max = 18,
				precision = 0,
			},
		},
		draw = function(size, state)
			local half_box = math.floor(state.box_size / 2)
			local center_x = state.level * state.guide_step + math.floor(state.toggle_size / 2)
			local line_start_x = center_x + half_box
			theme.active:DrawTreeToggle(
				size,
				{
					level = state.level,
					is_last = state.is_last,
					continuations = {state.continuation_1, state.continuation_2, state.continuation_3},
				},
				{
					guide_step = state.guide_step,
					toggle_size = state.toggle_size,
					box_size = state.box_size,
					line_start_x = line_start_x,
					expanded = state.expanded,
				}
			)
		end,
		preview_size = Vec2(220, 28),
	},
	{
		key = "drop_indicator",
		label = "Drop Indicator",
		state_fields = {
			{key = "source", type = "boolean", default = true},
			{
				key = "position",
				type = "enum",
				default = "inside",
				options = {
					{Text = "Inside", Value = "inside"},
					{Text = "Before", Value = "before"},
					{Text = "After", Value = "after"},
				},
			},
			{
				key = "thickness",
				type = "number",
				default = 2,
				min = 1,
				max = 4,
				precision = 0,
			},
			{key = "alpha", type = "number", default = 1, min = 0, max = 1, precision = 2},
		},
		draw = function(size, state)
			theme.active:DrawDropIndicator(size, state)
		end,
		preview_size = Vec2(200, 48),
	},
	{
		key = "header",
		label = "Header",
		state_fields = {},
		draw = function(size, state)
			local draw = {size = size, alpha = 1, radius = 0}
			theme.active:DrawHeader(draw)
		end,
		preview_size = Vec2(200, 32),
	},
	{
		key = "divider_horizontal",
		label = "Divider (Horizontal)",
		state_fields = {},
		draw = function(size, state)
			local draw = {size = size, alpha = 1}
			theme.active:DrawDivider(draw)
		end,
		preview_size = Vec2(200, 12),
	},
	{
		key = "divider_vertical",
		label = "Divider (Vertical)",
		state_fields = {},
		draw = function(size, state)
			local draw = {size = size, alpha = 1}
			theme.active:DrawDivider(draw)
		end,
		preview_size = Vec2(12, 80),
	},
	{
		key = "surface",
		label = "Surface",
		state_fields = {
			{
				key = "color",
				type = "enum",
				default = "surface",
				options = {
					{Text = "Surface", Value = "surface"},
					{Text = "Surface Alt", Value = "surface_alt"},
					{Text = "Main Background", Value = "main_background"},
					{Text = "Primary", Value = "primary"},
					{Text = "Secondary", Value = "secondary"},
				},
			},
		},
		draw = function(size, state)
			local draw = {size = size, alpha = 1, radius = theme.active:GetSize("XS")}
			theme.active:DrawSurface(draw, state.color)
		end,
		preview_size = Vec2(200, 80),
	},
	{
		key = "disclosure_icon",
		label = "Disclosure Icon",
		state_fields = {
			{
				key = "open_fraction",
				type = "number",
				default = 0,
				min = 0,
				max = 1,
				precision = 2,
			},
		},
		draw = function(size, state)
			theme.active:DrawIcon(
				"disclosure",
				size,
				{open_fraction = state.open_fraction, size = 10, thickness = 2}
			)
		end,
		preview_size = Vec2(40, 40),
	},
	{
		key = "dropdown_indicator",
		label = "Dropdown Indicator",
		state_fields = {},
		draw = function(size, state)
			theme.active:DrawIcon("dropdown_indicator", size, {size = 8, thickness = 2})
		end,
		preview_size = Vec2(40, 40),
	},
	{
		key = "close_icon",
		label = "Close Icon",
		state_fields = {},
		draw = function(size, state)
			theme.active:DrawIcon("close", size, {size = 8, thickness = 2})
		end,
		preview_size = Vec2(40, 40),
	},
	{
		key = "menu_spacer_horizontal",
		label = "Menu Spacer (Horizontal)",
		state_fields = {},
		draw = function(size, state)
			theme.active:DrawMenuSpacer(size, false)
		end,
		preview_size = Vec2(200, 12),
	},
	{
		key = "menu_spacer_vertical",
		label = "Menu Spacer (Vertical)",
		state_fields = {},
		draw = function(size, state)
			theme.active:DrawMenuSpacer(size, true)
		end,
		preview_size = Vec2(12, 80),
	},
}

local function make_default_anim(fields)
	local anim = {
		glow_alpha = 0,
		knob_scale = 1,
		check_anim = 0,
		press_scale = 0,
		last_hovered = false,
		last_pressed = false,
		last_value = false,
	}

	for _, field in ipairs(fields) do
		if field.key == "value" and field.type == "boolean" then
			anim.check_anim = field.default and 1 or 0
			anim.last_value = field.default
		end
	end

	return anim
end

local function make_default_state(element)
	local state = {anim = make_default_anim(element.state_fields)}

	for _, field in ipairs(element.state_fields) do
		state[field.key] = field.default
	end

	return state
end

local function build_property_items(element, state, refresh_preview)
	local children = {}

	if #element.state_fields == 0 then
		table.insert(
			children,
			{
				Key = "info/no_state",
				Text = "No editable state",
				Type = "string",
				Value = "This element has no state properties.",
				Description = "The drawing is static and cannot be customized through properties.",
			}
		)
	else
		for _, field in ipairs(element.state_fields) do
			local item = {
				Key = "state/" .. field.key,
				Text = field.key:gsub("_", " "):gsub("^%l", string.upper),
				Type = field.type,
				Value = state[field.key],
				Description = "Controls the \"" .. field.key .. "\" state of the " .. element.label .. " drawing.",
				OnChange = function(_, value)
					state[field.key] = value
					refresh_preview()
				end,
			}

			if field.type == "enum" then
				item.Options = field.options
			elseif field.type == "number" then
				item.Min = field.min
				item.Max = field.max
				item.Precision = field.precision or 2
			elseif field.type == "vec2" then
				item.Min = field.min
				item.Max = field.max
				item.Precision = field.precision or 2
			end

			table.insert(children, item)
		end
	end

	return {
		{
			Key = "state",
			Text = "State",
			Expanded = true,
			Children = children,
		},
	}
end

return {
	Name = "theme draw",
	Create = function()
		local selected_element = DRAW_ELEMENTS[1]
		local draw_state = make_default_state(selected_element)
		local editor
		local preview_panel
		local property_scroll

		local function refresh_preview() end

		local function refresh_editor()
			if editor and editor:IsValid() then
				editor:SetItems(build_property_items(selected_element, draw_state, refresh_preview))
			end
		end

		local function select_element(element)
			selected_element = element
			draw_state = make_default_state(element)
			refresh_editor()
			refresh_preview()
		end

		local dropdown_options = {}

		for _, element in ipairs(DRAW_ELEMENTS) do
			table.insert(dropdown_options, {Text = element.label, Value = element.key})
		end

		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 10,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Theme Draw Primitives",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "Select a theme drawing method on the left, then edit its state properties to see how the drawing responds in real time on the right.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Splitter{
				InitialSize = 220,
				layout = {
					GrowWidth = 1,
					MinSize = Vec2(0, 480),
					MaxSize = Vec2(0, 480),
				},
			}{
				Column{
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						FitHeight = false,
						AlignmentX = "stretch",
						ChildGap = 8,
					},
				}{
					Text{
						Text = "Element",
						Font = "body_strong S",
						IgnoreMouseInput = true,
					},
					Dropdown{
						Text = selected_element.label,
						Options = dropdown_options,
						GetText = function()
							return selected_element.label
						end,
						OnSelect = function(value)
							for _, element in ipairs(DRAW_ELEMENTS) do
								if element.key == value then
									select_element(element)

									break
								end
							end
						end,
						layout = {
							GrowWidth = 1,
						},
						Padding = "XS",
					},
					Text{
						Text = "Properties",
						Font = "body_strong S",
						IgnoreMouseInput = true,
					},
					ScrollablePanel{
						Ref = function(self)
							property_scroll = self
						end,
						ScrollX = false,
						ScrollY = true,
						ScrollBarContentShiftMode = "auto_shift",
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
						},
					}{
						PropertyEditor{
							Ref = function(self)
								editor = self
								self:SetItems(build_property_items(selected_element, draw_state, refresh_preview))
							end,
							layout = {
								GrowHeight = 1,
								GrowWidth = 1,
							},
						},
					},
				},
				Column{
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						AlignmentX = "center",
						AlignmentY = "center",
						ChildGap = 16,
					},
				}{
					Frame{
						Padding = "M",
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
							AlignmentX = "center",
							AlignmentY = "center",
						},
					}{
						Panel.New{
							Name = "theme_draw_preview",
							transform = {
								Size = selected_element.preview_size,
							},
							layout = {
								AlignmentX = "center",
								AlignmentY = "center",
							},
							gui_element = {
								Clipping = true,
								OnDraw = function(self)
									draw_state.pnl = self.Owner

									if selected_element.update_animations then
										selected_element.update_animations(self.Owner, draw_state)
									end

									local size = self.Owner.transform:GetSize()
									selected_element.draw(size, draw_state)
								end,
								OnPostDraw = function(self)
									if selected_element.draw_post then
										local size = self.Owner.transform:GetSize()
										selected_element.draw_post(size, draw_state)
									end
								end,
							},
							animation = true,
							Ref = function(self)
								preview_panel = self
							end,
						},
					},
					Text{
						Text = "Hover and press states are controlled via the property editor on the left.",
						Color = "text_disabled",
						Wrap = true,
						IgnoreMouseInput = true,
						layout = {
							GrowWidth = 1,
							AlignmentX = "center",
						},
					},
				},
			},
		}
	end,
}
