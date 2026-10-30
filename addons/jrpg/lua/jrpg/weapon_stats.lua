local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local damage = import("lua/damage.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local weapon_stats = {}
local BONUS_STEP = 0.02
local BONUS_CHANCE = 0.25
local MAX_UNLIMITED = 3
weapon_stats.Rarities = {
	{
		name = "common",
		damage_mult = 0,
		bonus = {0, 0},
		positive = 0,
		color = Color(0.47, 0.47, 0.47, 1),
	},
	{
		name = "uncommon",
		damage_mult = 0.05,
		bonus = {0, 2},
		positive = 1,
		color = Color(0.62, 0.77, 0.91, 1),
	},
	{
		name = "greater",
		damage_mult = 0.10,
		bonus = {0, 3},
		positive = 2,
		color = Color(0.24, 0.52, 0.78, 1),
	},
	{
		name = "rare",
		damage_mult = 0.15,
		bonus = {0, 6},
		positive = 2,
		color = Color(0.29, 1, 0.29, 1),
	},
	{
		name = "epic",
		damage_mult = 0.20,
		bonus = {1, 9},
		positive = 2,
		color = Color(0.95, 0.76, 0.2, 1),
	},
	{
		name = "legendary",
		damage_mult = 0.30,
		bonus = {1, 12},
		positive = MAX_UNLIMITED,
		color = Color(1, 0, 0, 1),
	},
	{
		name = "godly",
		damage_mult = 0.35,
		bonus = {1, 15},
		positive = MAX_UNLIMITED,
		color = Color(1, 1, 1, 1),
	},
}
weapon_stats.Registered = {}

for _, rarity in ipairs(weapon_stats.Rarities) do
	weapon_stats.Registered[rarity.name] = rarity
end

function weapon_stats.GetRarity(name)
	return weapon_stats.Registered[name]
end

function weapon_stats.GetColor(name)
	local rarity = weapon_stats.Registered[name]
	return rarity and rarity.color
end

weapon_stats.Statuses = {}
weapon_stats.Names = {}

function weapon_stats.RegisterStatus(definition)
	weapon_stats.Statuses[definition.Name] = definition
	table.insert(weapon_stats.Names, definition.Name)
	return definition
end

for _, name in ipairs(damage_types.Names) do
	if name ~= "generic" then
		local definition = damage_types.Get(name)
		weapon_stats.RegisterStatus{
			Name = name,
			Elemental = true,
			Chance = 0.5,
			Names = definition.Names,
			Adjectives = definition.Adjectives,
		}
	end
end

local function reflect(attacker, victim, info, amount)
	local copy = table.shallow_copy(info)
	copy.Attacker = victim
	copy.Damage = amount
	copy.Secondary = nil
	copy.WeaponStatus = true
	damage.Deal(attacker, copy)
end

weapon_stats.RegisterStatus{
	Name = "leech",
	Chance = 0.5,
	Names = {"life steal"},
	Adjectives = {"vampiric", "leeching"},
	OnDamage = function(weapon, attacker, victim, info)
		if attacker.health then
			attacker.health:Heal(math.max(info.Damage * 0.25 / weapon.Strength, 1))
		end
	end,
}
weapon_stats.RegisterStatus{
	Name = "fast",
	Chance = 0.5,
	Names = {"speed", "quickness", "haste"},
	Adjectives = {"quick", "snappy", "rapid", "swift", "accelerated", "speedy", "fast"},
	Roll = function(weapon)
		weapon:SetRateMultiplier(weapon.RateMultiplier * (1 + weapon.Strength ^ 2))
	end,
}
weapon_stats.RegisterStatus{
	Name = "decay",
	Chance = 0.1,
	Names = {"decay"},
	Adjectives = {"withering", "decaying", "fading", "deteriorating", "decay"},
	OnDamage = function(weapon, attacker, victim, info)
		status_effects.Add(victim, "decay", info.Damage / 150, attacker)
	end,
}
weapon_stats.RegisterStatus{
	Name = "deflect",
	Chance = 0.5,
	Names = {"deflect"},
	Adjectives = {"shielding", "deflecting", "repelling", "ricocheting", "warding", "resist"},
	OnReceiveDamage = function(weapon, victim, attacker, info)
		if attacker and attacker ~= victim and attacker.health and math.random() < 0.3 then
			reflect(attacker, victim, info, math.max(info.Damage * 0.3 / weapon.Strength, 1))
		end
	end,
}

function weapon_stats.RandomRarity()
	local rarities = weapon_stats.Rarities
	return rarities[math.max(math.ceil(math.random() ^ 4 * #rarities), 1)]
end

do
	local function pick(names, limit)
		local candidates = table.shallow_copy(names)
		local picked = {}

		for i = #candidates, 2, -1 do
			local j = math.random(i)
			candidates[i], candidates[j] = candidates[j], candidates[i]
		end

		for _, name in ipairs(candidates) do
			if #picked >= limit then break end

			local definition = weapon_stats.Statuses[name]

			if math.random() < definition.Chance then picked[#picked + 1] = name end
		end

		return picked
	end

	function weapon_stats.RandomStatuses(rarity)
		return pick(weapon_stats.Names, rarity.positive)
	end
end

do
	local function join(words)
		if #words < 2 then return words[1] or "" end

		return table.concat(words, ", ", 1, #words - 1) .. " and " .. words[#words]
	end

	function weapon_stats.GetTitle(display_name, rarity, names, bonus)
		local of = {}
		local first_positive

		for _, name in ipairs(names) do
			local definition = weapon_stats.Statuses[name]

			if not first_positive then
				first_positive = definition
			else
				of[#of + 1] = table.random(definition.Names)
			end
		end

		local words = {rarity.name}

		if first_positive then
			words[#words + 1] = table.random(first_positive.Adjectives or first_positive.Names)
		end

		words[#words + 1] = display_name

		if of[1] then words[#words + 1] = "of " .. join(of) end

		if bonus > 0 then words[#words + 1] = "(+" .. bonus .. ")" end

		local title = table.concat(words, " "):gsub("(%a)(%a*)", function(first, rest)
			return first:upper() .. rest
		end)
		return (title:gsub(" Of ", " of "):gsub(" And ", " and "))
	end
end

function weapon_stats.Roll(weapon, rarity_name, bonus, names)
	local rarity = rarity_name and
		weapon_stats.Registered[rarity_name] or
		weapon_stats.RandomRarity()

	if bonus == nil then
		bonus = math.random() < BONUS_CHANCE and
			math.random(rarity.bonus[1], rarity.bonus[2]) or
			0
	end

	names = names or weapon_stats.RandomStatuses(rarity)
	local attributes, statuses = {}, {}

	for _, name in ipairs(names) do
		local list = weapon_stats.Statuses[name].Elemental and attributes or statuses
		list[#list + 1] = name
	end

	weapon:SetRarity(rarity.name)
	weapon:SetDamageMultiplier(1 + rarity.damage_mult)
	weapon:SetRateMultiplier(1)
	weapon:SetStrength(1 + bonus * BONUS_STEP)
	weapon:SetAttributes(attributes)
	weapon:SetStatuses(statuses)

	for _, name in ipairs(names) do
		local roll = weapon_stats.Statuses[name].Roll

		if roll then roll(weapon, rarity) end
	end

	weapon:SetTitle(weapon_stats.GetTitle(weapon.DisplayName, rarity, names, bonus))
end

event.AddListener("RollWeapon", "jrpg_weapon_stats", function(weapon)
	weapon_stats.Roll(weapon)
end)

local function call_statuses(weapon, hook, a, b, info)
	for _, name in ipairs(weapon.Statuses) do
		local callback = weapon_stats.Statuses[name][hook]

		if callback then callback(weapon, a, b, info) end
	end
end

event.AddListener("ModifyDamage", "jrpg_weapon_stats", function(victim, info)
	if info.WeaponStatus or info.Secondary or info.Status then return end

	local attacker = info.Attacker
	local inflictor = info.Inflictor

	if attacker and inflictor and inflictor.weapon then
		call_statuses(inflictor.weapon, "OnDamage", attacker, victim, info)
	end

	for _, child in ipairs(victim:GetChildren()) do
		local weapon = child.weapon

		if weapon and weapon.Equipped ~= "" then
			call_statuses(weapon, "OnReceiveDamage", victim, attacker, info)
		end
	end
end)

return weapon_stats
