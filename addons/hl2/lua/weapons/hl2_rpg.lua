local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
hl2.Model(
	"hl2_rpg",
	"models/weapons/w_rocket_launcher.mdl",
	Vec3(0.04, 0.04, 0.05),
	hl2.FORWARD_X
)
hl2.Model("hl2_rocket", "models/weapons/w_missile_launch.mdl", Vec3(), hl2.FORWARD_Z)
return {
	Values = {
		WorldSize = Vec3(0.13, 0.26, 0.84),
		WorldCenter = Vec3(0.04, 0.08, -0.32),
		Stance = "rpg",
		Slot = 5,
		Category = "hl2",
		DisplayName = "RPG",
		FireRate = 0.5,
		TwoHanded = true,
		AlwaysPose = true,
		SupportGrip = Vec3(0, -0.02, -0.3),
		HoldOffset = Vec3(0.06, 0.06, 0.32),
		Replacement = "hl2_rpg",
		AmmoType = "rpg_round",
		DefaultAmmo = 3,
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.12, 0.26, 0.84),
			Vec3(0.04, 0.08, -0.32),
			{Color = Color(0.25, 0.27, 0.22, 1), Roughness = 0.5, Metallic = 0.6}
		),
		nodes.Marker("muzzle", Vec3(0.04, 0.12, -0.75)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local physics = import("goluwa/physics.lua")
local hl2 = import("lua/hl2.lua")
local META = objects.CreateTemplate("weapon_hl2_rpg")
META:GetSet("RocketSpeed", 28)
META:GetSet("Damage", 150)
META:GetSet("Radius", 4.5)
META:GetSet("Range", 400)
local AIM_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}
local sprites

function META:Initialize()
	self.guiding = true
	self:AddGlobalEvent("Update")
end

function META:GetLaserPoint(cmd)
	local character = self.Owner:GetParent()
	local eye = hl2.GetEye(character)
	local forward = cmd.aim:GetForward()
	local hit = physics.Sweep(eye, forward * self.Range, 0, character, nil, AIM_OPTIONS)
	return hit and hit.point or eye + forward * self.Range, hit and hit.normal
end

function META:OnWeaponPrimary(cmd)
	local rocket = self.rocket

	if rocket and rocket:IsValid() then return false end

	local character = self.Owner:GetParent()
	self.Owner.weapon:TakePrimaryAmmo(1)
	hl2.Sound(self.Owner, "weapons/rpg/rocketfire1.wav", 125, 1)
	import("lua/weapon_effects.lua").MuzzleFlash(self.Owner, cmd.aim:GetForward(), "hl2_rpg")
	self.rocket = hl2.Launch(
		character,
		self.Owner,
		hl2.GetLaunchOrigin(character, cmd.aim, 0.9),
		cmd.aim:GetForward() * self.RocketSpeed,
		{Kind = "rocket", Damage = self.Damage, Radius = self.Radius, Speed = self.RocketSpeed, Life = 12}
	)
	character.character_movement:Push(cmd.aim:GetForward() * -1.5)
end

function META:OnWeaponSecondary()
	self.guiding = not self.guiding
	hl2.Sound(self.Owner, "weapons/slam/buttonclick.wav", 60, 1)
	return 0.3
end

function META:OnWeaponThink(dt, cmd)
	local rocket = self.rocket

	if not (rocket and rocket:IsValid()) then
		self.rocket = nil
		return
	end

	rocket.hl2_projectile.target = self.guiding and self:GetLaserPoint(cmd) or nil
end

function META:OnUpdate()
	if not (RENDER_3D and self.guiding and self.Owner.weapon:IsEquipped()) then return end

	local character = self.Owner:GetParent()
	local cmd = character.character_movement and character.character_movement:GetCommand()

	if not cmd then return end

	local point, normal = self:GetLaserPoint(cmd)

	if not normal then return end

	sprites = sprites or import("goluwa/render3d/sprites.lua")
	local vfx = import("goluwa/render3d/vfx.lua")
	point = point + normal * 0.01
	sprites.GetBatch(vfx.GetTexture("glow")):Add(point.x, point.y, point.z, 0.05, 60, 4, 2, 1)
	sprites.GetBatch(vfx.GetTexture("glow")):Add(point.x, point.y, point.z, 0.015, 120, 60, 50, 1)
end

return META:Register()
]=====],
}
