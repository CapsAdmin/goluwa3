local prototype = import("goluwa/prototype.lua")
local system = import("goluwa/system.lua")
local META = prototype.CreateTemplate("clickable")
local shared_double_click_times = setmetatable({}, {__mode = "k"})
META:StartStorable()
META:GetSet("DoubleClickTime", 0.3)
META:GetSet("DoubleClickKey", nil)
META:EndStorable()

function META:Initialize()
	self.Owner:EnsureComponent("mouse_input")
	self.Owner:EnsureComponent("key_input")
	self:AddLocalListener("OnMouseInput", self.OnMouseInput)
	self:AddLocalListener("OnKeyInput", self.OnKeyInput)
end

function META:OnMouseInput(button, press, pos)
	if button == "button_1" then
		if press then
			self.is_pressing_left = true
		else
			if self.is_pressing_left then
				self.is_pressing_left = false

				if self.Owner.mouse_input:GetHovered() then
					local now = system.GetElapsedTime()
					local double_click_key = self:GetDoubleClickKey() or self.Owner
					local last_click_time = shared_double_click_times[double_click_key]
					local is_double_click = last_click_time and now - last_click_time <= self:GetDoubleClickTime()
					shared_double_click_times[double_click_key] = now
					local handled = self.Owner:CallLocalEvent("OnClick")

					if is_double_click then
						handled = self.Owner:CallLocalEvent("OnDoubleClick") or handled
					end

					return handled
				end
			end
		end
	elseif button == "button_2" then
		if press then
			if self.Owner.mouse_input:GetHovered() then
				return self.Owner:CallLocalEvent("OnRightClick")
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
