local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
hl2.Model("hl2_smg1", "models/weapons/w_smg1.mdl", Vec3(0, 0.035, -0.05), hl2.BACKWARD_X)
return {
	Values = {
		WorldSize = Vec3(0.05, 0.19, 0.35),
		WorldCenter = Vec3(0, 0.06, -0.07),
		Stance = "smg1",
		Slot = 3,
		Category = "hl2",
		DisplayName = "SMG",
		FireRate = 0.075,
		Automatic = true,
		TwoHanded = true,
		AlwaysPose = true,
		SupportGrip = Vec3(0, 0.03, -0.17),
		HoldOffset = Vec3(0.09, -0.21, 0.25),
		Replacement = "hl2_smg1",
		AmmoType = "smg1",
		SecondaryAmmoType = "smg1_grenade",
		ClipSize = 45,
		DefaultAmmo = 225,
		DefaultSecondaryAmmo = 3,
		ReloadTime = 1.6,
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.04, 0.19, 0.35),
			Vec3(0, 0.06, -0.07),
			{Color = Color(0.18, 0.18, 0.2, 1), Roughness = 0.4, Metallic = 0.7}
		),
		nodes.Marker("muzzle", Vec3(0, 0.1, -0.22)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local hl2_gun = import("lua/hl2_gun.lua")
local hl2 = import("lua/hl2.lua")
local META = hl2_gun.Gun(
	objects.CreateTemplate("weapon_hl2_smg1"),
	{
		Damage = 6,
		Spread = 0.04,
		Muzzle = "hl2_smg1",
		ReloadSound = "weapons/smg1/smg1_reload.wav",
		EmptySound = "weapons/pistol/pistol_empty.wav",
	}
)
META:GetSet("GrenadeSpeed", 22)
META:GetSet("GrenadeDamage", 100)
META:GetSet("GrenadeRadius", 4)

function META:OnWeaponSecondary(cmd)
	local character = self:GetCharacter()
	local weapon = self.Owner.weapon
	weapon:TakeSecondaryAmmo(1)
	hl2.Sound(self.Owner, "weapons/grenade_launcher1.wav", 120, 1)
	local velocity = (cmd.aim:GetForward() + cmd.aim:GetUp() * 0.06) * self.GrenadeSpeed

	if character.rigid_body then velocity = velocity + character.rigid_body:GetVelocity() end

	hl2.Launch(
		character,
		self.Owner,
		hl2.GetLaunchOrigin(character, cmd.aim),
		velocity,
		{Kind = "grenade", Damage = self.GrenadeDamage, Radius = self.GrenadeRadius, Life = 8}
	)
	return 1
end

return META:Register()
]=====],
}
