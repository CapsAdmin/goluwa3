local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BODY = {Color = Color(0.85, 0.75, 0.2, 1), Roughness = 0.5, Metallic = 0}
local HANDLE = {Color = Color(0.1, 0.1, 0.1, 1), Roughness = 0.9, Metallic = 0}
local CONE = {Color = Color(0.2, 0.2, 0.22, 1), Roughness = 0.4, Metallic = 0.6}
return {
	Values = {
		WorldSize = Vec3(0.05, 0.18, 0.28),
		WorldCenter = Vec3(0, 0.03, -0.12),
		Stance = "pistol",
		Slot = 9,
		DisplayName = "Sound test",
		FireRate = 0.3,
		HoldOffset = Vec3(0.16, 0, 0),
	},
	Nodes = {
		nodes.Handle("handle", 0.022, 0.12, Vec3(0, 0, 0), HANDLE),
		nodes.Box("body", Vec3(0.05, 0.06, 0.16), Vec3(0, 0.09, -0.06), BODY),
		nodes.Muzzle(0.03, 0.06, Vec3(0, 0.09, -0.17), CONE),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local META = objects.CreateTemplate("weapon_sound_test")

function META:OnWeaponPredictPrimary(cmd)
	weapon_effects.TestSound(self.Owner, "clap")
end

function META:OnWeaponPrimary(cmd)
	weapon_effects.TestSound(self.Owner, "clap")
end

function META:OnWeaponPredictSecondary(cmd)
	weapon_effects.TestSound(self.Owner, "boom")
end

function META:OnWeaponSecondary(cmd)
	weapon_effects.TestSound(self.Owner, "boom")
end

return META:Register()
]=====],
}
