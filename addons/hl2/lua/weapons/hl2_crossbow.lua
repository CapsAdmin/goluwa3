local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
hl2.Model(
	"hl2_crossbow",
	"models/weapons/w_crossbow.mdl",
	Vec3(0, 0.07, -0.05),
	hl2.FORWARD_X
)
hl2.Model("hl2_crossbow_bolt", "models/crossbow_bolt.mdl", Vec3(0, 0, 0.2), hl2.FORWARD_Z)
return {
	Values = {
		WorldSize = Vec3(0.58, 0.19, 0.73),
		WorldCenter = Vec3(0, 0.08, -0.1),
		Stance = "crossbow",
		Slot = 4.1,
		Category = "hl2",
		DisplayName = "Crossbow",
		FireRate = 0.2,
		TwoHanded = true,
		AlwaysPose = true,
		SupportGrip = Vec3(0, 0.03, -0.25),
		HoldOffset = Vec3(0.09, -0.21, 0.25),
		Replacement = "hl2_crossbow",
		AmmoType = "xbowbolt",
		ClipSize = 1,
		DefaultAmmo = 10,
		ReloadTime = 1.7,
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.5, 0.19, 0.73),
			Vec3(0, 0.08, -0.1),
			{Color = Color(0.35, 0.25, 0.18, 1), Roughness = 0.5, Metallic = 0.4}
		),
		nodes.Marker("muzzle", Vec3(0, 0.12, -0.45)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local hl2 = import("lua/hl2.lua")
local META = objects.CreateTemplate("weapon_hl2_crossbow")
META:GetSet("BoltSpeed", 66)
META:GetSet("Damage", 100)
META:GetSet("ZoomFOV", 20)

function META:OnWeaponPrimary(cmd)
	local character = self.Owner:GetParent()
	local weapon = self.Owner.weapon
	weapon:TakePrimaryAmmo(1)
	hl2.Sound(self.Owner, "weapons/crossbow/fire1.wav", 100, 1)
	local eye = hl2.GetEye(character)
	hl2.Launch(
		character,
		self.Owner,
		eye + cmd.aim:GetForward() * 0.5,
		cmd.aim:GetForward() * self.BoltSpeed,
		{Kind = "bolt", Damage = self.Damage * weapon:GetDamageScale(), Life = 15}
	)
	weapon:StartReload()
end

function META:OnWeaponReload()
	hl2.Sound(self.Owner, "weapons/crossbow/bolt_load1.wav", 70, 1)
	self.reload_cue = 0.9
end

function META:OnWeaponThink(dt)
	if not self.reload_cue then return end

	self.reload_cue = self.reload_cue - dt

	if self.reload_cue <= 0 then
		self.reload_cue = nil
		hl2.Sound(self.Owner, "weapons/crossbow/bolt_load2.wav", 70, 1)
	end
end

function META:ToggleZoom()
	local input = self.Owner:GetParent().player_input

	if not input then return end

	if self.unzoomed_fov then
		input:SetFOV(self.unzoomed_fov)
		self.unzoomed_fov = nil
	else
		self.unzoomed_fov = input:GetFOV()
		input:SetFOV(math.rad(self.ZoomFOV))
	end
end

function META:OnWeaponSecondary()
	self:ToggleZoom()
	return 0.3
end

function META:OnWeaponPredictSecondary()
	self:ToggleZoom()
end

function META:OnWeaponHolster()
	self.reload_cue = nil

	if self.unzoomed_fov then self:ToggleZoom() end
end

return META:Register()
]=====],
}
