local prototype = require("prototype")
local mouse_input = require("ecs.components.2d.mouse_input")
local key_input = require("ecs.components.2d.key_input")
local META = prototype.CreateTemplate("clickable_2d")
META.ComponentName = "clickable_2d"
META.Require = {mouse_input, key_input}

function META:OnMouseInput(button, press, pos)
	if button == "button_1" then
		if press then
			self.is_pressing = true
		else
			if self.is_pressing then
				self.is_pressing = false

				if self.Entity.mouse_input_2d:GetHovered() then
					local entity = self.Entity

					if entity.OnClick then entity:OnClick() end
				end
			end
		end
	end
end

function META:KeyInput(key, press)
	if press and (key == "enter" or key == "numpad_enter") then
		local entity = self.Entity

		if entity.OnClick then
			entity:OnClick()
			return true
		end
	end
end

local clickable = library()
clickable.Component = META:Register()
return clickable
