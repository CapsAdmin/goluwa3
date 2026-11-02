local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local steam = import("goluwa/steam/steam.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local damage = import("lua/damage.lua")
local props = import("lua/props.lua")
local prop_data = import("goluwa/source_engine/prop_data.lua")
Entity.RegisterComponent("breakable", import("lua/components/breakable.lua"))
Entity.RegisterComponent("fade_out", import("lua/components/fade_out.lua"))
steam.MountSourceGame("gmod")
local CRATE = "models/props_junk/wood_crate001a.mdl"

T.Test("prop data reads breakability, gibs and sounds from the model", function()
	steam.MountSourceGame("gmod")
	local crate = prop_data.Get(CRATE)
	T(crate.Health)["=="](30)
	T(#crate.Gibs)["=="](7)
	T(#crate.Sounds.Waves)[">"](0)
	local barrel = prop_data.Get("models/props_c17/oildrum001.mdl")
	T(barrel == nil)["=="](true)
	local scattered = prop_data.Get("models/props_c17/furniturearmchair001a.mdl")
	T(#scattered.Gibs)["=="](0)
	T(#scattered.Chunks)[">"](0)
end)

T.TestPhysics("a wood crate is breakable and falls apart into its chunks when its health runs out", function()
	local ground = Entity.New{
		transform = {Position = Vec3(0, -0.5, 0)},
		rigid_body = {
			MotionType = "static",
			Shape = BoxShape.New(Vec3(40, 1, 40)),
			WorldGeometry = true,
		},
	}
	local crate

	props.Spawn(CRATE, Vec3(0, 0, 0), Quat():Identity(), function(entity)
		crate = entity
	end)

	T.WaitUntil(function()
		return crate ~= nil
	end)

	T(crate.health.MaxHealth)["=="](prop_data.Get(CRATE).Health)
	damage.Deal(crate, {Damage = 10, Type = "slash", Direction = Vec3(1, 0, 0)})
	T(crate:IsValid())["=="](true)
	damage.Deal(crate, {Damage = 100, Type = "slash", Direction = Vec3(1, 0, 0)})
	T(crate:IsValid())["=="](false)

	T.WaitUntil(function()
		return #RigidBody.Instances >= 1 + #prop_data.Get(CRATE).Gibs
	end)

	for _ = 1, 60 do
		physics.UpdateFixed(1 / 60)
	end

	T.WaitUntil(function()
		return #RigidBody.Instances == 1
	end, 12)

	ground:Remove()
end)

T.TestPhysics("a wood crate thrown hard into the ground breaks while a gentle landing leaves it whole", function()
	local ground = Entity.New{
		transform = {Position = Vec3(0, -0.5, 0)},
		rigid_body = {
			MotionType = "static",
			Shape = BoxShape.New(Vec3(40, 1, 40)),
			WorldGeometry = true,
		},
	}
	local gentle, hard

	props.Spawn(CRATE, Vec3(-3, 0, 0), Quat():Identity(), function(entity)
		gentle = entity
	end)

	props.Spawn(CRATE, Vec3(3, 0, 0), Quat():Identity(), function(entity)
		hard = entity
	end)

	T.WaitUntil(function()
		return gentle ~= nil and hard ~= nil
	end)

	hard.rigid_body:SetVelocity(Vec3(0, -12, 0))

	for _ = 1, 120 do
		physics.UpdateFixed(1 / 60)
	end

	T(hard:IsValid())["=="](false)
	T(gentle:IsValid())["=="](true)
	T(gentle.health:GetFraction())["=="](1)
	gentle:Remove()
	ground:Remove()
end)
