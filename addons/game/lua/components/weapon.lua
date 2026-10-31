local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local network = import("goluwa/network/network.lua")
local event = import("goluwa/event.lua")
local prefab = import("goluwa/entities/prefab.lua")
local model_replacements = import("lua/model_replacements.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("weapon")
local BUTTON = usercmd.BUTTON
local SOCKETS = {[""] = "grip_r", right = "grip_r", left = "grip_l", chest = "chest"}
META.Network = {
	Slot = {"number", 0.5, "reliable"},
	Equipped = {"string", 0.05, "reliable"},
	Drawn = {"boolean", 0.05, "reliable"},
	PoseArms = {"boolean", 0.1, "reliable"},
	HoldOffset = {"vec3", 0.1, "reliable"},
	SupportGrip = {"vec3", 0.1, "reliable"},
	Attributes = {"table", 0.5, "reliable"},
	Statuses = {"table", 0.5, "reliable"},
	Strength = {"number", 0.5, "reliable"},
	RateMultiplier = {"number", 0.5, "reliable"},
	DamageMultiplier = {"number", 0.5, "reliable"},
	Rarity = {"string", 0.5, "reliable"},
	Title = {"string", 0.5, "reliable"},
}
META:StartStorable()
META:GetSet("Slot", 1)
META:GetSet("DisplayName", "")
META:GetSet("Category", "tools")
META:GetSet("Mount", "hand")
META:GetSet("Stance", "all")
META:IsSet("HiddenInFirstPerson", false)
META:IsSet("HeldAtEye", false)
META:IsSet("HidesPlayer", false)
META:IsSet("TwoHanded", false)
META:IsSet("HoldFromHead", false)
META:IsSet("PoseArms", true)
META:IsSet("AlwaysPose", false)
META:IsSet("Holster", false)
META:IsSet("AimSlack", false)
META:GetSet("SupportGrip", Vec3())
META:GetSet("SupportRoll", 0)
META:IsSet("Offhand", false)
META:GetSet("HoldOffset", Vec3())
META:GetSet("FireRate", 0.1)
META:GetSet("Automatic", false)
META:GetSet("WorldSize", Vec3(0.2, 0.2, 0.6))
META:GetSet("WorldCenter", Vec3())
META:GetSet("WorldMass", 3)
META:GetSet("Replacement", "")
META:GetSet("Attributes", {})
META:GetSet("Statuses", {})
META:GetSet("Strength", 1)
META:GetSet("RateMultiplier", 1)
META:GetSet("DamageMultiplier", 1)
META:GetSet("Rarity", "")
META:GetSet("Title", "")
META:IsSet("Rollable", false)
META:GetSet("Sheath", "")
META:GetSet("SheathOffset", Vec3())
META:GetSet("SheathRotation", Quat(0, 0, 0, 1))
META:GetSet("SheathDelay", 5)
META:EndStorable()
META:GetSet("Equipped", "")
META:IsSet("Drawn", false)
META:GetSet("PrimaryButton", BUTTON.ATTACK1)
META:GetSet("SecondaryButton", BUTTON.ATTACK2)

function META:Initialize()
	self:AddGlobalEvent("SourceGameMounted")
	self.time = 0
	self.next_primary = 0
	self.next_secondary = 0
	self.sheath_time = 0
end

function META:ApplyReplacement()
	local entry = self.Replacement ~= "" and model_replacements.Get(self.Replacement)

	if entry then
		local node = self.Owner.prefab:GetNode("replacement")
		prefab.Suppress()
		node.transform:SetPosition(entry.Position)
		node.transform:SetRotation(entry.Rotation)
		node.transform:SetScale(entry.Scale)
		node.model:SetModelPath(entry.Path)
		prefab.Unsuppress()
	end
end

function META:OnSourceGameMounted()
	self:ApplyReplacement()
end

function META:OnEntityConstructed()
	self:ApplyReplacement()

	if self.Rollable and self.Rarity == "" and network.HasAuthority() then
		event.Call("RollWeapon", self)
	end

	self:RefreshWorldState()
end

function META:GetDamageTypes(default)
	return #self.Attributes > 0 and self.Attributes or default
end

function META:GetDamageScale()
	return self.DamageMultiplier * (#self.Attributes > 0 and self.Strength or 1)
end

function META:GetTitle()
	return self.Title ~= "" and self.Title or self.DisplayName
end

function META:GetHolder()
	local parent = self.Owner:GetParent()
	return parent:IsValid() and parent.weapon_holder or nil
end

function META:IsHeld()
	return self:GetHolder() ~= nil
end

function META:IsEquipped()
	return self.Equipped ~= ""
end

function META:SetEquipped(where)
	if self.Equipped == where then return end

	self.Equipped = where

	if where == "" then self.Drawn = false end

	self:RefreshWorldState()
	local holder = self:GetHolder()
	local link = holder and holder.Owner.network

	if link and link.linked and not network.HasAuthority() then
		self.Owner:CallLocalEvent(where == "" and "OnWeaponHolster" or "OnWeaponEquip")
	end
end

function META:SetDrawn(drawn)
	if drawn then self.sheath_time = self.time + self.SheathDelay end

	if self.Drawn == drawn then return end

	self.Drawn = drawn
	self:RefreshWorldState()
end

function META:IsSheathed()
	return self.Sheath ~= "" and not self.Drawn
end

function META:GetDefaultPlace()
	if self.Mount ~= "hand" then return self.Mount end

	return self.Offhand and "left" or "right"
end

function META:CanEquip(where)
	if self.Mount ~= "hand" then return where == self.Mount end

	if where == "right" then return not self.Offhand end

	return where == "left" and not self.TwoHanded
end

function META:RefreshWorldState()
	local owner = self.Owner
	local held = self:IsHeld()
	local model = self:GetModel()

	if model then
		local sheathed = held and self:IsEquipped() and self:IsSheathed()
		prefab.Suppress()
		model.transform:SetAttachment(held and (sheathed and self.Sheath or SOCKETS[self.Equipped]) or "root")
		model.transform:SetPosition(sheathed and self.SheathOffset:Copy() or held and Vec3() or self.WorldCenter * -1)
		model.transform:SetRotation(sheathed and self.SheathRotation:Copy() or Quat(0, 0, 0, 1))
		model.visibility:SetVisible(not held)
		prefab.Unsuppress()
	end

	if not network.HasAuthority() then return end

	if held then
		if owner.rigid_body then owner:RemoveComponent("rigid_body") end
	elseif not owner.rigid_body then
		owner:EnsureComponent(
			"rigid_body",
			{
				Shape = BoxShape.New(self.WorldSize),
				MotionType = "dynamic",
				Mass = self.WorldMass,
				AutomaticMass = false,
				Friction = 0.6,
				LinearDamping = 0.05,
				AngularDamping = 0.2,
			}
		)
	end
end

function META:OnCanUse()
	if self:IsHeld() then return false end
end

function META:OnParent()
	self:RefreshWorldState()
end

function META:OnUnParent()
	self:RefreshWorldState()
end

function META:OnUsed(user)
	if self:IsHeld() or not network.HasAuthority() then return end

	return user.weapon_holder:Pickup(self.Owner)
end

function META:GetModel()
	local instance = self.Owner.prefab
	return instance and instance:GetNode("model")
end

function META:GetMuzzle()
	return self.Owner.prefab:GetNode("muzzle")
end

function META:UpdateModel(visible)
	self:GetModel().visibility:SetVisible(visible)
end

function META:IsPrimaryDown(cmd)
	return usercmd.HasButton(cmd, BUTTON.ACTIVE) and
		usercmd.HasButton(cmd, self.PrimaryButton)
end

function META:WasPrimaryPressed(cmd)
	return usercmd.HasButton(cmd, BUTTON.ACTIVE) and
		usercmd.WasPressed(cmd, self.PrimaryButton)
end

function META:IsSecondaryDown(cmd)
	return usercmd.HasButton(cmd, BUTTON.ACTIVE) and
		usercmd.HasButton(cmd, self.SecondaryButton)
end

function META:WasSecondaryPressed(cmd)
	return usercmd.HasButton(cmd, BUTTON.ACTIVE) and
		usercmd.WasPressed(cmd, self.SecondaryButton)
end

local function run(self, dt, cmd, primary, secondary, think, press_primary, press_secondary)
	local owner = self.Owner
	self.time = self.time + dt

	if self.Drawn and self.Sheath ~= "" and self.time >= self.sheath_time then
		self:SetDrawn(false)
	end

	self.PrimaryButton = primary
	self.SecondaryButton = secondary
	owner:CallLocalEvent(think, dt, cmd)

	if not usercmd.HasButton(cmd, BUTTON.ACTIVE) then return end

	local automatic = self.Automatic

	if
		self.time >= self.next_primary and
		(
			usercmd.WasPressed(cmd, primary) or
			automatic and
			usercmd.HasButton(cmd, primary)
		)
		and
		owner:CallLocalEvent(press_primary, cmd) ~= false
	then
		self.next_primary = self.time + self.FireRate / self.RateMultiplier
		local pose = self:GetHolder().Owner.character_pose

		if pose then pose:RegisterShot() end
	end

	if
		self.time >= self.next_secondary and
		(
			usercmd.WasPressed(cmd, secondary) or
			automatic and
			usercmd.HasButton(cmd, secondary)
		)
		and
		owner:CallLocalEvent(press_secondary, cmd) ~= false
	then
		self.next_secondary = self.time + self.FireRate / self.RateMultiplier
	end
end

function META:Think(dt, cmd, primary, secondary)
	run(
		self,
		dt,
		cmd,
		primary,
		secondary,
		"OnWeaponThink",
		"OnWeaponPrimary",
		"OnWeaponSecondary"
	)
end

function META:Predict(dt, cmd, primary, secondary)
	run(
		self,
		dt,
		cmd,
		primary,
		secondary,
		"OnWeaponPredictThink",
		"OnWeaponPredictPrimary",
		"OnWeaponPredictSecondary"
	)
end

return META:Register()
