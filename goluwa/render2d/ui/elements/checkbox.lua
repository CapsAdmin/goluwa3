local Panel = import("goluwa/render2d/ui/panel.lua")
local Checkable = import("goluwa/render2d/ui/elements/checkable.lua")
local META = Panel:CreateTemplate("checkbox")
META.Base = Checkable
META.BoxName = "checkbox"

function META:SetValue(value, notify)
	local old_value = self.Value
	META.BaseClass.SetValue(self, value)

	if notify and old_value ~= value then self.OnChange(value, self) end

	return self
end

function META.OnChange(value, checkbox) end

function META:OnClick()
	self:SetValue(not self.Value, true)
end

return META:Register()
