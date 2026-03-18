local prototype = import("goluwa/prototype.lua")
local META = prototype.CreateTemplate("tui_clickable")

function META:Initialize()
	self.Owner:EnsureComponent("tui_mouse_input")
	self.is_pressing = false

	self.Owner:AddLocalListener("OnMouseInput", function(_, button, press)
		return self:OnMouseInput(button, press)
	end)

	self.Owner:AddLocalListener("OnKeyInput", function(_, key, press)
		return self:OnKeyInput(key, press)
	end)
end

function META:OnMouseInput(button, press)
	if button == "left" then
		if press then
			self.is_pressing = true
		else
			if self.is_pressing then
				self.is_pressing = false

				if self.Owner.tui_mouse_input:GetHovered() then
					self.Owner:CallLocalEvent("OnClick")
				end
			end
		end
	end
end

function META:OnKeyInput(key, press)
	if press and (key == "return" or key == "kp_enter") then
		self.Owner:CallLocalEvent("OnClick")
		return true
	end
end

return META:Register()
