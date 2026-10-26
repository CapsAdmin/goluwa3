local Color = import("goluwa/structs/color.lua")
local weapon_categories = {}
weapon_categories.Registered = {}

function weapon_categories.Register(definition)
	assert(definition.Name, "a weapon category needs a name")
	assert(definition.Color, "weapon category " .. definition.Name .. " needs a color")
	definition.Label = definition.Label or definition.Name:upper()
	weapon_categories.Registered[definition.Name] = definition
	return definition
end

function weapon_categories.Get(name)
	return weapon_categories.Registered[name] or weapon_categories.Registered.unknown
end

weapon_categories.Register{Name = "unknown", Label = "OTHER", Color = Color(0.6, 0.6, 0.65, 1)}
weapon_categories.Register{Name = "tools", Label = "TOOL", Color = Color(0.35, 0.65, 0.95, 1)}
weapon_categories.Register{Name = "weapons", Label = "RANGE", Color = Color(0.95, 0.45, 0.25, 1)}
weapon_categories.Register{Name = "items", Label = "ITEMS", Color = Color(0.4, 0.85, 0.5, 1)}
return weapon_categories
