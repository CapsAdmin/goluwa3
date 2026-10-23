local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local physics = import("goluwa/physics.lua")
Entity.RegisterComponent("magic_projectile", import("lua/components/magic_projectile.lua"))

T.TestPhysics("magic projectiles bounce off the world and fade out", function()
	local wall = Entity.New{
		transform = {Position = Vec3(0, 0, -6), Scale = Vec3(20, 20, 1)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local caster = Entity.New{transform = {Position = Vec3(0, 0, 0)}}
	local projectile = Entity.New{
		transform = {Position = Vec3(0, 0, -1)},
		rigid_body = {
			Shape = SphereShape.New(0.12),
			Mass = 0.05,
			AutomaticMass = false,
			GravityScale = 0,
			Restitution = 1,
			RestitutionCombineMode = "max",
			CCD = true,
			CanSleep = false,
		},
		magic_projectile = {Types = "fire", Damage = 10},
	}
	local component = projectile.magic_projectile
	component:Launch(caster, Vec3(0, 0, -1), nil, nil)
	component.velocity = Vec3(0, 0, -11)
	projectile.rigid_body:SetVelocity(component.velocity)
	local bounced_at

	for i = 1, 400 do
		physics.UpdateFixed(1 / 60)

		if not projectile:IsValid() then break end

		component:OnUpdate(1 / 60)

		if component.Bounced and not bounced_at then
			bounced_at = i
			T(projectile.rigid_body:GetVelocity().z)[">"](0)
		end
	end

	T(bounced_at ~= nil)["=="](true)
	T(projectile:IsValid())["=="](false)
end)
