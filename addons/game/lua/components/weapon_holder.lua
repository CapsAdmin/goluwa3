local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local Entity = import("goluwa/entities/entity.lua")
local use = import("goluwa/entities/use.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("weapon_holder")
local BUTTON = usercmd.BUTTON

function META:Initialize()
	self:AddGlobalEvent("PhysicsUpdate")
	self:AddGlobalEvent("Update")
end

function META:OnUpdate()
	if not (CLIENT and RENDER_3D) then return end

	local pose = self.Owner.character_pose
	local first_person = pose and pose:IsFirstPerson()

	for _, child in ipairs(self.Owner:GetChildren()) do
		local weapon = child.weapon

		if weapon then
			weapon:UpdateModel(weapon:IsEquipped() and not (first_person and weapon:IsHiddenInFirstPerson()))
		end
	end
end

-- a two handed weapon is in the right hand and also answers for the left
function META:GetWeapon(where)
	for _, child in ipairs(self.Owner:GetChildren()) do
		local weapon = child.weapon

		if
			weapon and
			(
				weapon.Equipped == where or
				where == "left" and
				weapon.Equipped == "right" and
				weapon.TwoHanded
			)
		then
			return child
		end
	end
end

function META:GetPosedWeapon(where)
	local weapon = self:GetWeapon(where)

	if weapon and weapon.weapon:IsPoseArms() then return weapon end
end

do
	local function by_slot(a, b)
		local x, y = a.weapon:GetSlot(), b.weapon:GetSlot()

		if x ~= y then return x < y end

		return a:GetName() < b:GetName()
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

function META:FindWeapon(name)
	for _, child in ipairs(self.Owner:GetChildren()) do
		if child.weapon and child:GetName() == name then return child end
	end
end

function META:Unequip(weapon)
	if not weapon.weapon:IsEquipped() then return end

	weapon.weapon:SetEquipped("")
	weapon:CallLocalEvent("OnWeaponHolster")
end

function META:Equip(weapon, where)
	local info = weapon.weapon
	local from = info.Equipped

	if from == where then return end

	assert(info:CanEquip(where), weapon:GetName() .. " cannot be equipped in " .. where)
	self:Unequip(weapon)
	local current = self:GetWeapon(where)

	if current then self:Unequip(current) end

	if where == "right" or where == "left" then
		local other_side = where == "right" and "left" or "right"

		if info.TwoHanded then
			local other = self:GetWeapon(other_side)

			if other then self:Unequip(other) end
		elseif from == other_side and current and current.weapon:CanEquip(other_side) then
			current.weapon:SetEquipped(other_side)
			current:CallLocalEvent("OnWeaponEquip")
		end
	end

	info:SetEquipped(where)
	weapon:CallLocalEvent("OnWeaponEquip")

	if where == "right" and not info.TwoHanded and not self:GetWeapon("left") then
		local choice = self.left_choice

		if
			choice and
			choice ~= weapon and
			choice:IsValid() and
			choice:GetParent() == self.Owner
		then
			choice.weapon:SetEquipped("left")
			choice:CallLocalEvent("OnWeaponEquip")
		end
	end

	local left = self:GetWeapon("left")

	if left and left ~= self:GetWeapon("right") then
		self.left_choice = left
	elseif self.left_choice == weapon then
		self.left_choice = nil
	end
end

function META:EmptyLeftHand()
	local left = self:GetWeapon("left")

	if left and not left.weapon:IsTwoHanded() then self:Unequip(left) end

	self.left_choice = nil
end

function META:EquipDefault(weapon)
	local where = weapon.weapon:GetDefaultPlace()

	if not self:GetWeapon(where) then
		self:Equip(weapon, where)
	elseif where == "left" and not self.left_choice then
		self.left_choice = weapon
	end
end

function META:EquipFirst()
	for _, weapon in ipairs(self:GetWeapons()) do
		if weapon.weapon:CanEquip("right") then
			self:Equip(weapon, "right")
			return
		end
	end
end

function META:Give(weapon_name)
	local owner = self.Owner
	local weapon = Entity.New{
		Parent = owner,
		Name = weapon_name,
		prefab = {Path = weapon_name},
		network = SERVER and
			owner.network and
			{NetworkOwner = owner.network:GetNetworkOwner(), SendToOwner = true} or
			nil,
	}
	self:EquipDefault(weapon)
	return weapon
end

function META:Pickup(weapon)
	local owner = self.Owner

	if self:FindWeapon(weapon:GetName()) then return false end

	weapon.transform:SetPosition(Vec3())
	weapon.transform:SetRotation(Quat():Identity())

	if owner.network and weapon.network then
		weapon.network:SetNetworkOwner(owner.network:GetNetworkOwner())
		weapon.network:SetSendToOwner(true)
	end

	owner:AddChild(weapon)
	self:EquipDefault(weapon)
	return true
end

function META:Drop(weapon)
	local owner = self.Owner
	local forward = owner.character_movement:GetCommand().view:GetForward()
	self:Unequip(weapon)
	local position = owner.transform:GetPosition() + owner.character_movement:GetViewOffset() + forward * 0.6
	weapon:UnParent()
	weapon.transform:SetPosition(position)
	weapon.transform:SetRotation(owner.character_movement:GetCommand().view:Copy())

	if weapon.network then
		weapon.network:SetNetworkOwner("")
		weapon.network:SetSendToOwner(false)
	end

	weapon.rigid_body:SetVelocity(forward * 6)

	if not self:GetWeapon("right") then self:EquipFirst() end
end

function META:OnDeath()
	self:RemoveWeapons()
end

function META:RemoveWeapons()
	local children = self.Owner:GetChildren()

	for i = #children, 1, -1 do
		if children[i].weapon then children[i]:Remove() end
	end

	self.left_choice = nil
end

function META:GiveLoadout()
	for _, name in ipairs(import("lua/weapons.lua").Loadout) do
		if not self:FindWeapon(name) then self:Give(name) end
	end
end

function META:ApplySelection(cmd)
	if cmd.select == usercmd.SELECT_EMPTY then
		self:EmptyLeftHand()
		return
	end

	local weapon = self:GetWeapons()[cmd.select]
	local where = cmd.select_left and "left" or "right"

	if weapon and weapon.weapon:CanEquip(where) then self:Equip(weapon, where) end
end

function META:GetButtons(weapon)
	local equipped = weapon.weapon.Equipped

	if equipped == "right" or equipped == "left" then
		local other = self:GetWeapon(equipped == "right" and "left" or "right")

		if other and other ~= weapon then
			return equipped == "left" and BUTTON.ATTACK1 or BUTTON.ATTACK2, 0
		end

		return BUTTON.ATTACK1, BUTTON.ATTACK2
	end

	return BUTTON.ATTACK3, 0
end

function META:HasAuthority()
	return network.HasAuthority()
end

function META:OnPhysicsUpdate(dt)
	local authority = self:HasAuthority()
	local link = self.Owner.network
	local own_rig = link and link.linked

	if not authority and not own_rig then return end

	local cmd = self.Owner.character_movement:GetCommand()

	if cmd.select ~= 0 then self:ApplySelection(cmd) end

	if not authority then
		if network.IsPredicting() then
			for _, child in ipairs(self.Owner:GetChildren()) do
				if child.weapon and child.weapon:IsEquipped() then
					child.weapon:Predict(dt, cmd, self:GetButtons(child))
				end
			end
		end

		return
	end

	if self.Owner.ragdoll and self.Owner.ragdoll.Limp then return end

	if usercmd.WasPressed(cmd, BUTTON.USE) and usercmd.HasButton(cmd, BUTTON.ACTIVE) then
		local owner = self.Owner
		use.Press(
			owner,
			owner.transform:GetPosition() + owner.character_movement:GetViewOffset(),
			cmd.view:GetForward()
		)
	end

	local right = self:GetWeapon("right")
	local left = self:GetWeapon("left")

	if left == right then left = nil end

	if usercmd.WasPressed(cmd, BUTTON.DROP) and usercmd.HasButton(cmd, BUTTON.ACTIVE) then
		local dropped = right or left

		if dropped then
			self:Drop(dropped)
			return
		end
	end

	for _, child in ipairs(self.Owner:GetChildren()) do
		if child.weapon and child.weapon:IsEquipped() then
			child.weapon:Think(dt, cmd, self:GetButtons(child))
		end
	end
end

function META:OnCharacterModeChanged(mode)
	for _, child in ipairs(self.Owner:GetChildren()) do
		if child.weapon and child.weapon:IsEquipped() then
			child:CallLocalEvent("OnWeaponCharacterModeChanged", mode)
		end
	end
end

return META:Register()
