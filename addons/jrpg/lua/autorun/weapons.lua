local weapons = import("lua/weapons.lua")
local keyframes = import("lua/keyframes.lua")
local movesets = import("lua/movesets.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
import("lua/jrpg/weapon_stats.lua")
import("lua/jrpg/stagger.lua")
weapons.AddRootComponent("item_highlight", {})
keyframes.AddPoses(import("lua/jrpg/movesets/poses.lua"))

for _, name in ipairs{"sword", "greatsword", "rapier", "reaper"} do
	local path = "lua/jrpg/movesets/" .. name .. ".lua"
	movesets.Register(name, import(path), path)
end

for _, name in ipairs{"sword", "greatsword", "rapier", "reaper", "shield", "debug"} do
	local definition = import("lua/weapons/" .. name .. ".lua")
	weapons.Register(
		"weapon_" .. name,
		definition.Values,
		definition.Nodes,
		definition.Source,
		definition.ScriptValues
	)
end

local magic = import("lua/weapons/magic.lua")

for i, name in ipairs(damage_types.Names) do
	local definition = damage_types.Get(name)
	local values = table.shallow_copy(magic.Values)
	values.Slot = magic.Values.Slot + i - 1
	values.DisplayName = definition.DisplayName
	weapons.Register(
		"weapon_magic_" .. name,
		values,
		magic.CreateNodes(definition.Color),
		magic.Source,
		{Element = name}
	)
end

local potion = import("lua/weapons/potion.lua")

for i, kind in ipairs(potion.Kinds) do
	local values = table.shallow_copy(potion.Values)
	values.Slot = potion.Values.Slot + i - 1
	values.DisplayName = kind.DisplayName
	weapons.Register(
		"weapon_potion_" .. kind.Name,
		values,
		potion.CreateNodes(kind.Color),
		potion.Source,
		{Kind = kind.Name}
	)
end
