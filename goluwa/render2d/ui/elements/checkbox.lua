local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local objects = import("goluwa/objects/objects.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local META = Panel:CreateTemplate("checkbox")
META.CMP.animation = {}
META.CMP.clickable = {}
META.CMP.transform.Size = "M"
META.CMP.mouse_input.Cursor = "hand"

META:GetSet("Size", Vec2() + 10, function(self, val)
	self.transform:SetSize(val)
end)

function META.CMP.mouse_input:OnHover(hovered)
	self.Owner:SetState("hovered", hovered)
end

function META.CMP.gui_element:OnDraw()
	theme.active:Draw(self.Owner)
end

function META:OnCreate(props)
	self.BaseClass.OnCreate(self, props)
	self:SetValue(props.Value ~= nil and props.Value or false, false)
	self.props = props
	return self
end

function META.OnChange(val) end

function META:OnClick()
	self:SetValue(not self:GetValue(), true)
end

function META:SetValue(new_value, notify)
	local old_value = self:GetValue()
	self:SetState("value", new_value)

	if notify and old_value ~= new_value then self.OnChange(new_value) end

	return self
end

function META:GetValue()
	return self:GetState("value")
end

META:Register()
return META.New
