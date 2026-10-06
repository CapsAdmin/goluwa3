local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local Entity = import("goluwa/entities/entity.lua")
local META = objects.CreateTemplate("weapon_holder")

function META:Initialize()
	self:AddGlobalEvent("PhysicsUpdate")
end

function META:GetActiveWeapon()
	for _, child in ipairs(self.Owner:GetChildren()) do
		if child.weapon and child.weapon:IsActive() then return child end
	end
end

do
	local function by_slot(a, b)
		return a.weapon:GetSlot() < b.weapon:GetSlot()
	end

	function META:GetWeapons()
		local weapons = {}

		for _, child in ipairs(self.Owner:GetChildren()) do
			if child.weapon then weapons[#weapons + 1] = child end
		end

		table.sort(weapons, by_slot)
		return weapons
	end
end

function META:GetActiveSlot()
	local weapon = self:GetActiveWeapon()

	if weapon then return weapon.weapon:GetSlot() end

	return 0
end

function META:CycleSlot(slot, direction)
	local weapons = self:GetWeapons()
	local count = #weapons

	if count == 0 then return 0 end

	local index = 1

	for i, weapon in ipairs(weapons) do
		if weapon.weapon:GetSlot() == slot then
			index = i

			break
		end
	end

	return weapons[(index - 1 + direction) % count + 1].weapon:GetSlot()
end

function META:Give(component_name)
	local owner = self.Owner
	local weapon = Entity.New{
		Parent = owner,
		Name = component_name,
		ComponentSet = {"weapon", component_name},
		network = owner.network and {NetworkOwner = owner.network:GetNetworkOwner()} or nil,
	}

	if not self:GetActiveWeapon() then self:Select(weapon) end

	return weapon
end

function META:Select(weapon)
	local old = self:GetActiveWeapon()

	if old == weapon then return end

	if old then
		old.weapon:SetActive(false)
		old:CallLocalEvent("WeaponHolster")
	end

	weapon.weapon:SetActive(true)
	weapon:CallLocalEvent("WeaponEquip")
end

function META:SelectSlot(slot)
	for _, weapon in ipairs(self:GetWeapons()) do
		if weapon.weapon:GetSlot() == slot then
			self:Select(weapon)
			return
		end
	end
end

function META:GetBeamPoint()
	local weapon = self:GetActiveWeapon()

	if weapon then return weapon:CallLocalEvent("WeaponGetBeamPoint") end
end

function META:HasAuthority()
	return not (CLIENT and network.IsConnected())
end

function META:OnPhysicsUpdate(dt)
	local cmd = self.Owner.player_controller.cmd

	if cmd.select ~= 0 then self:SelectSlot(cmd.select) end

	if not self:HasAuthority() then return end

	local weapon = self:GetActiveWeapon()

	if weapon then weapon.weapon:Think(dt, cmd) end
end

function META:OnPlayerModeChanged(mode)
	local weapon = self:GetActiveWeapon()

	if weapon then weapon:CallLocalEvent("WeaponPlayerModeChanged", mode) end
end

return META:Register()
