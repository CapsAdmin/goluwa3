local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local weapons = import("lua/weapons.lua")
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
Entity.RegisterComponent("usable", import("lua/components/usable.lua"))
local BUTTON = usercmd.BUTTON
local PROBE = [[
local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("weapon_probe")

function META:OnWeaponPrimary()
	table.insert(_G.WEAPON_PROBE, self.Owner:GetName() .. " primary")
	return false
end

function META:OnWeaponSecondary()
	table.insert(_G.WEAPON_PROBE, self.Owner:GetName() .. " secondary")
	return false
end

return META:Register()
]]
local PROBES = {
	probe_sword = {Slot = 1},
	probe_rifle = {Slot = 2, TwoHanded = true},
	probe_wand = {Slot = 3},
	probe_shield = {Slot = 4, Offhand = true},
	probe_lamp = {Slot = 5, Mount = "chest"},
}

local function create()
	for name, values in pairs(PROBES) do
		weapons.Register(name, values, {}, PROBE)
	end

	local cmd = usercmd.New()
	local owner = Entity.New{transform = {}, weapon_holder = {}}
	owner.character_movement = {
		GetCommand = function()
			return cmd
		end,
	}
	local holder = owner.weapon_holder
	local given = {}

	for _, name in ipairs{"probe_sword", "probe_rifle", "probe_wand", "probe_shield", "probe_lamp"} do
		given[name] = holder:Give(name)
	end

	local function press(buttons)
		cmd.buttons = bit.bor(BUTTON.ACTIVE, buttons)
		cmd.pressed = buttons
		_G.WEAPON_PROBE = {}
		holder:OnPhysicsUpdate(1)
		cmd.buttons, cmd.pressed, cmd.select, cmd.select_left = 0, 0, 0, false
		return table.concat(_G.WEAPON_PROBE, ", ")
	end

	local function select(name, left)
		for i, weapon in ipairs(holder:GetWeapons()) do
			if weapon:GetName() == name then cmd.select = i end
		end

		cmd.select_left = left
		press(0)
	end

	local function done()
		owner:Remove()
		_G.WEAPON_PROBE = nil

		for name in pairs(PROBES) do
			weapons.Definitions[name] = nil
			prefab.definitions[name] = nil
		end
	end

	return holder, given, press, select, done
end

T.Test("given weapons go to their default place and while dual wielding each mouse button fires its own hand", function()
	local holder, given, press, _, done = create()
	T(holder:GetWeapon("right"))["=="](given.probe_sword)
	T(holder:GetWeapon("left"))["=="](given.probe_shield)
	T(holder:GetWeapon("chest"))["=="](given.probe_lamp)
	T(given.probe_shield.weapon:GetModel().transform:GetAttachment())["=="]("grip_l")
	T(given.probe_lamp.weapon:GetModel().transform:GetAttachment())["=="]("chest")
	T(press(BUTTON.ATTACK1))["=="]("probe_shield primary")
	T(press(BUTTON.ATTACK2))["=="]("probe_sword primary")
	T(press(BUTTON.ATTACK3))["=="]("probe_lamp primary")
	holder:EmptyLeftHand()
	T(press(BUTTON.ATTACK1))["=="]("probe_sword primary")
	T(press(BUTTON.ATTACK2))["=="]("probe_sword secondary")
	done()
end)

T.Test("a two handed weapon takes both hands and the left hand weapon comes back after it", function()
	local holder, given, press, select, done = create()
	select("probe_rifle")
	T(holder:GetWeapon("right"))["=="](given.probe_rifle)
	T(holder:GetWeapon("left"))["=="](given.probe_rifle)
	T(given.probe_shield.weapon:IsEquipped())["=="](false)
	T(press(BUTTON.ATTACK2))["=="]("probe_rifle secondary")
	select("probe_wand")
	T(holder:GetWeapon("right"))["=="](given.probe_wand)
	T(holder:GetWeapon("left"))["=="](given.probe_shield)
	done()
end)

T.Test("the left hand is picked with its own selection and can be emptied", function()
	local holder, given, press, select, done = create()
	select("probe_wand", true)
	T(holder:GetWeapon("left"))["=="](given.probe_wand)
	T(given.probe_shield.weapon:IsEquipped())["=="](false)
	T(press(bit.bor(BUTTON.ATTACK1, BUTTON.ATTACK2)))["=="]("probe_sword primary, probe_wand primary")
	select("probe_rifle", true)
	T(holder:GetWeapon("left"))["=="](given.probe_wand)
	select("probe_wand")
	T(holder:GetWeapon("right"))["=="](given.probe_wand)
	T(holder:GetWeapon("left"))["=="](given.probe_sword)
	holder.Owner.character_movement:GetCommand().select = usercmd.SELECT_EMPTY
	press(0)
	T(holder:GetWeapon("left"))["=="](nil)
	select("probe_rifle")
	select("probe_sword")
	T(holder:GetWeapon("left"))["=="](nil)
	done()
end)

T.Test("a held weapon cannot be used, a weapon lying in the world can", function()
	local event = import("goluwa/event.lua")
	local Vec3 = import("goluwa/structs/vec3.lua")
	local _, given, _, _, done = create()
	local sword = given.probe_sword
	local user = Entity.New{transform = {}}

	local function find()
		local hit = event.Call("FindUseFallback", user, Vec3(0, 0, 1), Vec3(0, 0, -1), nil)
		return hit and hit.entity
	end

	T(sword:CallLocalEvent("OnCanUse"))["=="](false)
	T(find())["=="](nil)
	sword:UnParent()
	sword.transform:SetPosition(Vec3(0, 0, 0))
	T(sword:CallLocalEvent("OnCanUse"))["=="](nil)
	T(find())["=="](sword)
	sword:Remove()
	user:Remove()
	done()
end)
