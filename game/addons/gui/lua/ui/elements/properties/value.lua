local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")
local ContextMenu = import("lua/ui/elements/context_menu.lua")
local MenuItem = import("lua/ui/elements/context_menu_item.lua")
local Text = import("lua/ui/elements/text.lua")
local prototype = import("goluwa/prototype.lua")
local system = import("goluwa/system.lua")
local theme = import("lua/ui/theme.lua")
local Value = {}
local icon_sources = {
	copy = "https://api.iconify.design/material-symbols-light/content-copy.svg",
	paste = "https://api.iconify.design/material-symbols-light/content-paste-rounded.svg",
	reset = "https://api.iconify.design/material-symbols-light/reset-iso-rounded.svg",
}

local function set_text(panel, value)
	if panel and panel:IsValid() and panel.text then
		panel.text:SetText(value or "")
	end
end

local function default_format_value(value)
	if value == nil then return "" end

	return tostring(value)
end

function Value.InstallContextMenu(panel, props)
	if not (panel and props) then return panel end

	function panel:OpenContextMenu()
		if props.BeforeOpen then props.BeforeOpen(self) end

		local current_encoded = props.Encode and props.Encode(self) or nil
		local default_encoded = props.GetDefaultEncoded and props.GetDefaultEncoded(self, current_encoded) or nil
		local clipboard_text = clipboard.Get() or ""
		local can_paste = false

		if props.Decode then
			local _, ok = props.Decode(clipboard_text, self)
			can_paste = ok == true
		end

		local can_reset = default_encoded ~= nil and default_encoded ~= current_encoded
		local active = Panel.World:GetKeyed("ActiveContextMenu")

		if active and active:IsValid() then active:Remove() end

		local function apply_encoded_value(encoded)
			if not (props.Decode and props.Commit) then return end

			local decoded, ok = props.Decode(encoded, self)

			if not ok then return end

			props.Commit(decoded, self)
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
		return true
	end

	if panel.mouse_input and panel.mouse_input.OnMouseInput then
		local on_mouse_input = panel.mouse_input.OnMouseInput
		panel.mouse_input.OnMouseInput = function(self, button, press, ...)
			if button == "button_2" and press then return panel:OpenContextMenu() end

			return on_mouse_input(self, button, press, ...)
		end
	end

	return panel
end

local function create_value(props)
	props = props or {}
	local external_ref = props.Ref

	if external_ref then
		props = table.shallow_copy(props)
		props.Ref = nil
	end

	local value = props.Value

	if value == nil then value = "" end

	local format_value = props.FormatValue or default_format_value
	local format_edit_value = props.FormatEditValue or format_value
	local parse_value = props.ParseValue or function(text)
		return text
	end
	local edit_click_count = props.EditClickCount or 1
	local drag_threshold = props.DragThreshold or 4
	local size = props.Size or Vec2(220, 34)
	local min_size = props.MinSize or Vec2(80, size.y)
	local max_size = props.MaxSize or Vec2(0, size.y)
	local text_panel
	local panel
	local idle_color = Color(0, 0, 0, 0.001)
	local surface_color = idle_color
	local state = {
		hovered = false,
		editing = false,
		click_count = 0,
		last_click_time = 0,
		pending_drag = false,
		dragging = false,
		drag_start_pos = Vec2(),
		drag_start_value = value,
		drag_accumulated_delta = Vec2(),
		last_drag_pos = Vec2(),
		mouse_trapped = false,
	}

	local function set_drag_mouse_trapped(trapped)
		if state.mouse_trapped == trapped then return end

		local window = system.GetWindow()

		if not (window and window.SetMouseTrapped) then return end

		window:SetMouseTrapped(trapped)
		state.mouse_trapped = trapped
	end

	local function update_display_text()
		if state.editing then return end

		set_text(text_panel, format_value(value))
	end

	local function update_visual_state()
		if not panel or not panel:IsValid() or not text_panel or not text_panel:IsValid() then
			return
		end

		if panel.mouse_input then
			panel.mouse_input:SetCursor(state.editing and "text_input" or (props.Cursor or "hand"))
		end

		if text_panel.mouse_input then
			text_panel.mouse_input:SetIgnoreMouseInput(not state.editing)
			text_panel.mouse_input:SetCursor(state.editing and "text_input" or nil)
		end

		if state.editing then
			surface_color = theme.GetColor(props.EditPanelColor or "surface_alt")
		elseif state.hovered then
			surface_color = theme.GetColor(props.HoverPanelColor or "surface_alt"):Copy()
			surface_color.a = surface_color.a * 0.45
		else
			surface_color = idle_color
		end
	end

	local function set_editor_defaults()
		if
			not text_panel or
			not text_panel:IsValid()
			or
			not text_panel.text or
			not text_panel.text.editor
		then
			return
		end

		text_panel.text.editor:SetMultiline(false)
		text_panel.text.editor:SetPreserveTabsOnEnter(false)
	end

	local function stop_editing(commit)
		if not state.editing then return false end

		state.editing = false
		local next_value = value

		if commit and text_panel and text_panel:IsValid() and text_panel.text then
			local parsed = parse_value(text_panel.text:GetText(), value)

			if parsed ~= nil then next_value = parsed end
		end

		if text_panel and text_panel:IsValid() and text_panel.text then
			text_panel.text:SetEditable(false)
		end

		panel:SetValue(next_value, commit == true)
		prototype.SetFocusedObject(NULL)
		update_visual_state()
		return true
	end

	local function begin_editing()
		if
			state.editing or
			not text_panel or
			not text_panel:IsValid()
			or
			not text_panel.text
		then
			return false
		end

		state.editing = true
		set_text(text_panel, format_edit_value(value))
		text_panel.text:SetEditable(true)
		set_editor_defaults()
		text_panel:RequestFocus()
		set_editor_defaults()

		if text_panel.text.editor then text_panel.text.editor:SelectAll() end

		update_visual_state()
		return true
	end

	panel = Panel.New{
		Name = props.Name or "value",
		Tooltip = props.Tooltip,
		TooltipOptions = props.TooltipOptions,
		OnSetProperty = theme.OnSetProperty,
		transform = {
			Size = size,
		},
		layout = {
			Direction = "x",
			AlignmentY = "center",
			GrowWidth = 1,
			MinSize = min_size,
			MaxSize = max_size,
			Padding = props.Padding or "XS",
			props.layout,
		},
		gui_element = {
			Clipping = true,
			BorderRadius = props.BorderRadius or 6,
			OnDraw = function(self)
				if surface_color.a > 0 then
					theme.active:DrawSurface(theme.GetDrawContext(self, true), surface_color)
				end
			end,
			OnPostDraw = function(self)
				if state.editing then
					theme.active:DrawFramePost(theme.GetDrawContext(self, true))
				end
			end,
		},
		mouse_input = {
			Cursor = props.Cursor or "hand",
			OnHover = function(self, hovered)
				state.hovered = hovered
				update_visual_state()
			end,
			OnMouseInput = function(self, button, press, local_pos)
				if button ~= "button_1" or not press then return end

				if state.editing then return true end

				local now = system.GetElapsedTime()

				if now - state.last_click_time < 0.35 then
					state.click_count = state.click_count + 1
				else
					state.click_count = 1
				end

				state.last_click_time = now
				state.pending_drag = props.OnDragValue ~= nil
				state.dragging = false
				state.drag_start_pos = system.GetWindow():GetMousePosition():Copy()
				state.drag_start_value = value
				state.drag_accumulated_delta = Vec2()
				state.last_drag_pos = state.drag_start_pos:Copy()

				if state.click_count >= edit_click_count then
					state.pending_drag = false
					state.click_count = 0
					return begin_editing()
				end

				return true
			end,
			OnGlobalMouseMove = function(self, pos)
				if not state.pending_drag or state.editing or not props.OnDragValue then
					return
				end

				local delta = pos - state.drag_start_pos
				local started_drag = false

				if not state.dragging then
					if math.abs(delta.x) < drag_threshold and math.abs(delta.y) < drag_threshold then
						return
					end

					state.dragging = true
					started_drag = true
					state.drag_accumulated_delta = Vec2()
					set_drag_mouse_trapped(true)
				end

				local window = system.GetWindow()
				local frame_delta = started_drag and
					(
						pos - state.last_drag_pos
					)
					or
					(
						window and
						window.GetMouseDelta and
						window:GetMouseDelta() or
						(
							pos - state.last_drag_pos
						)
					)
				state.last_drag_pos = pos:Copy()
				state.drag_accumulated_delta = state.drag_accumulated_delta + frame_delta
				local next_value = props.OnDragValue(state.drag_accumulated_delta, state.drag_start_value, panel)

				if next_value ~= nil then panel:SetValue(next_value, true) end

				if
					state.mouse_trapped and
					window and
					window.SetMousePosition and
					(
						not window.ShouldWarpMouseWhenCaptured or
						window:ShouldWarpMouseWhenCaptured()
					)
				then
					pcall(window.SetMousePosition, window, state.drag_start_pos)
					state.last_drag_pos = state.drag_start_pos:Copy()
				end

				return true
			end,
			OnGlobalMouseInput = function(self, button, press, pos)
				if button == "button_1" and not press then
					if state.dragging then
						state.dragging = false
						state.pending_drag = false
						state.click_count = 0
						set_drag_mouse_trapped(false)
						return true
					end

					state.pending_drag = false
					set_drag_mouse_trapped(false)
					return
				end

				if button == "button_1" and press and state.editing then
					if not self.Owner.gui_element or not self.Owner.gui_element:IsHovered(pos) then
						return stop_editing(true)
					end
				end
			end,
		},
		clickable = true,
		animation = true,
	}{
		Text{
			Ref = function(self)
				text_panel = self

				if self.mouse_input then self.mouse_input:SetIgnoreMouseInput(true) end

				update_display_text()
				update_visual_state()
			end,
			Text = format_value(value),
			Font = props.Font,
			FontName = props.FontName,
			FontSize = props.FontSize,
			Editable = false,
			Wrap = false,
			Cursor = nil,
			Color = props.TextColor or "text",
			AlignY = "center",
			layout = {
				GrowWidth = 1,
				FitWidth = false,
			},
			OnKeyInput = function(self, key, press)
				if not state.editing or not press then return end

				if key == "enter" then return stop_editing(true) end

				if key == "escape" then return stop_editing(false) end
			end,
		},
	}

	function panel:SetValue(new_value, notify)
		local old_value = value
		value = new_value
		update_display_text()

		if notify and old_value ~= value and props.OnChange then
			props.OnChange(value, old_value)
		end

		return self
	end

	function panel:GetValue()
		return value
	end

	function panel:EncodeValue()
		return format_edit_value(value)
	end

	function panel:DecodeValue(text)
		local parsed = parse_value(text, value)

		if parsed == nil then return nil, false end

		return parsed, true
	end

	function panel:BeginEdit()
		begin_editing()
		return self
	end

	function panel:EndEdit(commit)
		stop_editing(commit ~= false)
		return self
	end

	function panel:IsEditing()
		return state.editing
	end

	function panel:IsDragging()
		return state.dragging
	end

	if props.ContextMenu then Value.InstallContextMenu(panel, props.ContextMenu) end

	if external_ref then external_ref(panel) end

	return panel
end

return setmetatable(Value, {
	__call = function(_, props)
		return create_value(props)
	end,
})
