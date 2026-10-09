local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Control = import("goluwa/render2d/ui/widgets/properties/control.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("property_value")
META.Base = Control
META.CMP.layout = {
	Direction = "x",
	AlignmentY = "center",
	GrowWidth = 1,
	Padding = "XS",
}
META.CMP.visual = {Clipping = true}
META.CMP.mouse_input = {Cursor = "hand"}
META:StartStorable()
META:GetSet("Value", nil)
META:GetSet("Font", nil)
META:GetSet("FontSize", nil)
META:GetSet("TextColor", nil)
META:GetSet("Cursor", "hand")
META:GetSet("EditClickCount", 1)
META:GetSet("DragThreshold", nil)
META:GetSet("HoverPanelColor", nil)
META:GetSet("EditPanelColor", nil)
META:GetSet("RightElements", nil)
META:GetSet("BottomElements", nil)
META:EndStorable()

function META.FormatValue(value, field)
	if value == nil then return "" end

	return tostring(value)
end

function META.ParseValue(text, current_value, field)
	return text
end

local function on_text_key_input(text, key, press)
	local field = text.Field

	if not field._editing or not press then return end

	if key == "enter" then return field:end_editing(true) end

	if key == "escape" then return field:end_editing(false) end
end

function META.PropDefaults(_, props)
	local has_bottom = props.BottomElements and #props.BottomElements > 0
	local layout = {
		Direction = has_bottom and "y" or "x",
		ChildGap = has_bottom and "XXS" or 0,
	}

	if props.Size then
		return {
			MinSize = Vec2(80, props.Size.y),
			MaxSize = Vec2(0, props.Size.y),
			layout = layout,
		}
	end

	return {
		Size = theme.Dynamic(theme.InputSize, 220, props.FontSize),
		MinSize = theme.Dynamic(theme.InputSize, 80, props.FontSize),
		MaxSize = theme.Dynamic(theme.InputSize, 0, props.FontSize),
		layout = layout,
	}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	local right_elements = self.RightElements or {}
	local bottom_elements = self.BottomElements or {}
	self._editing = false
	self._hovered = false
	self._click_count = 0
	self._last_click_time = 0
	self._pending_drag = false
	self._dragging = false
	self._mouse_trapped = false
	self._drag_start_pos = Vec2()
	self._drag_value = self.Value
	self._last_drag_pos = Vec2()
	self:SetState("theme_role", "property_value")
	self.mouse_input:SetCursor(self.Cursor)
	local row = self

	if #right_elements > 0 then
		row = Panel.New{
			Parent = self,
			IsInternal = true,
			Name = "property_value_row",
			transform = true,
			layout = {
				Direction = "x",
				GrowWidth = 1,
				ChildGap = 0,
				AlignmentY = "center",
			},
		}
	end

	self._text = Text{
		Parent = row,
		IsInternal = true,
		Field = self,
		Text = self.FormatValue(self.Value, self),
		Font = self.Font,
		Color = self.TextColor or "text",
		Editable = false,
		Wrap = false,
		AlignY = 0.5,
		IgnoreMouseInput = true,
		layout = {
			GrowWidth = 1,
			FitWidth = false,
		},
		OnKeyInput = on_text_key_input,
	}

	for _, element in ipairs(right_elements) do
		row:AddChild(element)
	end

	for _, element in ipairs(bottom_elements) do
		self:AddChild(element)
	end
end

function META:SetValue(new_value, notify)
	local old_value = self.Value
	self.Value = new_value
	self:update_display_text()

	if notify and old_value ~= new_value then
		self.OnChange(new_value, old_value, self)
	end

	return self
end

function META:GetValue()
	return self.Value
end

function META:EncodeValue()
	return self:format_edit_value(self.Value)
end

function META:DecodeValue(text)
	local parsed = self.ParseValue(text, self.Value, self)

	if parsed == nil then return nil, false end

	return parsed, true
end

function META:IsEditing()
	return self._editing
end

function META:IsDragging()
	return self._dragging
end

function META:BeginEdit()
	if self._editing then return self end

	self._editing = true
	self._text.text:SetText(self:format_edit_value(self.Value))
	self._text.text:SetEditable(true)
	self:apply_editor_defaults()
	self._text:RequestFocus()
	self:apply_editor_defaults()

	if self._text.text.editor then self._text.text.editor:SelectAll() end

	self:update_cursor()
	self:OnEditingChanged(true)
	return self
end

function META:OnEditingChanged(editing) end

function META:EndEdit(commit)
	self:end_editing(commit ~= false)
	return self
end

function META:format_edit_value(value)
	return (self.FormatEditValue or self.FormatValue)(value, self)
end

function META:update_display_text()
	if self._editing or not self._text then return end

	self._text.text:SetText(self.FormatValue(self.Value, self))
end

function META:update_cursor()
	self.mouse_input:SetCursor(self._editing and "text_input" or self.Cursor)
	self._text.mouse_input:SetIgnoreMouseInput(not self._editing)
	self._text.mouse_input:SetCursor(self._editing and "text_input" or nil)
end

function META:apply_editor_defaults()
	local editor = self._text.text.editor

	if not editor then return end

	editor:SetMultiline(false)
	editor:SetPreserveTabsOnEnter(false)
end

function META:end_editing(commit)
	if not self._editing then return false end

	self._editing = false
	local next_value = self.Value

	if commit then
		local parsed = self.ParseValue(self._text.text:GetText(), self.Value, self)

		if parsed ~= nil then next_value = parsed end
	end

	self._text.text:SetEditable(false)
	self:SetValue(next_value, commit == true)
	objects.SetFocusedObject(NULL)
	self:update_cursor()
	self:OnEditingChanged(false)
	return true
end

function META:set_mouse_trapped(trapped)
	if self._mouse_trapped == trapped then return end

	local window = system.GetWindow()

	if trapped then
		window:PushMouseTrapRequest(self, true)
	else
		window:PopMouseTrapRequest(self)
	end

	self._mouse_trapped = trapped
end

function META:OnHover(hovered)
	self._hovered = hovered
	self:update_cursor()
end

function META:OnMouseInput(button, press, local_pos)
	if button == "button_2" and press then return self:OpenContextMenu() end

	if button ~= "button_1" or not press then return end

	if self._editing then return true end

	local now = system.GetElapsedTime()

	if now - self._last_click_time < 0.35 then
		self._click_count = self._click_count + 1
	else
		self._click_count = 1
	end

	self._last_click_time = now
	self._pending_drag = self.OnDragValue ~= nil
	self._dragging = false
	self._drag_start_pos = system.GetWindow():GetMousePosition():Copy()
	self._last_drag_pos = self._drag_start_pos:Copy()

	if self._click_count >= self.EditClickCount then
		self._pending_drag = false
		self._click_count = 0
		self:BeginEdit()
		return true
	end

	return true
end

function META:OnGlobalMouseMove(pos)
	if not self._pending_drag or self._editing then return end

	local delta = pos - self._drag_start_pos
	local started_drag = false

	if not self._dragging then
		local threshold = theme.active:ResolveSize(self.DragThreshold or "XXS")

		if math.abs(delta.x) < threshold and math.abs(delta.y) < threshold then
			return
		end

		self._dragging = true
		started_drag = true
		self._drag_value = self.Value
		self:set_mouse_trapped(true)
	end

	local window = system.GetWindow()
	local frame_delta = started_drag and
		(
			pos - self._last_drag_pos
		)
		or
		window:GetMouseDelta()
	self._last_drag_pos = pos:Copy()
	local next_value = self.OnDragValue(frame_delta, self)

	if next_value ~= nil then self:SetValue(next_value, true) end

	if self._mouse_trapped and window:ShouldWarpMouseWhenCaptured() then
		window:SetMousePosition(self._drag_start_pos)
		self._last_drag_pos = self._drag_start_pos:Copy()
	end

	return true
end

function META:OnGlobalMouseInput(button, press, pos)
	if button == "button_1" and not press then
		if self._dragging then
			self._dragging = false
			self._pending_drag = false
			self._click_count = 0
			self:set_mouse_trapped(false)
			return true
		end

		self._pending_drag = false
		self:set_mouse_trapped(false)
		return
	end

	if button == "button_1" and press and self._editing then
		if not self.visual:IsHovered(pos) then return self:end_editing(true) end
	end
end

function META:OnDraw()
	self:SetState("editing", self._editing)
	self:SetState("hovered", self._hovered)
	self:SetState("edit_fill", self.EditPanelColor)
	self:SetState("hover_fill", self.HoverPanelColor)
	theme.active:Draw(self)
end

function META:OnPostDraw()
	if self._editing or not self.DrawBackground then return end

	self.DrawBackground(self, self.Value)
end

return META:Register()
