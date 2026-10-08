local Panel = import("goluwa/render2d/ui/panel.lua")
local Checkable = import("goluwa/render2d/ui/elements/checkable.lua")
local META = Panel:CreateTemplate("radio_button")
META.Base = Checkable
META.BoxName = "radio_button"

function META.IsSelected(radio) end

function META.OnSelect(radio) end

function META:IsChecked()
	local selected = self.IsSelected(self)

	if selected ~= nil then return selected end

	return self.Value
end

function META:OnClick()
	if self:IsChecked() then return end

	self.OnSelect(self)
	self:SetValue(true)
end

return META:Register()
