local prototype = require("prototype")
local META = prototype.CreateTemplate("clickable")

function META:OnMouseInput(button, press, pos)
	if button == "button_1" then
		if press then
			self.is_pressing = true
		else
			if self.is_pressing then
				self.is_pressing = false

				if self.Owner.mouse_input:GetHovered() then
					local Owner = self.Owner

					if Owner.OnClick then Owner:OnClick() end
				end
			end
		end
	end
end

function META:KeyInput(key, press)
	if press and (key == "enter" or key == "numpad_enter") then
		local Owner = self.Owner

		if Owner.OnClick then
			Owner:OnClick()
			return true
		end
	end
end

return META:Register()
