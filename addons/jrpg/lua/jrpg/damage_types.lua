local Color = import("goluwa/structs/color.lua")
local data_files = import("goluwa/data_files.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local damage_types = {}
damage_types.Files = data_files.New("lua/jrpg/damage_types/", {"Name", "DisplayName", "Color", "EndColor", "Apply"})
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

do
	local ACTIONS = {}

	function ACTIONS.Remove(action, victim)
		status_effects.Remove(victim, action.Remove)
	end

	function ACTIONS.Add(action, victim, info)
		status_effects.Add(victim, action.Add, info.Damage / action.Divisor, info.Attacker)
	end

	function ACTIONS.Max(action, victim, info)
		status_effects.Set(
			victim,
			action.Max,
			math.max(status_effects.Get(victim, action.Max), info.Damage / action.Divisor),
			info.Attacker
		)
	end

	function ACTIONS.HealAttacker(action, victim, info)
		local attacker = info.Attacker

		if attacker and attacker ~= victim and attacker:IsValid() and attacker.health then
			attacker.health:Heal(info.Damage * action.HealAttacker)
		end
	end

	local function get_action(action)
		for key, fn in pairs(ACTIONS) do
			if action[key] then return fn end
		end

		error("unknown damage type action")
	end

	function damage_types.Register(name, data)
		damage_types.Files:Remember(name, data)
		local definition = data_files.Realize(table.copy(data))
		definition.Name = name
		assert(definition.Color, "damage type " .. name .. " needs a color")
		definition.Particles = table.merge(table.shallow_copy(DEFAULT_PARTICLES), definition.Particles or {})
		definition.Glow = definition.Glow or 1
		definition.Overlay = definition.Overlay or "magic_generic"
		definition.Flicker = definition.Flicker or 0
		definition.Light = definition.Light or 1
		definition.Adjectives = definition.Adjectives or {name}
		definition.Names = definition.Names or {name}
		definition.DisplayName = definition.DisplayName or name:sub(1, 1):upper() .. name:sub(2)

		if definition.Apply then
			local steps = {}

			for i, action in ipairs(definition.Apply) do
				steps[i] = {get_action(action), action}
			end

			definition.OnDamage = function(victim, info)
				for i = 1, #steps do
					steps[i][1](steps[i][2], victim, info)
				end
			end
		end

		if not damage_types.Registered[name] then
			damage_types.List[#damage_types.List + 1] = definition
		else
			for i, existing in ipairs(damage_types.List) do
				if existing.Name == name then damage_types.List[i] = definition end
			end
		end

		damage_types.Registered[name] = definition
		return definition
	end
end

function damage_types.Update(name, data)
	return damage_types.Register(name, data)
end

function damage_types.Reload(name)
	return damage_types.Register(name, damage_types.Files:Read(name))
end

function damage_types.Save(name)
	return damage_types.Files:Save(name)
end

function damage_types.Get(name)
	return damage_types.Registered[name] or damage_types.Registered.generic
end

function damage_types.IsMagic(name)
	return name == "magic"
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

damage_types.Base = {"slash", "magic"}

for _, list in ipairs{damage_types.Names, damage_types.Base} do
	for _, name in ipairs(list) do
		damage_types.Register(name, import("lua/jrpg/damage_types/" .. name .. ".lua"))
	end
end

return damage_types
