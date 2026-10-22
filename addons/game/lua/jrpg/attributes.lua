local UNIT = import("goluwa/source_engine/units.lua").meters
local attributes = {}
attributes.List = {
	{Name = "health", Init = 100, Step = 25, Base = 100, Help = "maximum health"},
	{Name = "mana", Init = 75, Step = 10, Base = 50, Help = "maximum mana"},
	{Name = "stamina", Init = 25, Step = 5, Base = 75, Help = "maximum stamina"},
	{
		Name = "physical_attack",
		Init = 1,
		Step = 0.2,
		Help = "melee and weapon damage",
	},
	{
		Name = "physical_defense",
		Init = 1,
		Step = 0.2,
		Help = "less damage from physical hits",
	},
	{Name = "magic_attack", Init = 1, Step = 0.2, Help = "elemental damage"},
	{
		Name = "magic_defense",
		Init = 1,
		Step = 0.2,
		Help = "less damage from elemental hits",
	},
	{Name = "jump", Init = 1, Step = 0.2, Help = "jump height"},
	{Name = "speed", Init = 0, Step = 30 * UNIT, Help = "movement speed"},
}
attributes.ByName = {}

for _, attribute in ipairs(attributes.List) do
	attributes.ByName[attribute.Name] = attribute
end

function attributes.GetDefaults()
	local stats = {}

	for _, attribute in ipairs(attributes.List) do
		stats[attribute.Name] = attribute.Init
	end

	return stats
end

function attributes.GetNextLevelXP(level)
	return math.floor(500 * level ^ 1.5)
end

return attributes
