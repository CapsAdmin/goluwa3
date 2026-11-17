local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
hl2.Model(
	"hl2_shotgun",
	"models/weapons/w_shotgun.mdl",
	Vec3(0, 0.045, -0.1),
	hl2.BACKWARD_X
)
return {
	Values = {
		WorldSize = Vec3(0.06, 0.17, 0.59),
		WorldCenter = Vec3(0, 0.08, -0.1),
		Stance = "shotgun",
		Slot = 4,
		Category = "hl2",
		DisplayName = "Shotgun",
		FireRate = 0.8,
		TwoHanded = true,
		AlwaysPose = true,
		SupportGrip = Vec3(0, 0.03, -0.25),
		HoldOffset = Vec3(0.09, -0.21, 0.25),
		Replacement = "hl2_shotgun",
		AmmoType = "buckshot",
		ClipSize = 6,
		DefaultAmmo = 30,
		ReloadTime = 0.5,
		ReloadIncrement = 1,
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.05, 0.17, 0.59),
			Vec3(0, 0.08, -0.1),
			{Color = Color(0.22, 0.2, 0.18, 1), Roughness = 0.4, Metallic = 0.6}
		),
		nodes.Marker("muzzle", Vec3(0, 0.12, -0.39)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local hl2_gun = import("lua/hl2_gun.lua")
local hl2 = import("lua/hl2.lua")
local RELOAD = {
	"weapons/shotgun/shotgun_reload1.wav",
	"weapons/shotgun/shotgun_reload2.wav",
	"weapons/shotgun/shotgun_reload3.wav",
}
local META = hl2_gun.Gun(
	objects.CreateTemplate("weapon_hl2_shotgun"),
	{
		Damage = 9,
		Pellets = 7,
		Spread = 0.08,
		Range = 60,
		Impulse = 3,
		Muzzle = "hl2_shotgun",
		EmptySound = "weapons/shotgun/shotgun_empty.wav",
	}
)

function META:Pump(delay)
	self.pump = delay
end

function META:OnWeaponPrimary(cmd)
	self:Shoot(cmd)
	self.Owner.weapon:TakePrimaryAmmo(1)
	self:Pump(0.4)
end

function META:OnWeaponPredictSecondary(cmd)
	if self.Owner.weapon:HasPrimaryAmmo(2) then
		self:Shoot(cmd, 12, 0.11, "hl2_shotgun_double")
	end
end

function META:OnWeaponSecondary(cmd)
	local weapon = self.Owner.weapon

	if not weapon:HasPrimaryAmmo(2) then
		if weapon:HasPrimaryAmmo(1) then return self:OnWeaponPrimary(cmd) end

		weapon:StartReload()
		return weapon.DryFireDelay
	end

	self:Shoot(cmd, 12, 0.11, "hl2_shotgun_double")
	weapon:TakePrimaryAmmo(2)
	weapon.next_primary = weapon.time + 1.3
	self:Pump(0.7)
	return 1.3
end

function META:OnWeaponThink(dt)
	if not self.pump then return end

	self.pump = self.pump - dt

	if self.pump <= 0 then
		self.pump = nil
		hl2.Sound(self.Owner, "weapons/shotgun/shotgun_cock.wav", 75, 1)
	end
end

function META:OnWeaponReload()
	hl2.RandomSound(self.Owner, RELOAD, 70)
end

function META:OnWeaponReloadStep()
	hl2.RandomSound(self.Owner, RELOAD, 70)
end

function META:OnWeaponReloaded()
	self:Pump(0.1)
end

return META:Register()
]=====],
}
