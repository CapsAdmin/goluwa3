local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local input = import("goluwa/input.lua")
local NumberValue = import("lua/ui/elements/number_value.lua")
local Row = import("lua/ui/elements/row.lua")
local theme = import("lua/ui/theme.lua")
local axes = {"x", "y", "z"}

local function get_component(source, index, default)
	if source == nil then return default end

	if type(source) == "number" then return source end

	local value = source[axes[index]]

	if value == nil then value = source[index] end

	if value == nil then return default end

	return value
end

local function clamp_component(value, min, max)
	return math.clamp(value, min, max)
end

local function vec3_equals(a, b)
	return a.x == b.x and a.y == b.y and a.z == b.z
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
	local component_gap = resolve_size(props.ComponentGap) or 8
	local field_height = props.FieldHeight or size.y
	local field_width = props.ComponentWidth or
		math.max(42, math.floor((size.x - component_gap * 2) / 3))
	local value = Vec3(props.Value)
	local fields = {}
	local children = {}
	local control
	local updating = false

	local function get_min(index)
		return tonumber(get_component(props.Min, index, -math.huge)) or -math.huge
	end

	local function get_max(index)
		return tonumber(get_component(props.Max, index, math.huge)) or math.huge
	end

	local function get_precision(index)
		local precision = get_component(props.Precision, index, 2)
		return tonumber(precision) or 2
	end

	local function get_drag_step(index)
		local step = get_component(props.DragStep, index, nil)

		if step == nil then return nil end

		return tonumber(step)
	end

	local function build_vec3(source)
		return Vec3(
			clamp_component(tonumber(get_component(source, 1, 0)) or 0, get_min(1), get_max(1)),
			clamp_component(tonumber(get_component(source, 2, 0)) or 0, get_min(2), get_max(2)),
			clamp_component(tonumber(get_component(source, 3, 0)) or 0, get_min(3), get_max(3))
		)
	end

	local function sync_fields()
		updating = true

		for index, field in ipairs(fields) do
			if field and field:IsValid() then
				field:SetValue(get_component(value, index, 0), false)
			end
		end

		updating = false
	end

	for index, axis in ipairs(axes) do
		children[#children + 1] = NumberValue{
			Ref = function(self)
				fields[index] = self
			end,
			Value = get_component(value, index, 0),
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

				local old_value = build_vec3(value)
				local next_value = build_vec3(value)
				local delta = (tonumber(new_component) or 0) - (tonumber(old_component) or 0)
				next_value[axis] = clamp_component(tonumber(new_component) or 0, get_min(index), get_max(index))

				if input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift") then
					for other_index, other_axis in ipairs(axes) do
						if other_index ~= index then
							next_value[other_axis] = clamp_component(
								(tonumber(old_value[other_axis]) or 0) + delta,
								get_min(other_index),
								get_max(other_index)
							)
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

	control = Row{
		Name = props.Name or "vec3_value",
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
		local old_value = build_vec3(value)
		value = build_vec3(new_value)
		sync_fields()

		if notify and not vec3_equals(old_value, value) and props.OnChange then
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
				encoded[index] = tostring(get_component(value, index, 0))
			end
		end

		return table.concat(encoded, " ")
	end

	function control:DecodeValue(text)
		local values = {}

		for number in tostring(text or ""):gmatch("[%+%-]?%d+%.?%d*") do
			values[#values + 1] = tonumber(number)

			if #values >= 3 then break end
		end

		if #values ~= 3 then return nil, false end

		return build_vec3(values), true
	end

	control:SetValue(value)

	if external_ref then external_ref(control) end

	return control
end
