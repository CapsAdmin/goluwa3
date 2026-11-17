local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
hl2.Model("hl2_357", "models/weapons/w_357.mdl", Vec3(0, 0.05, -0.01), hl2.FORWARD_X)
return {
	Values = {
		WorldSize = Vec3(0.05, 0.14, 0.27),
		WorldCenter = Vec3(0, 0.04, -0.06),
		Stance = "revolver",
		Slot = 2.1,
		Category = "hl2",
		DisplayName = ".357 Magnum",
		FireRate = 0.75,
		HoldOffset = Vec3(0.16, 0, 0),
		Holster = true,
		AimSlack = true,
		Replacement = "hl2_357",
		AmmoType = "357",
		ClipSize = 6,
		DefaultAmmo = 12,
		ReloadTime = 3.2,
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.05, 0.14, 0.27),
			Vec3(0, 0.04, -0.06),
			{Color = Color(0.6, 0.6, 0.62, 1), Roughness = 0.25, Metallic = 1}
		),
		nodes.Marker("muzzle", Vec3(0, 0.1, -0.17)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local hl2_gun = import("lua/hl2_gun.lua")
local hl2 = import("lua/hl2.lua")
local META = hl2_gun.Gun(
	objects.CreateTemplate("weapon_hl2_357"),
	{
		Damage = 75,
		Spread = 0.003,
		Impulse = 18,
		Muzzle = "hl2_357",
		HoleSize = 1.4,
		EmptySound = "weapons/pistol/pistol_empty.wav",
	}
)

function META:OnWeaponReload()
	local owner = self.Owner
	hl2.Sound(owner, "weapons/357/357_reload1.wav", 70, 1)
	self.reload_sounds = {
		{0.9, "weapons/357/357_reload4.wav"},
		{1.9, "weapons/357/357_reload3.wav"},
		{2.6, "weapons/357/357_spin1.wav"},
	}
	self.reload_clock = 0
end

function META:OnWeaponThink(dt)
	local queue = self.reload_sounds

	if not queue then return end

	if not self.Owner.weapon:IsReloading() then
		self.reload_sounds = nil
		return
	end

	self.reload_clock = self.reload_clock + dt

	while queue[1] and queue[1][1] <= self.reload_clock do
		hl2.Sound(self.Owner, table.remove(queue, 1)[2], 70, 1)
	end
end

return META:Register()
]=====],
}
