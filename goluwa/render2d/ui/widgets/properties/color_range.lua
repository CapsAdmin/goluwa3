local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Control = import("goluwa/render2d/ui/widgets/properties/control.lua")
local Swatch = import("goluwa/render2d/ui/widgets/properties/swatch.lua")
local META = Panel:CreateTemplate("property_color_range")
META.Base = Control
META.CMP.layout = {
	Direction = "x",
	GrowWidth = 1,
	FitWidth = false,
	AlignmentY = "center",
	ChildGap = "XS",
}
META:StartStorable()
META:GetSet("Value", nil)
META:GetSet("RowHeight", 20)
META:EndStorable()

local function to_color(value)
	return Color(value[1], value[2], value[3], value[4] or 1)
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._value = table.copy(self.Value)
	self._swatches = {}

	for index = 1, 2 do
		local proxy = {
			Node = self.Node,
			PropertyKey = self.PropertyKey .. "/" .. index,
			PropertyPath = self.PropertyPath,
			GetValue = function()
				return to_color(self._value[index])
			end,
			SetValue = function(_, color, notify)
				self._value[index] = {color.r, color.g, color.b, color.a}
				self._swatches[index]:SetColor(color)

				if notify then self.OnChange(table.copy(self._value), nil, self) end
			end,
		}
		self._swatches[index] = Swatch{
			Parent = self,
			IsInternal = true,
			Mode = "filled",
			Color = to_color(self._value[index]),
			OnClick = function()
				self.Editor:open_color_picker_window(proxy)
			end,
			layout = {
				GrowWidth = 1,
				FitWidth = false,
				MinSize = Vec2(24, self.RowHeight),
				MaxSize = Vec2(0, self.RowHeight),
			},
		}
	end
end

function META:SetValue(value, notify)
	self.Value = value

	if not self._swatches then return self end

	self._value = table.copy(value)

	for index = 1, 2 do
		self._swatches[index]:SetColor(to_color(self._value[index]))
	end

	return self
end

function META:GetValue()
	return self._value
end

return META:Register()
