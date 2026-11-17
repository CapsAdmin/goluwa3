local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
hl2.Model("hl2_frag", "models/weapons/w_grenade.mdl", Vec3(0, 0.0, -0.03), Quat(0, 0, 0, 1))
return {
	Values = {
		WorldSize = Vec3(0.07, 0.17, 0.07),
		WorldCenter = Vec3(0, 0, -0.03),
		Slot = 5.1,
		Category = "hl2",
		DisplayName = "Grenade",
		Stance = "grenade",
		FireRate = 1.2,
		AmmoType = "grenade",
		DefaultAmmo = 5,
		Replacement = "hl2_frag",
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.066, 0.17, 0.066),
			Vec3(0, 0, -0.03),
			{Color = Color(0.25, 0.3, 0.2, 1), Roughness = 0.5, Metallic = 0.5}
		),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local hl2 = import("lua/hl2.lua")
local model_replacements = import("lua/model_replacements.lua")
local META = objects.CreateTemplate("weapon_hl2_frag")
local FALLBACK = {ModelPath = "models/sphere.lua", ModelOptions = {radius = 0.045, segments = 12, rings = 8}}
META:GetSet("Damage", 125)
META:GetSet("Radius", 6)
META:GetSet("Fuse", 3)
META:GetSet("ThrowSpeed", 16)
META:GetSet("LobSpeed", 7)

function META:Throw(cmd, speed, lift, sound)
	local caster = self.Owner:GetParent()
	local view = cmd.aim
	local forward = view:GetForward()
	local origin = hl2.GetEye(caster) + forward * 0.5 + view:GetRight() * 0.2 - Vec3(0, 0.15, 0)
	local velocity = forward * speed + Vec3(0, lift, 0)

	if caster.rigid_body then velocity = velocity + caster.rigid_body:GetVelocity() end

	caster.character_pose:PlayAction("cast_r", 0.35)
	self.Owner.weapon:TakePrimaryAmmo(1)
	hl2.Sound(self.Owner, sound, 70, 1)
	local grenade = Entity.New{
		Name = "hl2_frag",
		transform = {Position = origin},
		rigid_body = {
			Shape = SphereShape.New(0.045),
			Mass = 0.4,
			AutomaticMass = false,
			Restitution = 0.4,
			Friction = 0.6,
			RollingFriction = 0.2,
			AngularDamping = 0.5,
			LinearDamping = 0.05,
			CCD = true,
			CanSleep = false,
		},
		model = model_replacements.Get("hl2_frag") and {ModelPath = model_replacements.Get("hl2_frag").Path} or FALLBACK,
		grenade = {Damage = self.Damage, Radius = self.Radius, Fuse = self.Fuse, EffectSize = 2.6, SmallEffect = true},
		network = SERVER and {} or nil,
	}
	grenade.grenade:Launch(caster, velocity)
end

function META:OnWeaponPrimary(cmd)
	self:Throw(cmd, self.ThrowSpeed, 2.5, "weapons/slam/throw.wav")
end

function META:OnWeaponSecondary(cmd)
	self:Throw(cmd, self.LobSpeed, 1, "weapons/iceaxe/iceaxe_swing1.wav")
	return 1.2
end

return META:Register()
]=====],
}
