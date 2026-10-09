local Panel = import("goluwa/render2d/ui/panel.lua")
local open_context_menu = import("goluwa/render2d/ui/widgets/properties/context_menu.lua")
local META = Panel:CreateTemplate("property_control")
META.CMP.transform = {}
META.CMP.layout = {}
META:StartStorable()
META:GetSet("Default", nil)
META:GetSet("DefaultEncoded", nil)
META:GetSet("MenuControl", nil)
META:EndStorable()

function META.OnChange(value, old_value, control) end

function META.OnBeforeContextMenu(control) end

function META:EncodeValue()
	return tostring(self:GetValue())
end

function META:EncodeAny(value)
	return tostring(value)
end

function META:DecodeValue(text)
	return nil, false
end

function META:GetDefaultEncoded()
	if self.DefaultEncoded ~= nil then return tostring(self.DefaultEncoded) end

	if self.Default ~= nil then return self:EncodeAny(self.Default) end
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
end

function META:OnMouseInput(button, press)
	if button == "button_2" and press then return self:OpenContextMenu() end
end

function META:OpenContextMenu()
	return open_context_menu(self.MenuControl or self)
end

return META:Register()
