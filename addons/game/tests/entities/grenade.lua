local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local weapons = import("lua/weapons.lua")
import("lua/damage.lua")
Entity.RegisterComponent("grenade", import("lua/components/grenade.lua"))

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
end

local function create_victim(position)
	return Entity.New{
		ComponentSet = {"transform", "health"},
		transform = {Position = position},
		health = {Health = 100, MaxHealth = 100},
	}
end

local function create_grenade(position, fields)
	return Entity.New{
		transform = {Position = position},
		rigid_body = {
			Shape = SphereShape.New(0.06),
			Mass = 0.4,
			AutomaticMass = false,
			CanSleep = false,
		},
		grenade = fields,
	}
end

T.TestPhysics("a grenade is a registered weapon", function()
	T(weapons.Definitions.weapon_grenade ~= nil)["=="](true)
end)

T.TestPhysics("a grenade explodes after its fuse, hurting by distance and pushing props", function()
	create_ground()
	local near = create_victim(Vec3(2, 0, 0))
	local far = create_victim(Vec3(5, 0, 0))
	local outside = create_victim(Vec3(12, 0, 0))
	local prop = Entity.New{
		transform = {Position = Vec3(0, 1.5, 3)},
		rigid_body = {Shape = SphereShape.New(0.3), Mass = 1, AutomaticMass = false, CanSleep = false},
	}
	local grenade = create_grenade(Vec3(0, 0.06, 0), {Damage = 100, Radius = 6, Fuse = 1})
	grenade.rigid_body:SetVelocity(Vec3())
	local component = grenade.grenade

	for _ = 1, 50 do
		physics.UpdateFixed(1 / 60)
		component:OnUpdate(1 / 60)
	end

	T(grenade:IsValid())["=="](true)
	T(near.health.Health)["=="](100)

	for _ = 1, 20 do
		physics.UpdateFixed(1 / 60)

		if grenade:IsValid() then component:OnUpdate(1 / 60) end
	end

	T(grenade:IsValid())["=="](false)
	T(near.health.Health < far.health.Health)["=="](true)
	T(far.health.Health < 100)["=="](true)
	T(outside.health.Health)["=="](100)
	T(prop.rigid_body:GetVelocity().z > 0.5)["=="](true)
end)

T.TestPhysics("cover reduces grenade damage", function()
	create_ground()
	local open = create_victim(Vec3(-3, 1, 0))
	local covered = create_victim(Vec3(3, 1, 0))
	Entity.New{
		transform = {Position = Vec3(1.5, 1, 0), Scale = Vec3(0.2, 2, 4)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local grenade = create_grenade(Vec3(0, 0.06, 0), {Damage = 100, Radius = 6, Fuse = 0.1})
	physics.UpdateFixed(1 / 60)
	grenade.grenade:Explode()
	T(100 - covered.health.Health < (100 - open.health.Health) * 0.6)["=="](true)
end)
