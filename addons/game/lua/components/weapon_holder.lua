local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local Entity = import("goluwa/entities/entity.lua")
local use = import("goluwa/entities/use.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
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

function META:Give(weapon_name)
	local owner = self.Owner
	local weapon = Entity.New{
		Parent = owner,
		Name = weapon_name,
		prefab = {Path = weapon_name},
		network = owner.network and {NetworkOwner = owner.network:GetNetworkOwner()} or nil,
	}

	if not self:GetActiveWeapon() then self:Select(weapon) end

	return weapon
end

function META:Pickup(weapon)
	local owner = self.Owner

	for _, held in ipairs(self:GetWeapons()) do
		if held:GetName() == weapon:GetName() then return false end
	end

	weapon.transform:SetPosition(Vec3())
	weapon.transform:SetRotation(Quat():Identity())

	if owner.network and weapon.network then
		weapon.network:SetNetworkOwner(owner.network:GetNetworkOwner())
	end

	owner:AddChild(weapon)

	if not self:GetActiveWeapon() then self:Select(weapon) end

	return true
end

function META:Drop(weapon)
	local owner = self.Owner
	local forward = owner.player_controller.cmd.view:GetForward()

	if weapon.weapon:IsActive() then
		weapon.weapon:SetActive(false)
		weapon:CallLocalEvent("OnWeaponHolster")
	end

	local position = owner.transform:GetPosition() + owner.character_movement:GetViewOffset() + forward * 0.6
	weapon:UnParent()
	weapon.transform:SetPosition(position)
	weapon.transform:SetRotation(owner.player_controller.cmd.view:Copy())
	weapon.weapon.pickup_time = system.GetElapsedTime() + weapon.weapon.PickupDelay

	if weapon.network then weapon.network:SetNetworkOwner("") end

	weapon.rigid_body:SetVelocity(forward * 6)

	if not self:GetActiveWeapon() then
		local weapons = self:GetWeapons()

		if weapons[1] then self:Select(weapons[1]) end
	end
end

function META:OnDeath()
	for _, weapon in ipairs(self:GetWeapons()) do
		weapon:Remove()
	end
end

function META:GiveLoadout()
	for _, name in ipairs(import("lua/weapons.lua").Loadout) do
		self:Give(name)
	end
end

function META:Select(weapon)
	local old = self:GetActiveWeapon()

	if old == weapon then return end

	if old then
		old.weapon:SetActive(false)
		old:CallLocalEvent("OnWeaponHolster")
	end

	weapon.weapon:SetActive(true)
	weapon:CallLocalEvent("OnWeaponEquip")
end

function META:SelectSlot(slot)
	for _, weapon in ipairs(self:GetWeapons()) do
		if weapon.weapon:GetSlot() == slot then
			self:Select(weapon)
			return
		end
	end
end

function META:HasAuthority()
	return network.HasAuthority()
end

function META:OnPhysicsUpdate(dt)
	local cmd = self.Owner.player_controller.cmd

	if cmd.select ~= 0 then self:SelectSlot(cmd.select) end

	if not self:HasAuthority() then return end

	if
		usercmd.WasPressed(cmd, usercmd.BUTTON.USE) and
		usercmd.HasButton(cmd, usercmd.BUTTON.ACTIVE)
	then
		local owner = self.Owner
		use.Press(
			owner,
			owner.transform:GetPosition() + owner.character_movement:GetViewOffset(),
			cmd.view:GetForward()
		)
	end

	local weapon = self:GetActiveWeapon()

	if
		weapon and
		usercmd.WasPressed(cmd, usercmd.BUTTON.DROP) and
		usercmd.HasButton(cmd, usercmd.BUTTON.ACTIVE)
	then
		self:Drop(weapon)
		return
	end

	if weapon then weapon.weapon:Think(dt, cmd) end
end

function META:OnPlayerModeChanged(mode)
	local weapon = self:GetActiveWeapon()

	if weapon then weapon:CallLocalEvent("OnWeaponPlayerModeChanged", mode) end
end

return META:Register()
