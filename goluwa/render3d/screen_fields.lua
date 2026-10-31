local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local screen_fields = {}
screen_fields.MAX = 8
screen_fields.fields = {}
local DEFAULTS = {
	Duration = 0.8,
	Attack = 0.12,
	Radius = 4,
	Expand = true,
	Thickness = 0.35,
	Blur = 0,
	Ring = 0,
	Aberration = 0,
	Darken = 0,
	Haze = 0,
	Zoom = 0,
}

function screen_fields.Add(config)
	local field = {age = 0, position = config.Position:Copy()}

	for key, default in pairs(DEFAULTS) do
		field[key] = config[key] == nil and default or config[key]
	end

	local fields = screen_fields.fields

	if #fields >= screen_fields.MAX then table.remove(fields, 1) end

	fields[#fields + 1] = field
	return field
end

function screen_fields.Remove(field)
	table.remove_value(screen_fields.fields, field)
end

function screen_fields.Clear()
	table.clear(screen_fields.fields)
end

function screen_fields.IsActive()
	return screen_fields.fields[1] ~= nil
end

function screen_fields.GetIntensity(field)
	local t = math.min(field.age / field.Duration, 1)

	if t < field.Attack then return 1 - (1 - t / field.Attack) ^ 3 end

	local rest = 1 - (t - field.Attack) / (1 - field.Attack)
	return rest * rest
end

function screen_fields.GetRadius(field)
	if not field.Expand then return field.Radius end

	local t = math.min(field.age / field.Duration, 1)
	return field.Radius * (1 - (1 - t) ^ 3)
end

event.AddListener("Update", "screen_fields", function(dt)
	local fields = screen_fields.fields

	for i = #fields, 1, -1 do
		local field = fields[i]
		field.age = field.age + dt

		if field.age >= field.Duration then table.remove(fields, i) end
	end
end)

return screen_fields
