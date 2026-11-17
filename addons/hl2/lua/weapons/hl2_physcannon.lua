local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
hl2.Model(
	"hl2_physcannon",
	"models/weapons/w_physics.mdl",
	Vec3(0, 0.06, 0.1),
	hl2.FORWARD_X
)
return {
	Values = {
		WorldSize = Vec3(0.2, 0.19, 0.59),
		WorldCenter = Vec3(0, 0.06, -0.15),
		Stance = "physgun",
		Slot = 1.1,
		Category = "hl2",
		DisplayName = "Zero Point Energy Field Manipulator",
		FireRate = 0.5,
		TwoHanded = true,
		AlwaysPose = true,
		SupportGrip = Vec3(0, 0, -0.3),
		HoldOffset = Vec3(0.09, -0.21, 0.25),
		Replacement = "hl2_physcannon",
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.18, 0.19, 0.59),
			Vec3(0, 0.06, -0.15),
			{Color = Color(0.55, 0.4, 0.2, 1), Roughness = 0.5, Metallic = 0.6}
		),
		nodes.Marker("muzzle", Vec3(0, 0.08, -0.46)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local physics = import("goluwa/physics.lua")
local network = import("goluwa/network/network.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local damage = import("lua/damage.lua")
local hl2 = import("lua/hl2.lua")
local META = objects.CreateTemplate("weapon_hl2_physcannon")
META:GetSet("PuntRange", 5)
META:GetSet("PullRange", 14)
META:GetSet("GrabRange", 3)
META:GetSet("MaxMass", 250)
META:GetSet("PuntImpulse", 900)
META:GetSet("PuntDamage", 10)
META:GetSet("LaunchSpeed", 30)
META:GetSet("HoldDistance", 0.5)
META:GetSet("PullSpeed", 18)
META:GetSet("PositionStrength", 25)
META:GetSet("VelocityResponse", 22)
META:GetSet("MaxHoldSpeed", 40)
META:GetSet("RotationStrength", 20)
META:GetSet("AngularResponse", 30)
local AIM_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}

local function is_movable(entity)
	local body = entity.rigid_body
	return body ~= nil and body:IsDynamic() and not body.WorldGeometry and not entity.health
end

local function is_holdable(entity)
	return is_movable(entity) and not entity.ragdoll and not entity.ragdoll_part
end

local function get_angular_target(current, target, strength)
	local delta = (target * current:GetConjugated()):GetNormalized()

	if delta.w < 0 then delta = delta * -1 end

	local w = math.clamp(delta.w, -1, 1)
	local angle = 2 * math.acos(w)
	local axis_scale = math.sqrt(math.max(0, 1 - w * w))

	if angle <= 0.0001 or axis_scale <= 0.0001 then return Vec3() end

	return Vec3(delta.x / axis_scale, delta.y / axis_scale, delta.z / axis_scale) * angle * strength
end

function META:Initialize()
	self.held_body = nil
end

function META:Find(cmd, range, filter)
	local character = self.Owner:GetParent()
	return physics.Sweep(hl2.GetEye(character), cmd.aim:GetForward() * range, 0.15, character, filter, AIM_OPTIONS)
end

function META:Grab(body, cmd)
	self.held_body = body
	self.held_group = body:GetCollisionGroup()
	self.held_rotation = (cmd.aim:GetConjugated() * body:GetRotation()):GetNormalized()
	local half = body:GetHalfExtents()
	self.held_reach = math.max(half.x, half.y, half.z)
	body:SetCollisionGroup(usercmd.HELD_COLLISION_GROUP)
	body:SetGravityScale(0)
	body:Wake()
	hl2.Sound(self.Owner, "weapons/physcannon/physcannon_pickup.wav", 75, 1)
end

function META:Drop(velocity)
	local body = self.held_body
	self.held_body = nil

	if body and body:IsValid() then
		body:SetCollisionGroup(self.held_group)
		body:SetGravityScale(1)
		body:SetVelocity(velocity or body:GetVelocity())
		body:Wake()
	end
end

function META:OnWeaponPrimary(cmd)
	local forward = cmd.aim:GetForward()
	local body = self.held_body

	if body then
		local mass = body:GetMass()
		self:Drop(forward * (self.LaunchSpeed * math.clamp(40 / mass, 0.25, 1)))
		body:SetAngularVelocity(Vec3(math.randomf(-3, 3), math.randomf(-3, 3), math.randomf(-3, 3)))
		hl2.RandomSound(
			self.Owner,
			{
				"weapons/physcannon/superphys_launch1.wav",
				"weapons/physcannon/superphys_launch2.wav",
				"weapons/physcannon/superphys_launch3.wav",
				"weapons/physcannon/superphys_launch4.wav",
			},
			95
		)
		return
	end

	local hit = self:Find(cmd, self.PuntRange)
	local entity = hit and hit.entity

	if not entity then
		hl2.Sound(self.Owner, "weapons/physcannon/physcannon_dryfire.wav", 75, 1)
		return
	end

	local character = self.Owner:GetParent()
	hl2.DealHit(
		hit,
		{
			Attacker = character,
			Inflictor = self.Owner,
			Damage = self.PuntDamage,
			Type = "generic",
			Force = forward * 20,
		}
	)
	local target = hit.rigid_body or entity.rigid_body

	if target and target:IsDynamic() then
		target:ApplyImpulse(forward * math.min(self.PuntImpulse, target:GetMass() * self.LaunchSpeed), hit.point)
		target:Wake()
	end

	hl2.RandomSound(
		self.Owner,
		{"weapons/physcannon/superphys_launch1.wav", "weapons/physcannon/superphys_launch2.wav"},
		90
	)
end

function META:OnWeaponSecondary(cmd)
	if self.held_body then
		self:Drop()
		hl2.Sound(self.Owner, "weapons/physcannon/physcannon_drop.wav", 75, 1)
		return 0.3
	end

	local hit = self:Find(cmd, self.PullRange, is_holdable)

	if not hit then
		hl2.Sound(self.Owner, "weapons/physcannon/physcannon_dryfire.wav", 70, 1)
		return 0.4
	end

	local body = hit.entity.rigid_body

	if body:GetMass() > self.MaxMass then
		hl2.Sound(self.Owner, "weapons/physcannon/physcannon_tooheavy.wav", 75, 1)
		return 0.5
	end

	self.pulling = body
	hl2.Sound(self.Owner, "weapons/physcannon/physcannon_claws_open.wav", 65, 1)
	return 0.1
end

function META:UpdatePull(cmd, eye)
	local body = self.pulling

	if not (body:IsValid() and self.Owner.weapon:IsSecondaryDown(cmd)) then
		self.pulling = nil
		return
	end

	local offset = eye - body:GetPosition()
	local distance = offset:GetLength()

	if distance <= self.GrabRange + self.HoldDistance then
		self.pulling = nil
		self:Grab(body, cmd)
		return
	end

	body:SetVelocity(body:GetVelocity() * 0.8 + offset / distance * (self.PullSpeed * 0.2))
	body:Wake()
end

function META:UpdateHold(dt, cmd, eye)
	local body = self.held_body

	if not body:IsValid() then
		self.held_body = nil
		return
	end

	local character = self.Owner:GetParent()
	local distance = character.character_movement:GetRadius() + self.HoldDistance + self.held_reach
	local target = eye + cmd.aim:GetForward() * distance
	local offset = target - body:GetPosition()
	local length = offset:GetLength()

	if length > 4 then
		self:Drop()
		hl2.Sound(self.Owner, "weapons/physcannon/physcannon_drop.wav", 75, 1)
		return
	end

	local wanted = length > 0.0001 and offset / length * math.min(self.MaxHoldSpeed, length * self.PositionStrength) or Vec3()
	local velocity = body:GetVelocity():Copy()
	body:SetVelocity(velocity + (wanted - velocity) * math.min(dt * self.VelocityResponse, 1))
	local angular_target = get_angular_target(body:GetRotation(), (cmd.aim * self.held_rotation):GetNormalized(), self.RotationStrength)
	local angular = body:GetAngularVelocity():Copy()
	body:SetAngularVelocity(angular + (angular_target - angular) * math.min(dt * self.AngularResponse, 1))
	body:Wake()
end

function META:OnWeaponThink(dt, cmd)
	if not network.HasAuthority() then return end

	local eye = hl2.GetEye(self.Owner:GetParent())

	if self.pulling then self:UpdatePull(cmd, eye) end

	if self.held_body then self:UpdateHold(dt, cmd, eye) end
end

function META:OnWeaponHolster()
	self.pulling = nil
	self:Drop()
end

function META:OnWeaponCharacterModeChanged()
	self.pulling = nil
	self:Drop()
end

function META:OnRemove()
	self:Drop()
end

return META:Register()
]=====],
}
