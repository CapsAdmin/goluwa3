local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local network = import("goluwa/network/network.lua")
local prefab = import("goluwa/entities/prefab.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("weapon")
local BUTTON = usercmd.BUTTON
META.Network = {
	Slot = {"number", 0.5, "reliable"},
	Active = {"boolean", 0.5, "reliable"},
	PoseArms = {"boolean", 0.1, "reliable"},
	HoldOffset = {"vec3", 0.1, "reliable"},
	SupportGrip = {"vec3", 0.1, "reliable"},
}
META:StartStorable()
META:GetSet("Slot", 1)
META:GetSet("DisplayName", "")
META:GetSet("Category", "tools")
META:IsSet("HiddenInFirstPerson", false)
META:IsSet("HeldAtEye", false)
META:IsSet("HidesPlayer", false)
META:IsSet("TwoHanded", false)
META:IsSet("HoldFromHead", false)
META:IsSet("PoseArms", true)
META:GetSet("SupportGrip", Vec3())
META:GetSet("SupportRoll", 0)
META:IsSet("Offhand", false)
META:GetSet("HoldOffset", Vec3())
META:GetSet("FireRate", 0.1)
META:GetSet("Automatic", false)
META:GetSet("WorldSize", Vec3(0.2, 0.2, 0.6))
META:GetSet("WorldCenter", Vec3())
META:GetSet("WorldMass", 3)
META:EndStorable()
META:IsSet("Active", false)

function META:Initialize()
	self.time = 0
	self.next_primary = 0
	self.next_secondary = 0
end

function META:OnEntityConstructed()
	self:RefreshWorldState()
end

function META:GetHolder()
	local parent = self.Owner:GetParent()
	return parent:IsValid() and parent.weapon_holder or nil
end

function META:IsHeld()
	return self:GetHolder() ~= nil
end

function META:RefreshWorldState()
	local owner = self.Owner
	local held = self:IsHeld()
	local model = self:GetModel()

	if model then
		prefab.Suppress()
		model.transform:SetAttachment(held and (self.Offhand and "grip_l" or "grip_r") or "root")
		model.transform:SetPosition(held and Vec3() or self.WorldCenter * -1)
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

function META:Think(dt, cmd)
	local owner = self.Owner
	self.time = self.time + dt
	owner:CallLocalEvent("OnWeaponThink", dt, cmd)

	if not usercmd.HasButton(cmd, BUTTON.ACTIVE) then return end

	local automatic = self.Automatic

	if
		self.time >= self.next_primary and
		(
			usercmd.WasPressed(cmd, BUTTON.ATTACK1) or
			automatic and
			usercmd.HasButton(cmd, BUTTON.ATTACK1)
		)
		and
		owner:CallLocalEvent("OnWeaponPrimary", cmd) ~= false
	then
		self.next_primary = self.time + self.FireRate
		local pose = self:GetHolder().Owner.character_pose

		if pose then pose:RegisterShot() end
	end

	if
		self.time >= self.next_secondary and
		(
			usercmd.WasPressed(cmd, BUTTON.ATTACK2) or
			automatic and
			usercmd.HasButton(cmd, BUTTON.ATTACK2)
		)
		and
		owner:CallLocalEvent("OnWeaponSecondary", cmd) ~= false
	then
		self.next_secondary = self.time + self.FireRate
	end
end

return META:Register()
