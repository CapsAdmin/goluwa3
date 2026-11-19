local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local weapons = import("lua/weapons.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
import("lua/components/weapon_holder.lua")
import("lua/components/usable.lua")
import("addons/hl2/lua/autorun/hl2.lua")

local function hl2_names()
	local names = {}

	for _, name in ipairs(weapons.GetNames()) do
		if name:starts_with("weapon_hl2_") then names[#names + 1] = name end
	end

	return names
end

T.Test("every half-life 2 weapon builds with a loaded script and its category", function()
	local names = hl2_names()
	T(#names)[">="](12)

	for _, name in ipairs(names) do
		local instance = Entity.New{prefab = {Path = name}}
		T(instance.script.Error == nil)["=="](true)
		T(instance.script.instance ~= nil)["=="](true)
		T(instance.weapon:GetCategory())["=="]("hl2")
		T(instance.weapon:GetModel():GetParent())["=="](instance)
		instance:Remove()
	end
end)

T.Test("given half-life 2 weapons start with a full clip and their reserve ammo", function()
	local pvars = import("goluwa/cli/pvars.lua")
	local infinite = pvars.Get("sv_infinite_ammo")
	pvars.SetSession("sv_infinite_ammo", false)
	local cmd = usercmd.New()
	local owner = Entity.New{transform = {}, weapon_holder = {}}
	owner.character_movement = {
		Scale = 1,
		GetCommand = function()
			return cmd
		end,
	}
	local smg = owner.weapon_holder:Give("weapon_hl2_smg1").weapon
	T(smg.Clip)["=="](45)
	T(owner.weapon_holder:GetAmmo("smg1"))["=="](225)
	T(owner.weapon_holder:GetAmmo("smg1_grenade"))["=="](3)
	local dropped = weapons.Spawn("weapon_hl2_smg1", Vec3(0, 1, 0))
	T(owner.weapon_holder:Pickup(dropped))["=="](true)
	T(dropped:IsValid())["=="](false)
	T(owner.weapon_holder:GetAmmo("smg1"))["=="](450)
	pvars.SetSession("sv_infinite_ammo", true)
	T(owner.weapon_holder:GetAmmo("smg1"))["=="](math.huge)
	pvars.SetSession("sv_infinite_ammo", infinite)
	owner:Remove()
end)
