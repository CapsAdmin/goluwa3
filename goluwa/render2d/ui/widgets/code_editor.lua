local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local META = Panel:CreateTemplate("code_editor")
META.Base = Window
META.Title = "LUA"
local EDIT_HEIGHT = 380
META:StartStorable()
META:GetSet("Code", "")
META:EndStorable()

-- gets the text, returns an error message or nothing
function META.OnApply(code, editor) end

function META.PropDefaults(_, props)
	local size = props.Size or Vec2(640, 520)
	return {Size = size, Position = (Panel.World.transform:GetSize() - size) / 2}
end

function META:SetStatus(status)
	if self._status then self._status.text:SetText(status) end
end

function META:Apply()
	local err = self.OnApply(self._edit:GetText(), self)
	self:SetStatus(err and tostring(err) or "applied")
end

local function on_apply_click(button)
	button.Editor:Apply()
end

local function on_close_click(button)
	button.Editor:Remove()
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._edit = TextEdit{
		Text = self.Code,
		Wrap = false,
		ScrollX = true,
		ScrollY = true,
		Size = Vec2(0, EDIT_HEIGHT),
		MinSize = Vec2(100, EDIT_HEIGHT),
		MaxSize = Vec2(0, EDIT_HEIGHT),
		layout = {GrowWidth = 1, FitWidth = false},
	}
	self._status = Text{
		Text = "",
		Color = "text_disabled",
		layout = {GrowWidth = 1, FitHeight = true},
	}
	self:AddChild(
		Column{
			layout = {
				Direction = "y",
				GrowWidth = 1,
				ChildGap = "S",
				AlignmentX = "stretch",
			},
		}{
			self._edit,
			self._status,
			Row{}{
				Button{Editor = self, Text = "Apply", OnClick = on_apply_click},
				Button{Editor = self, Text = "Close", OnClick = on_close_click},
			},
		}
	)
end

function META:FocusText()
	self._edit:RequestTextFocus()
end

return META:Register()
