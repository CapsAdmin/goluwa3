local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local steam = import("goluwa/steam/steam.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local props = import("lua/props.lua")
steam.MountSourceGame("gmod")
local GIB = "models/props_junk/cardboard_box002a_gib01.mdl"

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0)},
		rigid_body = {
			MotionType = "static",
			Shape = BoxShape.New(Vec3(40, 1, 40)),
			Friction = 0.8,
			WorldGeometry = true,
		},
	}
end

local function spawn(position)
	local spawned

	props.Spawn(GIB, position, Quat():Identity(), function(entity)
		spawned = entity
	end)

	T.WaitUntil(function()
		return spawned ~= nil and spawned.source_ragdoll.bodies[6] ~= nil
	end)

	return spawned
end

T.TestPhysics("a ragdoll model spawns one body per physics bone joined by hinges", function()
	local ground = create_ground()
	local entity = spawn(Vec3(0, 0, 0))
	local ragdoll = entity.source_ragdoll
	T(#ragdoll.bodies)["=="](6)
	T(#ragdoll.joints)["=="](5)

	for _ = 1, 120 do
		physics.UpdateFixed(1 / 60)
	end

	for _, body in ipairs(ragdoll.bodies) do
		T(body.Position.y)[">"](-0.05)
		T(body.Position.y)["<"](0.8)
	end

	entity:Remove()
	ground:Remove()
end)

T.TestPhysics("removing a ragdoll removes its limb bodies and joints", function()
	local ground = create_ground()
	local entity = spawn(Vec3(0, 0, 0))
	local limbs = {}

	for i = 2, 6 do
		limbs[#limbs + 1] = entity.source_ragdoll.bodies[i].Owner
	end

	entity:Remove()

	for _, limb in ipairs(limbs) do
		T(limb:IsValid())["=="](false)
	end

	ground:Remove()
end)

T.TestPhysics("a dropped ragdoll box folds its flaps open and the limbs stay joined", function()
	local ground = create_ground()
	local entity = spawn(Vec3(0, 1.5, 0))
	local ragdoll = entity.source_ragdoll

	for _ = 1, 240 do
		physics.UpdateFixed(1 / 60)
	end

	local root = ragdoll.bodies[1].Position

	for i = 2, 6 do
		T(ragdoll.bodies[i].Position:Distance(root))["<"](1.2)
	end

	entity:Remove()
	ground:Remove()
end)

T.TestPhysics("the ragdoll rig bones sit on their bodies at a rotated spawn", function()
	local ground = create_ground()
	local spawned

	props.Spawn(
		GIB,
		Vec3(2, 0, 1),
		Quat():SetAngles(Deg3(0, 40, 0)),
		function(entity)
			spawned = entity
		end
	)

	T.WaitUntil(function()
		return spawned ~= nil and
			spawned.source_ragdoll.bodies[6] ~= nil and
			spawned.source_ragdoll:GetRig() ~= nil
	end)

	local ragdoll = spawned.source_ragdoll

	for _ = 1, 30 do
		physics.UpdateFixed(1 / 60)
		ragdoll:OnUpdate()
	end

	local matrix = ragdoll:GetVisual().transform:GetWorldMatrix()
	local rig = ragdoll:GetRig()

	for i, solid in ipairs(ragdoll.ragdoll.solids) do
		local bone = matrix:TransformVector(Vec3(rig:GetBonePosition(solid.bone)))
		local body = ragdoll.bodies[i]
		T(bone:Distance(body.Position - body.Rotation:VecMul(solid.mass_center)))["<"](0.02)
	end

	spawned:Remove()
	ground:Remove()
end)

T.TestPhysics("a model without collision data spawns with a box collider around its visual", function()
	local ground = create_ground()
	local spawned

	props.Spawn(
		"models/Advisor.mdl",
		Vec3(0, 0, 0),
		Quat():Identity(),
		function(entity)
			spawned = entity
		end
	)

	T.WaitUntil(function()
		return spawned ~= nil
	end)

	local body = spawned.rigid_body
	T(body:GetShapeType())["=="]("box")
	T(body:GetMass())[">"](1)

	for _ = 1, 120 do
		physics.UpdateFixed(1 / 60)
	end

	T(body:IsDynamic())["=="](true)
	T(body.Position.y)[">"](0.2)
	spawned:Remove()
	ground:Remove()
end)
