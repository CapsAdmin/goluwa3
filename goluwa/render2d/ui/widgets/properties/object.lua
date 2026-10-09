local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Control = import("goluwa/render2d/ui/widgets/properties/control.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("property_object")
META.Base = Control
META.CMP.layout = {
	Direction = "x",
	FitWidth = false,
	FitHeight = true,
	AlignmentY = "center",
}
META:StartStorable()
META:GetSet("Value", nil)
META:GetSet("FontSize", nil)
META:GetSet("FieldPadding", nil)
META:GetSet("ValueWidth", 200)
META:GetSet("RowHeight", 20)
META:GetSet("ActionButtonSize", nil)
META:GetSet("ActionPreviewPadding", nil)
META:EndStorable()

function META.GetDisplayText(value, control)
	return value == nil and "None" or tostring(value)
end

function META.GetActionTexture(value, control)
	return value
end

function META.OnActionButton(control) end

local function on_value_draw(panel)
	theme.active:Draw(panel)
end

local function on_action_draw(button)
	local control = button.Control
	local size = button.transform:GetSize()
	theme.active:Draw(button)

	if control.OnDrawActionButton then
		control.OnDrawActionButton(control, button, size)
		return
	end

	local texture = control.GetActionTexture(control.Value, control)

	if texture then
		local padding = theme.active:ResolveSize(control.ActionPreviewPadding or "XXS")
		render2d.SetTexture(texture)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(padding, padding, size.x - padding * 2, size.y - padding * 2)
	end
end

local function on_action_click(button)
	button.Control.OnActionButton(button.Control)
	return true
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	local gap = self.layout:GetChildGap()
	local height = self.RowHeight
	local button_size = self.ActionButtonSize or height
	local width = self.ValueWidth - button_size - gap
	self._label = Text{
		Text = self.GetDisplayText(self.Value, self),
		FontSize = self.FontSize,
		Elide = true,
		ElideString = "...",
		IgnoreMouseInput = true,
		layout = {
			GrowWidth = 1,
			FitWidth = false,
			FitHeight = true,
		},
	}
	Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "property_object_value",
		transform = {Size = Vec2(width, height)},
		layout = {
			FitWidth = false,
			GrowWidth = 1,
			MinSize = Vec2(width, height),
			MaxSize = Vec2(0, height),
			Padding = self.FieldPadding,
			AlignmentY = "center",
		},
		visual = true,
		mouse_input = {IgnoreMouseInput = true},
		OnDraw = on_value_draw,
	}(self._label)
	Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "property_object_action",
		Control = self,
		transform = {Size = Vec2(button_size, button_size)},
		layout = {
			FitWidth = false,
			MinSize = Vec2(button_size, button_size),
			MaxSize = Vec2(button_size, button_size),
		},
		visual = true,
		mouse_input = {Cursor = "pointer"},
		clickable = true,
		OnDraw = on_action_draw,
		OnClick = on_action_click,
	}
end

function META:SetValue(value, notify)
	local old_value = self.Value
	self.Value = value

	if self._label then
		self._label.text:SetText(self.GetDisplayText(value, self))
	end

	if notify and old_value ~= value then self.OnChange(value, old_value, self) end

	return self
end

function META:GetValue()
	return self.Value
end

function META:EncodeValue()
	return nil
end

return META:Register()
