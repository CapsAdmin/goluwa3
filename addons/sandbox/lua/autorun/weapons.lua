local weapons = import("lua/weapons.lua")
local definition = import("lua/weapons/toolgun.lua")
weapons.Register("weapon_toolgun", definition.Values, definition.Nodes, definition.Source)
weapons.Loadout[#weapons.Loadout + 1] = "weapon_toolgun"
