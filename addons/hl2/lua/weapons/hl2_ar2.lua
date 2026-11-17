local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
hl2.Model("hl2_ar2", "models/weapons/w_irifle.mdl", Vec3(0, 0.03, -0.04), hl2.BACKWARD_X)
return {
	Values = {
		WorldSize = Vec3(0.2, 0.24, 0.68),
		WorldCenter = Vec3(0, 0.06, 0.1),
		Stance = "ar2",
		Slot = 3.1,
		Category = "hl2",
		DisplayName = "Overwatch Standard Issue Pulse Rifle",
		FireRate = 0.1,
		Automatic = true,
		TwoHanded = true,
		AlwaysPose = true,
		SupportGrip = Vec3(0, 0.0, -0.2),
		HoldOffset = Vec3(0.09, -0.21, 0.25),
		Replacement = "hl2_ar2",
		AmmoType = "ar2",
		SecondaryAmmoType = "ar2_ball",
		ClipSize = 30,
		DefaultAmmo = 90,
		DefaultSecondaryAmmo = 2,
		ReloadTime = 1.8,
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.12, 0.24, 0.68),
			Vec3(0, 0.06, 0.1),
			{Color = Color(0.16, 0.18, 0.22, 1), Roughness = 0.3, Metallic = 0.8}
		),
		nodes.Marker("muzzle", Vec3(0, 0.12, -0.24)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local hl2_gun = import("lua/hl2_gun.lua")
local hl2 = import("lua/hl2.lua")
local META = hl2_gun.Gun(
	objects.CreateTemplate("weapon_hl2_ar2"),
	{
		Damage = 11,
		Spread = 0.02,
		Impulse = 6,
		Muzzle = "hl2_ar2",
		ReloadSound = "weapons/ar2/ar2_reload.wav",
		EmptySound = "weapons/ar2/ar2_empty.wav",
	}
)
META:GetSet("BallSpeed", 25)
META:GetSet("BallDamage", 200)
META:GetSet("BallLife", 4)
META:GetSet("ChargeTime", 0.6)

function META:OnWeaponSecondary(cmd)
	if self.charge then return false end

	self.charge = self.ChargeTime
	self.Owner.weapon:TakeSecondaryAmmo(1)
	hl2.Sound(self.Owner, "weapons/cguard/charging.wav", 85, 1)
	return self.ChargeTime + 1
end

function META:OnWeaponThink(dt, cmd)
	if not self.charge then return end

	self.charge = self.charge - dt

	if self.charge > 0 then return end

	self.charge = nil
	local character = self:GetCharacter()
	hl2.Sound(self.Owner, "weapons/irifle/irifle_fire2.wav", 120, 1)
	import("lua/weapon_effects.lua").MuzzleFlash(self.Owner, cmd.aim:GetForward(), "hl2_ar2_ball")
	hl2.Launch(
		character,
		self.Owner,
		hl2.GetLaunchOrigin(character, cmd.aim, 0.8),
		cmd.aim:GetForward() * self.BallSpeed,
		{Kind = "ball", Damage = self.BallDamage, Speed = self.BallSpeed, Life = self.BallLife}
	)

	character.character_movement:Push(cmd.aim:GetForward() * -3)
end

function META:OnWeaponHolster()
	self.charge = nil
end

return META:Register()
]=====],
}
