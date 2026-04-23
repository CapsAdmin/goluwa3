local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local input = import("goluwa/input.lua")
local Clickable = import("lua/ui/elements/clickable.lua")
local NumberValue = import("lua/ui/elements/number_value.lua")
local Row = import("lua/ui/elements/row.lua")
local theme = import("lua/ui/theme.lua")

local function get_component(source, components, index, default)
	if source == nil then return default end

	if type(source) == "number" then return source end

	local value = source[components[index]]

	if value == nil then value = source[index] end

	if value == nil then return default end

	return value
end

local function clamp_component(value, min, max)
	return math.clamp(value, min, max)
end

local function values_equal(a, b, components)
	for index, key in ipairs(components) do
		if a[key] ~= b[key] or a[index] ~= b[index] then return false end
	end

	return true
end

local function resolve_size(value)
	if type(value) == "string" then return theme.GetSize(value) end

	return value
end

return function(props)
	props = props or {}
	local external_ref = props.Ref

	if external_ref then
		props = table.shallow_copy(props)
		props.Ref = nil
	end

	local size = props.Size or Vec2(220, 34)
	local min_size = props.MinSize or Vec2(140, size.y)
	local max_size = props.MaxSize or Vec2(0, size.y)
	local components = props.Components or {"x", "y", "z"}
	local component_count = #components
	local show_swatch = props.ShowSwatch == true
	local component_gap = resolve_size(props.ComponentGap) or 8
	local field_height = props.FieldHeight or size.y
	local swatch_size = props.SwatchSize or field_height
	local field_width = props.ComponentWidth or
		math.max(
			42,
			math.floor(
				(
						size.x - component_gap * math.max(component_count - 1 + (show_swatch and 1 or 0), 0) - (
							show_swatch and
							swatch_size or
							0
						)
					) / math.max(component_count, 1)
			)
		)
	local fields = {}
	local children = {}
	local control
	local swatch
	local updating = false

	local function get_min(index)
		return tonumber(get_component(props.Min, components, index, -math.huge)) or -math.huge
	end

	local function get_max(index)
		return tonumber(get_component(props.Max, components, index, math.huge)) or math.huge
	end

	local function get_precision(index)
		local precision = get_component(props.Precision, components, index, 2)
		return tonumber(precision) or 2
	end

	local function get_drag_step(index)
		local step = get_component(props.DragStep, components, index, nil)

		if step == nil then return nil end

		return tonumber(step)
	end

	local function build_plain_value(source)
		local values = {}

		for index, key in ipairs(components) do
			local component = clamp_component(
				tonumber(get_component(source, components, index, 0)) or 0,
				get_min(index),
				get_max(index)
			)
			values[index] = component
			values[key] = component
		end

		return values
	end

	local function build_value(source)
		local values = build_plain_value(source)

		if props.Factory then return props.Factory(values, source) end

		if
			component_count == 3 and
			components[1] == "x" and
			components[2] == "y" and
			components[3] == "z"
		then
			return Vec3(values[1], values[2], values[3])
		end

		return values
	end

	local value = build_value(props.Value)

	local function get_swatch_color()
		return Color(
			tonumber(get_component(value, components, 1, 0)) or 0,
			tonumber(get_component(value, components, 2, 0)) or 0,
			tonumber(get_component(value, components, 3, 0)) or 0,
			tonumber(get_component(value, components, 4, 1)) or 1
		)
	end

	local function sync_swatch()
		if swatch and swatch:IsValid() then
			swatch.gui_element:SetColor(get_swatch_color())
		end
	end

	local function sync_fields()
		updating = true

		for index, field in ipairs(fields) do
			if field and field:IsValid() then
				field:SetValue(get_component(value, components, index, 0), false)
			end
		end

		updating = false
		sync_swatch()
	end

	for index, axis in ipairs(components) do
		children[#children + 1] = NumberValue{
			Ref = function(self)
				fields[index] = self
			end,
			Value = get_component(value, components, index, 0),
			Font = props.Font,
			FontName = props.FontName,
			FontSize = props.FontSize,
			Min = get_min(index),
			Max = get_max(index),
			Precision = get_precision(index),
			DragStep = get_drag_step(index),
			Size = Vec2(field_width, field_height),
			MinSize = Vec2(field_width, field_height),
			MaxSize = Vec2(field_width, field_height),
			OnChange = function(new_component, old_component)
				if updating then return end

				local next_value = build_plain_value(value)
				next_value[axis] = clamp_component(tonumber(new_component) or 0, get_min(index), get_max(index))
				next_value[index] = next_value[axis]

				if input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift") then
					for other_index, other_axis in ipairs(components) do
						if other_index ~= index then
							next_value[other_axis] = clamp_component(next_value[axis], get_min(other_index), get_max(other_index))
							next_value[other_index] = next_value[other_axis]
						end
					end
				end

				control:SetValue(next_value, true)
			end,
			layout = {
				GrowWidth = 0,
				FitWidth = false,
			},
		}
	end

	if show_swatch then
		children[#children + 1] = Clickable{
			Ref = function(self)
				swatch = self

				if self.gui_element then
					self.gui_element.OnDraw = function(gui)
						theme.panels.surface(gui)
					end
					self.gui_element.OnPostDraw = function(gui)
						theme.panels.frame_post(gui.Owner)
					end
				end
			end,
			Color = get_swatch_color(),
			Mode = "filled",
			OnClick = function()
				if props.OnSwatchClick then props.OnSwatchClick(value, control) end
			end,
			layout = {
				GrowWidth = 0,
				FitWidth = false,
				MinSize = Vec2(swatch_size, field_height),
				MaxSize = Vec2(swatch_size, field_height),
			},
		}()
	end

	control = Row{
		Name = props.Name or "vector_value",
		transform = {
			Size = size,
		},
		layout = {
			GrowWidth = 1,
			FitWidth = false,
			MinSize = min_size,
			MaxSize = max_size,
			ChildGap = component_gap,
			AlignmentY = "center",
			props.layout,
		},
	}(children)

	function control:SetValue(new_value, notify)
		local old_value = build_value(value)
		value = build_value(new_value)
		sync_fields()

		if notify and not values_equal(old_value, value, components) and props.OnChange then
			props.OnChange(value, old_value)
		end

		return self
	end

	function control:GetValue()
		return value
	end

	function control:EncodeValue()
		local encoded = {}

		for index, field in ipairs(fields) do
			if field and field:IsValid() and field.EncodeValue then
				encoded[index] = field:EncodeValue()
			else
				encoded[index] = tostring(get_component(value, components, index, 0))
			end
		end

		return table.concat(encoded, " ")
	end

	function control:DecodeValue(text)
		local values = {}

		for number in tostring(text or ""):gmatch("[%+%-]?%d+%.?%d*") do
			values[#values + 1] = tonumber(number)

			if #values >= component_count then break end
		end

		if #values ~= component_count then return nil, false end

		return build_value(values), true
	end

	control:SetValue(value)

	if external_ref then external_ref(control) end

	return control
end
