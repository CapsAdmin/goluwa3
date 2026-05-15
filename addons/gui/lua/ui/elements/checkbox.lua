local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local panel = Panel.New{
		Name = "checkbox",
		transform = {
			Size = props.Size or "M",
		},
		layout = {
			props.layout,
		},
		OnClick = function(self)
			self:SetValue(not self:GetValue(), true)
		end,
		mouse_input = {
			Cursor = "hand",
			OnHover = function(cmp, hovered)
				cmp.Owner:SetState("hovered", hovered)
			end,
		},
		gui_element = {
			OnDraw = function(cmp)
				theme.active:Draw(cmp.Owner)
			end,
		},
		animation = true,
		clickable = true,
	}

	function panel:SetValue(new_value, notify)
		local old_value = self:GetValue()
		self:SetState("value", new_value)

		if notify and old_value ~= new_value then
			if props.OnChange then props.OnChange(new_value) end
		end

		return self
	end

	function panel:GetValue()
		return self:GetState("value")
	end

	panel:SetValue(props.Value ~= nil and props.Value or false, false)
	return panel
end
