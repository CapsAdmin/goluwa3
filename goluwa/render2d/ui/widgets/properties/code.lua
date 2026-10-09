local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Control = import("goluwa/render2d/ui/widgets/properties/control.lua")
local CodeEditor = import("goluwa/render2d/ui/widgets/code_editor.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("property_code")
META.Base = Control
META.CMP.layout = {
	Direction = "x",
	GrowWidth = 1,
	FitWidth = false,
	FitHeight = true,
	AlignmentY = "center",
}
META:StartStorable()
META:GetSet("Value", "")
META:GetSet("Language", "lua")
META:GetSet("FontSize", nil)
META:GetSet("FieldPadding", nil)
META:GetSet("RowHeight", 20)
META:EndStorable()

-- gives the error of the last applied code, or nothing
function META.OnGetStatus(control) end

local function get_preview(value, language)
	local lines = 0
	local first

	for line in (value .. "\n"):gmatch("(.-)\n") do
		lines = lines + 1

		if not first and line:find("%S") then first = line:match("^%s*(.-)%s*$") end
	end

	if not first then return "(empty " .. language .. ")" end

	return first .. "  (" .. lines .. " lines)"
end

local function on_value_draw(panel)
	theme.active:Draw(panel)
end

local function on_apply(code, editor)
	local control = editor.Control
	control:SetValue(code, true)
	return control.OnGetStatus(control)
end

local function on_value_click(panel)
	local control = panel.Control
	control._editor = Panel.World:Ensure(
		CodeEditor{
			Key = "CodeEditor" .. tostring(control),
			Title = control.Language:upper(),
			Code = control.Value,
			Control = control,
			OnApply = on_apply,
		}
	)
	control._editor:SetStatus(control.OnGetStatus(control) or "")
	control._editor:FocusText()
	return true
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	local height = self.RowHeight
	self._label = Text{
		Text = get_preview(self.Value, self.Language),
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
		Name = "property_code_value",
		Control = self,
		transform = {Size = Vec2(0, height)},
		layout = {
			FitWidth = false,
			GrowWidth = 1,
			MinSize = Vec2(0, height),
			MaxSize = Vec2(0, height),
			Padding = self.FieldPadding,
			AlignmentY = "center",
		},
		visual = true,
		mouse_input = {Cursor = "hand"},
		clickable = true,
		OnDraw = on_value_draw,
		OnClick = on_value_click,
	}(self._label)
end

function META:SetValue(value, notify)
	local old_value = self.Value
	self.Value = value == nil and "" or tostring(value)

	if self._label then
		self._label.text:SetText(get_preview(self.Value, self.Language))
	end

	if notify and old_value ~= self.Value then
		self.OnChange(self.Value, old_value, self)
	end

	return self
end

function META:GetValue()
	return self.Value
end

function META:EncodeValue()
	return self.Value
end

function META:DecodeValue(text)
	return tostring(text or ""), true
end

return META:Register()
