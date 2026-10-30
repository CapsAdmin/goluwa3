local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BODY = {Color = Color(0.2, 0.27, 0.15, 1), Roughness = 0.45, Metallic = 0.6}
local METAL = {Color = Color(0.45, 0.45, 0.48, 1), Roughness = 0.3, Metallic = 0.9}
return {
	Values = {
		WorldSize = Vec3(0.1, 0.14, 0.1),
		WorldCenter = Vec3(),
		Slot = 18,
		Category = "items",
		DisplayName = "Grenade",
		FireRate = 1.2,
	},
	Nodes = {
		{
			guid = "casing",
			parent = "model",
			properties = {Name = "casing"},
			components = {
				transform = {Position = Vec3(0, 0.02, -0.03)},
				model = {
					ModelPath = "models/sphere.lua",
					ModelOptions = {radius = 0.045, segments = 16, rings = 10},
					MaterialConfig = BODY,
				},
			},
		},
		nodes.Box("fuze", Vec3(0.03, 0.03, 0.03), Vec3(0, 0.075, -0.03), METAL),
		nodes.Box("lever", Vec3(0.012, 0.07, 0.02), Vec3(0.025, 0.07, -0.03), METAL),
	},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local META = objects.CreateTemplate("weapon_grenade")
META:StartStorable()
META:GetSet("Damage", 140)
META:GetSet("Radius", 6)
META:GetSet("Fuse", 2.4)
META:GetSet("ThrowSpeed", 14)
META:EndStorable()
local THROW_LIFT = 2.5
local THROW_TIME = 0.35
local BODY = {Color = Color(0.2, 0.27, 0.15, 1), Roughness = 0.45, Metallic = 0.6}

function META:OnWeaponPrimary(cmd)
	local caster = self.Owner:GetParent()
	local view = cmd.aim
	local forward = view:GetForward()
	local eye = caster.transform:GetPosition() + caster.character_movement:GetViewOffset()
	local origin = eye + forward * 0.5 + view:GetRight() * 0.2 - Vec3(0, 0.15, 0)
	local velocity = forward * self.ThrowSpeed + Vec3(0, THROW_LIFT, 0)

	if caster.rigid_body then velocity = velocity + caster.rigid_body:GetVelocity() end

	caster.character_pose:PlayAction("cast_r", THROW_TIME)
	local grenade = Entity.New{
		Name = "grenade",
		transform = {Position = origin},
		rigid_body = {
			Shape = SphereShape.New(0.06),
			Mass = 0.4,
			AutomaticMass = false,
			Restitution = 0.45,
			Friction = 0.6,
			RollingFriction = 0.2,
			AngularDamping = 0.5,
			LinearDamping = 0.05,
			CCD = true,
			CanSleep = false,
		},
		model = {
			ModelPath = "models/sphere.lua",
			ModelOptions = {radius = 0.06, segments = 16, rings = 10},
			MaterialConfig = BODY,
		},
		grenade = {Damage = self.Damage, Radius = self.Radius, Fuse = self.Fuse},
		network = SERVER and {} or nil,
	}
	grenade.grenade:Launch(caster, velocity)
end

return META:Register()
]=====],
}
