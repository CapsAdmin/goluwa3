local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Control = import("goluwa/render2d/ui/widgets/properties/control.lua")
local Number = import("goluwa/render2d/ui/widgets/properties/number.lua")
local Swatch = import("goluwa/render2d/ui/widgets/properties/swatch.lua")
local input = import("goluwa/input.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("property_vector")
META.Base = Control
META.CMP.layout = {
	Direction = "x",
	GrowWidth = 1,
	FitWidth = false,
	AlignmentY = "center",
}
META:StartStorable()
META:GetSet("Value", nil)
META:GetSet("Components", nil)
META:GetSet("Factory", nil)
META:GetSet("Min", nil)
META:GetSet("Max", nil)
META:GetSet("Precision", nil)
META:GetSet("DragStep", nil)
META:GetSet("DragPrecisionBoost", nil)
META:GetSet("Cursor", nil)
META:GetSet("Swatch", false)
META:GetSet("SwatchSize", nil)
META:GetSet("ComponentWidth", nil)
META:GetSet("ComponentMaxWidth", 120)
META:GetSet("ValueWidth", 200)
META:GetSet("RowHeight", 20)
META:GetSet("FontSize", nil)
META:GetSet("FieldPadding", nil)
META:EndStorable()

function META.OnSwatchClick(control) end

local function get_component(source, components, index, default)
	if source == nil then return default end

	if type(source) == "number" then return source end

	local value = source[components[index]]

	if value == nil then value = source[index] end

	if value == nil then return default end

	return value
end

local function format_number(value, precision)
	local numeric = tonumber(value)

	if numeric == nil then return "" end

	if precision == nil then return tostring(numeric) end

	if precision <= 0 then return tostring(math.round(numeric)) end

	local formatted = string.format("%." .. precision .. "f", numeric)
	formatted = formatted:gsub("(%..-)0+$", "%1")
	formatted = formatted:gsub("%.$", "")
	return formatted
end

local function on_field_change(value, old_value, field)
	field.Vector:on_component_change(field.ComponentIndex, value)
end

local function on_swatch_click(swatch)
	swatch.Vector.OnSwatchClick(swatch.Vector)
end

function META:OnCreate(props)
	props.layout = {ChildGap = "XS", props.layout}
	META.BaseClass.OnCreate(self, props)
	local components = self.Components
	local gap = self.layout:GetChildGap()
	local height = self.RowHeight
	local swatch_size = self.SwatchSize or height
	local width = self.ComponentWidth or
		math.max(
			42,
			math.floor(
				(
						self.ValueWidth - gap * math.max(#components - 1 + (self.Swatch and 1 or 0), 0) - (
							self.Swatch and
							swatch_size or
							0
						)
					) / math.max(#components, 1)
			)
		)
	self._updating = false
	self._fields = {}
	self._value = self:build_value(self.Value)

	for index, key in ipairs(components) do
		self._fields[index] = Number{
			Parent = self,
			IsInternal = true,
			Vector = self,
			MenuControl = self,
			ComponentIndex = index,
			ComponentKey = key,
			Value = get_component(self._value, components, index, 0),
			Min = self:get_min(index),
			Max = self:get_max(index),
			Precision = self:get_precision(index),
			DragStep = self:get_drag_step(index),
			DragPrecisionBoost = self.DragPrecisionBoost,
			Cursor = self.Cursor or "vertical_resize",
			FontSize = self.FontSize,
			Padding = self.FieldPadding,
			Size = Vec2(width, height),
			MinSize = Vec2(width, height),
			MaxSize = Vec2(self.ComponentMaxWidth, height),
			layout = {
				GrowWidth = 1,
				FitWidth = false,
			},
			OnChange = on_field_change,
		}
	end

	if self.Swatch then
		Panel.New{
			Parent = self,
			IsInternal = true,
			transform = true,
			layout = {GrowWidth = 0.001, FitWidth = false, MinSize = Vec2(0, 1)},
		}
		self._swatch = Swatch{
			Parent = self,
			IsInternal = true,
			Vector = self,
			Mode = "filled",
			Color = self:get_swatch_color(),
			OnClick = on_swatch_click,
			layout = {
				GrowWidth = 0,
				FitWidth = false,
				MinSize = Vec2(swatch_size, height),
				MaxSize = Vec2(swatch_size, height),
			},
		}
	end
end

function META:get_min(index)
	return tonumber(get_component(self.Min, self.Components, index, -math.huge)) or
		-math.huge
end

function META:get_max(index)
	return tonumber(get_component(self.Max, self.Components, index, math.huge)) or math.huge
end

function META:get_precision(index)
	return tonumber(get_component(self.Precision, self.Components, index, nil))
end

function META:get_drag_step(index)
	return tonumber(get_component(self.DragStep, self.Components, index, nil))
end

function META:build_plain_value(source)
	local values = {}

	for index, key in ipairs(self.Components) do
		local component = math.clamp(
			tonumber(get_component(source, self.Components, index, 0)) or 0,
			self:get_min(index),
			self:get_max(index)
		)
		values[index] = component
		values[key] = component
	end

	return values
end

function META:build_value(source)
	return self.Factory(self:build_plain_value(source), source)
end

function META:get_swatch_color()
	local components = self.Components
	local value = self._value
	return Color(
		tonumber(get_component(value, components, 1, 0)) or 0,
		tonumber(get_component(value, components, 2, 0)) or 0,
		tonumber(get_component(value, components, 3, 0)) or 0,
		tonumber(get_component(value, components, 4, 1)) or 1
	)
end

function META:on_component_change(index, component)
	if self._updating then return end

	local components = self.Components
	local axis = components[index]
	local next_value = self:build_plain_value(self._value)
	next_value[axis] = math.clamp(tonumber(component) or 0, self:get_min(index), self:get_max(index))
	next_value[index] = next_value[axis]

	if input.IsShiftDown() then
		for other_index, other_axis in ipairs(components) do
			if other_index ~= index then
				next_value[other_axis] = math.clamp(next_value[axis], self:get_min(other_index), self:get_max(other_index))
				next_value[other_index] = next_value[other_axis]
			end
		end
	end

	self:SetValue(next_value, true)
end

function META:SetValue(new_value, notify)
	if not self._fields then
		self.Value = new_value
		return self
	end

	local old_value = self._value
	self._value = self:build_value(new_value)
	self.Value = self._value
	self._updating = true

	for index, field in ipairs(self._fields) do
		field:SetValue(get_component(self._value, self.Components, index, 0), false)
	end

	self._updating = false

	if self._swatch then self._swatch:SetColor(self:get_swatch_color()) end

	if notify then
		local changed = false

		for index, key in ipairs(self.Components) do
			if old_value[key] ~= self._value[key] or old_value[index] ~= self._value[index] then
				changed = true

				break
			end
		end

		if changed then self.OnChange(self._value, old_value, self) end
	end

	return self
end

function META:GetValue()
	return self._value
end

function META:EncodeAny(source)
	local encoded = {}

	for index = 1, #self.Components do
		encoded[index] = format_number(get_component(source, self.Components, index, 0), self:get_precision(index))
	end

	return table.concat(encoded, " ")
end

function META:EncodeValue()
	local encoded = {}

	for index, field in ipairs(self._fields) do
		encoded[index] = field:EncodeValue()
	end

	return table.concat(encoded, " ")
end

function META:DecodeValue(text)
	local values = {}

	for number in tostring(text or ""):gmatch("[%+%-]?%d+%.?%d*") do
		values[#values + 1] = tonumber(number)

		if #values >= #self.Components then break end
	end

	if #values ~= #self.Components then return nil, false end

	return self:build_value(values), true
end

return META:Register()
