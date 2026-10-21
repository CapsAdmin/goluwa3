local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local system = import("goluwa/system.lua")
local network = import("goluwa/network/network.lua")
local prefab = import("goluwa/entities/prefab.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("weapon")
local BUTTON = usercmd.BUTTON
META.Network = {
	Slot = {"number", 0.5, "reliable"},
	Active = {"boolean", 0.5, "reliable"},
}
META:StartStorable()
META:GetSet("Slot", 1)
META:GetSet("DisplayName", "")
META:IsSet("HiddenInFirstPerson", false)
META:IsSet("HeldAtEye", false)
META:GetSet("FireRate", 0.1)
META:GetSet("Automatic", false)
META:GetSet("WorldSize", Vec3(0.2, 0.2, 0.6))
META:GetSet("WorldCenter", Vec3())
META:GetSet("WorldMass", 3)
META:GetSet("PickupDelay", 1)
META:EndStorable()
META:IsSet("Active", false)

function META:Initialize()
	self.time = 0
	self.next_primary = 0
	self.next_secondary = 0
	self.pickup_time = 0
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
		model.transform:SetAttachment(held and "hand_r" or "root")
		model.transform:SetPosition(held and self:GetHolder().HoldOffset or self.WorldCenter * -1)
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

function META:OnCollisionEnter(other)
	if self:IsHeld() or not network.HasAuthority() then return end

	local holder = other.weapon_holder

	if holder and system.GetElapsedTime() >= self.pickup_time then holder:Pickup(self.Owner) end
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
