local prototype = require("prototype")
local META = prototype.CreateTemplate("clickable")

function META:Initialize()
	self.Owner:EnsureComponent("mouse_input")
	self:AddLocalListener("OnMouseInput", self.OnMouseInput)
	self:AddLocalListener("OnKeyInput", self.OnMouseInput)
end

function META:OnMouseInput(button, press, pos)
	if button == "button_1" then
		if press then
			self.is_pressing = true
		else
			if self.is_pressing then
				self.is_pressing = false

				if self.Owner.mouse_input:GetHovered() then
					self.Owner:CallLocalEvent("OnClick")
				end
			end
		end
	end
end

function META:OnKeyInput(key, press)
	if press and (key == "enter" or key == "numpad_enter") then
		self.Owner:CallLocalEvent("OnClick")
		return true
	end
end

return META:Register()
