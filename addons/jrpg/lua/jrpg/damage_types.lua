local Color = import("goluwa/structs/color.lua")
local damage_types = {}
damage_types.List = {}
damage_types.Registered = {}
damage_types.Names = {
	"generic",
	"fire",
	"ice",
	"lightning",
	"poison",
	"water",
	"wind",
	"dark",
	"holy",
	"heal",
}
local DEFAULT_PARTICLES = {
	Spread = 180,
	SpeedMin = 0.3,
	SpeedMax = 1.5,
	LifetimeMin = 0.2,
	LifetimeMax = 0.6,
	SizeStart = 0.04,
	SizeEnd = 0,
	Drag = 3,
	GravityScale = 0,
}

function damage_types.Register(definition)
	assert(definition.Name, "a damage type needs a name")
	assert(definition.Color, "damage type " .. definition.Name .. " needs a color")
	definition.Particles = table.merge(table.shallow_copy(DEFAULT_PARTICLES), definition.Particles or {})
	definition.Glow = definition.Glow or 1
	definition.Overlay = definition.Overlay or "magic_generic"
	definition.Flicker = definition.Flicker or 0
	definition.Light = definition.Light or 1
	definition.Adjectives = definition.Adjectives or {definition.Name}
	definition.Names = definition.Names or {definition.Name}
	definition.DisplayName = definition.DisplayName or
		definition.Name:sub(1, 1):upper() .. definition.Name:sub(2)

	if not damage_types.Registered[definition.Name] then
		damage_types.List[#damage_types.List + 1] = definition
	else
		for i, existing in ipairs(damage_types.List) do
			if existing.Name == definition.Name then damage_types.List[i] = definition end
		end
	end

	damage_types.Registered[definition.Name] = definition
	return definition
end

function damage_types.Get(name)
	return damage_types.Registered[name] or damage_types.Registered.generic
end

function damage_types.IsMagic(name)
	local definition = damage_types.Registered[name]
	return definition ~= nil and name ~= "generic" and not definition.Physical
end

function damage_types.GetColor(name)
	return damage_types.Get(name).Color
end

function damage_types.MixColor(names, out)
	out = out or Color(0, 0, 0, 1)
	local r, g, b = 0, 0, 0

	for _, name in ipairs(names) do
		local color = damage_types.GetColor(name)
		r, g, b = r + color.r, g + color.g, b + color.b
	end

	local count = math.max(#names, 1)
	return out:Set(r / count, g / count, b / count, 1)
end

function damage_types.RandomName(name)
	local definition = damage_types.Get(name)
	return table.random(definition.Adjectives), table.random(definition.Names)
end

damage_types.Physical = {"slash"}

for _, list in ipairs{damage_types.Names, damage_types.Physical} do
	for _, name in ipairs(list) do
		damage_types.Register(import("lua/jrpg/damage_types/" .. name .. ".lua"))
	end
end

return damage_types
