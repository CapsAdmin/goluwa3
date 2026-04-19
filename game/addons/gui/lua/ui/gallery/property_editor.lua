local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("../elements/button.lua")
local Column = import("../elements/column.lua")
local Frame = import("../elements/frame.lua")
local PropertyEditor = import("../elements/property_editor.lua")
local Row = import("../elements/row.lua")
local ScrollablePanel = import("../elements/scrollable_panel.lua")
local Splitter = import("../elements/splitter.lua")
local Text = import("../elements/text.lua")
local TextEdit = import("../elements/text_edit.lua")

local function set_text(panel, value)
	if panel and panel:IsValid() then panel.text:SetText(value or "") end
end

local function has_entries(list)
	return list and next(list) ~= nil
end

local function get_node_children(node)
	return node and node.Children or {}
end

local function get_node_text(node, path)
	return tostring(node and (node.Text or node.Label or node.Name or node.Key) or path or "Property")
end

local function get_node_key(node, path)
	return tostring(node and (node.Key or node.Id) or path)
end

local function format_number(node, value, fallback_precision)
	local numeric = tonumber(value) or 0
	local precision = node and node.Precision or fallback_precision or 2

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

local function describe_value(node)
	if has_entries(get_node_children(node)) then
		local child_count = #get_node_children(node)
		return child_count .. " child" .. (child_count == 1 and "" or "ren")
	end

	local kind = node and (node.Type or node.Editor)

	if kind == "boolean" then return node.Value and "enabled" or "disabled" end

	if kind == "enum" then return get_option_text(node.Options, node.Value) end

	if kind == "number" then return format_number(node, node.Value, 2) end

	if kind == "action" then
		return node.ActionText or node.ButtonText or "Action"
	end

	if not node or node.Value == nil then return "" end

	return tostring(node.Value)
end

local function build_snapshot(state)
	return table.concat(
		{
			"name = " .. tostring(state.name),
			"visible = " .. tostring(state.visible),
			"material = " .. tostring(state.material),
			"opacity = " .. string.format("%.2f", state.opacity),
			"brightness = " .. string.format("%.2f", state.brightness),
			"spin_speed = " .. string.format("%.1f", state.spin_speed),
			"bob_height = " .. string.format("%.1f", state.bob_height),
			"render_mode = " .. tostring(state.render_mode),
			"cast_shadows = " .. tostring(state.cast_shadows),
			"receive_lighting = " .. tostring(state.receive_lighting),
			"notes = [[" .. tostring(state.notes) .. "]]",
		},
		"\n"
	)
end

local function reset_state(state)
	state.name = "Beacon Drone"
	state.visible = true
	state.material = "glass"
	state.opacity = 0.72
	state.brightness = 1.4
	state.spin_speed = 38
	state.bob_height = 6
	state.render_mode = "additive"
	state.cast_shadows = false
	state.receive_lighting = true
	state.notes = "Ambient helper prop used to test grouped property editing."
	state.last_event = "Reset to defaults"
end

local function randomize_accent(state)
	local materials = {"glass", "scanlines", "hologram", "chrome"}
	local modes = {"additive", "alpha", "modulate"}
	state.material = materials[math.random(#materials)]
	state.render_mode = modes[math.random(#modes)]
	state.opacity = math.floor((0.25 + math.random() * 0.65) * 100 + 0.5) / 100
	state.brightness = math.floor((0.7 + math.random() * 2.1) * 100 + 0.5) / 100
	state.last_event = "Randomized appearance preset"
end

local function build_items(state, refresh_preview, refresh_editor)
	return {
		{
			Key = "appearance",
			Text = "Appearance",
			Expanded = true,
			Description = "Surface and presentation controls similar to PAC3-style render groups.",
			Children = {
				{
					Key = "appearance/name",
					Text = "Display Name",
					Type = "string",
					Value = state.name,
					Description = "Inspector label shown for this part.",
					OnChange = function(_, value)
						state.name = value
						state.last_event = "Renamed part"
						refresh_preview()
					end,
				},
				{
					Key = "appearance/visible",
					Text = "Visible",
					Type = "boolean",
					Value = state.visible,
					Description = "Toggles whether the part is rendered at all.",
					OnChange = function(_, value)
						state.visible = value
						state.last_event = value and "Enabled rendering" or "Disabled rendering"
						refresh_preview()
					end,
				},
				{
					Key = "appearance/material",
					Text = "Material",
					Type = "enum",
					Value = state.material,
					Options = {
						{Text = "Glass", Value = "glass"},
						{Text = "Scanlines", Value = "scanlines"},
						{Text = "Hologram", Value = "hologram"},
						{Text = "Chrome", Value = "chrome"},
					},
					Description = "Switches the material preset used by the mock part.",
					OnChange = function(_, value)
						state.material = value
						state.last_event = "Changed material to " .. tostring(value)
						refresh_preview()
					end,
				},
				{
					Key = "appearance/opacity",
					Text = "Opacity",
					Type = "number",
					Value = state.opacity,
					Min = 0,
					Max = 1,
					Precision = 2,
					Description = "Blends the part against the scene.",
					OnChange = function(_, value)
						state.opacity = value
						refresh_preview()
					end,
				},
				{
					Key = "appearance/brightness",
					Text = "Brightness",
					Type = "number",
					Value = state.brightness,
					Min = 0,
					Max = 3,
					Precision = 2,
					Description = "Scales the emissive response of the part.",
					OnChange = function(_, value)
						state.brightness = value
						refresh_preview()
					end,
				},
			},
		},
		{
			Key = "motion",
			Text = "Motion",
			Expanded = true,
			Description = "Transform-like controls for simple looping movement.",
			Children = {
				{
					Key = "motion/spin_speed",
					Text = "Spin Speed",
					Type = "number",
					Value = state.spin_speed,
					Min = 0,
					Max = 120,
					Precision = 1,
					Description = "Degrees per second for the idle spin loop.",
					OnChange = function(_, value)
						state.spin_speed = value
						refresh_preview()
					end,
				},
				{
					Key = "motion/bob_height",
					Text = "Bob Height",
					Type = "number",
					Value = state.bob_height,
					Min = 0,
					Max = 20,
					Precision = 1,
					Description = "Vertical displacement for the idle bob.",
					OnChange = function(_, value)
						state.bob_height = value
						refresh_preview()
					end,
				},
			},
		},
		{
			Key = "render",
			Text = "Render Flags",
			Expanded = true,
			Description = "Small switches that mirror the kind of packed flags PAC3 exposes.",
			Children = {
				{
					Key = "render/render_mode",
					Text = "Blend Mode",
					Type = "enum",
					Value = state.render_mode,
					Options = {
						{Text = "Additive", Value = "additive"},
						{Text = "Alpha", Value = "alpha"},
						{Text = "Modulate", Value = "modulate"},
					},
					Description = "Chooses how the part is blended during the final pass.",
					OnChange = function(_, value)
						state.render_mode = value
						state.last_event = "Switched blend mode"
						refresh_preview()
					end,
				},
				{
					Key = "render/cast_shadows",
					Text = "Cast Shadows",
					Type = "boolean",
					Value = state.cast_shadows,
					Description = "Whether the part contributes to the shadow pass.",
					OnChange = function(_, value)
						state.cast_shadows = value
						refresh_preview()
					end,
				},
				{
					Key = "render/receive_lighting",
					Text = "Receive Lighting",
					Type = "boolean",
					Value = state.receive_lighting,
					Description = "Disables scene lighting when unchecked.",
					OnChange = function(_, value)
						state.receive_lighting = value
						refresh_preview()
					end,
				},
			},
		},
		{
			Key = "metadata",
			Text = "Metadata",
			Expanded = true,
			Description = "Long-form fields that still live inside the collapsible property layout.",
			Children = {
				{
					Key = "metadata/notes",
					Text = "Notes",
					Type = "string",
					Multiline = true,
					ApplyText = "Commit",
					Value = state.notes,
					Description = "A larger text field embedded inline in the property list.",
					OnChange = function(_, value)
						state.notes = value
						state.last_event = "Updated notes"
						refresh_preview()
					end,
				},
			},
		},
		{
			Key = "actions",
			Text = "Actions",
			Expanded = true,
			Description = "Imperative rows for tasks that rebuild other values.",
			Children = {
				{
					Key = "actions/randomize_accent",
					Text = "Randomize Accent",
					Type = "action",
					ButtonText = "Run",
					Description = "Applies a quick randomized appearance preset.",
					OnAction = function()
						randomize_accent(state)
						refresh_preview()
						refresh_editor()
					end,
				},
				{
					Key = "actions/reset",
					Text = "Reset Defaults",
					Type = "action",
					ButtonText = "Reset",
					Description = "Restores the demo part to its initial state.",
					OnAction = function()
						reset_state(state)
						refresh_preview()
						refresh_editor()
					end,
				},
			},
		},
	}
end

return {
	Name = "property editor",
	Create = function()
		local state = {}
		local editor
		local summary_title
		local summary_body
		local summary_event
		local snapshot_view
		local property_scroll
		local selected_title
		local selected_meta
		local selected_value
		local selected_description

		local function refresh_selected_details(node, key, path)
			if not node then
				set_text(selected_title, "No selection")
				set_text(selected_meta, "")
				set_text(selected_value, "")
				set_text(selected_description, "")
				return
			end

			local kind = has_entries(get_node_children(node)) and
				"group" or
				(
					node.Type or
					node.Editor or
					"value"
				)
			local value_line = describe_value(node)
			set_text(selected_title, get_node_text(node, path))
			set_text(
				selected_meta,
				string.upper(kind) .. "  |  " .. tostring(key or get_node_key(node, path))
			)
			set_text(selected_value, value_line ~= "" and ("Current: " .. value_line) or "")
			set_text(selected_description, node.Description or "No description provided.")
		end

		local function refresh_preview()
			set_text(summary_title, state.name)
			set_text(
				summary_body,
				table.concat(
					{
						"Visible: " .. tostring(state.visible),
						"Material: " .. tostring(state.material),
						"Blend: " .. tostring(state.render_mode),
						"Opacity: " .. string.format("%.2f", state.opacity),
						"Brightness: " .. string.format("%.2f", state.brightness),
						"Spin: " .. string.format("%.1f deg/s", state.spin_speed),
						"Bob Height: " .. string.format("%.1f", state.bob_height),
						"Cast Shadows: " .. tostring(state.cast_shadows),
						"Receive Lighting: " .. tostring(state.receive_lighting),
						"Notes: " .. tostring(state.notes),
					},
					"\n"
				)
			)

			if snapshot_view and snapshot_view:IsValid() then
				snapshot_view:SetText(build_snapshot(state))
			end

			set_text(summary_event, state.last_event or "")
		end

		local function refresh_editor()
			if editor and editor:IsValid() then
				editor:SetItems(build_items(state, refresh_preview, refresh_editor))
			end
		end

		reset_state(state)
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
				Text = "Property Editor",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "A grouped property editor inspired by PAC3. Categories expand as collapsible sections, keys stay in a left column, values live in a right column, and each category uses a draggable divider to resize that split.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
					AlignmentY = "center",
				},
			}{
				Button{
					Text = "Expand All",
					OnClick = function()
						if editor and editor:IsValid() then editor:ExpandAll() end
					end,
				},
				Button{
					Text = "Collapse All",
					Mode = "outline",
					OnClick = function()
						if editor and editor:IsValid() then editor:CollapseAll() end
					end,
				},
				Button{
					Text = "Focus Notes",
					Mode = "outline",
					OnClick = function()
						if not editor or not editor:IsValid() then return end

						editor:ExpandToKey("metadata/notes", true)
						editor:SetSelectedKey("metadata/notes")

						if property_scroll and property_scroll:IsValid() then
							property_scroll:ScrollChildIntoView(editor:GetPanelForKey("metadata/notes"), 12)
						end
					end,
				},
				Button{
					Text = "Reset Demo",
					Mode = "outline",
					OnClick = function()
						reset_state(state)
						refresh_preview()
						refresh_editor()
					end,
				},
			},
			Splitter{
				InitialSize = 430,
				layout = {
					GrowWidth = 1,
					MinSize = Vec2(0, 560),
					MaxSize = Vec2(0, 560),
				},
			}{
				Column{
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						FitHeight = false,
						AlignmentX = "stretch",
						ChildGap = 10,
					},
				}{
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
								self:SetItems(build_items(state, refresh_preview, refresh_editor))
								self:SetSelectedKey("appearance/name")
							end,
							OnSelect = refresh_selected_details,
							layout = {
								GrowHeight = 1,
								MinSize = Vec2(760, 0),
								MaxSize = Vec2(760, 0),
								FitWidth = false,
							},
						},
					},
					Frame{
						Padding = "S",
						layout = {
							GrowWidth = 1,
							FitHeight = true,
						},
					}{
						Column{
							layout = {
								GrowWidth = 1,
								AlignmentX = "stretch",
								ChildGap = 6,
							},
						}{
							Text{
								Ref = function(self)
									selected_title = self
									refresh_selected_details(nil)
								end,
								Text = "No selection",
								Font = "body_strong S",
								IgnoreMouseInput = true,
							},
							Text{
								Ref = function(self)
									selected_meta = self
								end,
								Text = "",
								Color = "text_disabled",
								IgnoreMouseInput = true,
								layout = {
									GrowWidth = 1,
								},
							},
							Text{
								Ref = function(self)
									selected_value = self
								end,
								Text = "",
								IgnoreMouseInput = true,
								layout = {
									GrowWidth = 1,
								},
							},
							Text{
								Ref = function(self)
									selected_description = self
								end,
								Text = "",
								Wrap = true,
								IgnoreMouseInput = true,
								layout = {
									GrowWidth = 1,
								},
							},
						},
					},
				},
				Column{
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						AlignmentX = "stretch",
						ChildGap = 10,
					},
				}{
					Frame{
						Padding = "S",
						layout = {
							GrowWidth = 1,
						},
					}{
						Column{
							layout = {
								GrowWidth = 1,
								AlignmentX = "stretch",
								ChildGap = 8,
							},
						}{
							Text{
								Text = "Live Target",
								Font = "body_strong S",
								IgnoreMouseInput = true,
							},
							Text{
								Ref = function(self)
									summary_title = self
									refresh_preview()
								end,
								Text = state.name,
								IgnoreMouseInput = true,
							},
							Text{
								Ref = function(self)
									summary_body = self
									refresh_preview()
								end,
								Text = "",
								Wrap = true,
								IgnoreMouseInput = true,
								layout = {
									GrowWidth = 1,
								},
							},
							Text{
								Ref = function(self)
									summary_event = self
									refresh_preview()
								end,
								Text = "",
								Color = "text_disabled",
								Wrap = true,
								IgnoreMouseInput = true,
								layout = {
									GrowWidth = 1,
								},
							},
						},
					},
					Frame{
						Padding = "S",
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
						},
					}{
						Column{
							layout = {
								GrowWidth = 1,
								GrowHeight = 1,
								AlignmentX = "stretch",
								ChildGap = 8,
							},
						}{
							Text{
								Text = "Snapshot",
								Font = "body_strong S",
								IgnoreMouseInput = true,
							},
							TextEdit{
								Ref = function(self)
									snapshot_view = self
									self:SetText(build_snapshot(state))
								end,
								Editable = false,
								Text = build_snapshot(state),
								Size = Vec2(0, 320),
								MinSize = Vec2(0, 320),
								MaxSize = Vec2(0, 320),
								Wrap = true,
								layout = {
									GrowWidth = 1,
								},
							},
						},
					},
				},
			},
		}
	end,
}
