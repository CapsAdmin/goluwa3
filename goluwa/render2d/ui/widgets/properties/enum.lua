local Panel = import("goluwa/render2d/ui/panel.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local open_context_menu = import("goluwa/render2d/ui/widgets/properties/context_menu.lua")
local META = Panel:CreateTemplate("property_enum")
META.Base = Dropdown
META.Searchable = true
META:StartStorable()
META:GetSet("Default", nil)
META:GetSet("DefaultEncoded", nil)
META:EndStorable()

function META.OnChange(value, old_value, control) end

function META.OnBeforeContextMenu(control) end

function META.PropDefaults()
	return {ItemPadding = "S"}
end

function META:select_option(index)
	local old_value = self.Value
	META.BaseClass.select_option(self, index)
	self.OnChange(self.Value, old_value, self)
end

function META:SetValue(value, notify)
	local old_value = self.Value
	META.BaseClass.SetValue(self, value)

	if notify and old_value ~= value then self.OnChange(value, old_value, self) end

	return self
end

function META:EncodeValue()
	return tostring(self.Value)
end

function META:EncodeAny(value)
	return tostring(value)
end

function META:DecodeValue(text)
	local normalized = tostring(text or ""):match("^%s*(.-)%s*$")
	local normalized_lower = normalized:lower()

	for _, option in ipairs(self.Options) do
		local option_text
		local option_value

		if type(option) == "table" then
			option_text = tostring(option.Text or option.Label or option.Value)
			option_value = option.Value
		else
			option_text = tostring(option)
			option_value = option
		end

		if tostring(option_value) == normalized or option_text:lower() == normalized_lower then
			return option_value, true
		end
	end

	return nil, false
end

function META:GetDefaultEncoded()
	if self.DefaultEncoded ~= nil then return tostring(self.DefaultEncoded) end

	if self.Default ~= nil then return self:EncodeAny(self.Default) end
end

function META:OpenContextMenu()
	return open_context_menu(self)
end

function META:OnMouseInput(button, press)
	if button == "button_2" and press then return self:OpenContextMenu() end
end

return META:Register()
