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
			Friction = 0.85,
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

T.TestPhysics("a dropped citizen ragdoll lands on its joint limits softly instead of bouncing between them", function()
	local ground = create_ground()
	local spawned

	props.Spawn(
		"models/humans/group01/male_01.mdl",
		Vec3(0, 1.2, 0),
		Quat():Identity(),
		function(entity)
			spawned = entity
		end
	)

	T.WaitUntil(function()
		return spawned ~= nil and spawned.source_ragdoll.bodies[2] ~= nil
	end)

	local ragdoll = spawned.source_ragdoll
	local hits, impact, near, previous = 0, 0, {}, {}

	for _ = 1, 360 do
		physics.UpdateFixed(1 / 60)

		for i, joint in ipairs(ragdoll.joints) do
			local angle = joint:GetAngle()
			local at = angle < joint.LowerAngle + 0.02 or angle > joint.UpperAngle - 0.02

			if at and not near[i] then
				hits = hits + 1
				impact = impact + math.abs(angle - (previous[i] or angle)) * 60
			end

			near[i] = at
			previous[i] = angle
		end
	end

	T(hits)["<"](25)
	T(impact)["<"](100)
	spawned:Remove()
	ground:Remove()
end)

T.TestPhysics("limbs of a ragdoll collide with every body they are not jointed to", function()
	local ground = create_ground()
	local spawned

	props.Spawn(
		"models/humans/group01/male_01.mdl",
		Vec3(0, 1, 0),
		Quat():Identity(),
		function(entity)
			spawned = entity
		end
	)

	T.WaitUntil(function()
		return spawned ~= nil and spawned.source_ragdoll.bodies[2] ~= nil
	end)

	local ragdoll = spawned.source_ragdoll
	local jointed = {}

	for _, joint in ipairs(ragdoll.joints) do
		jointed[joint.Body0] = jointed[joint.Body0] or {}
		jointed[joint.Body0][joint.Body1] = true
	end

	local colliding = 0

	for i, a in ipairs(ragdoll.bodies) do
		for j = i + 1, #ragdoll.bodies do
			local b = ragdoll.bodies[j]

			if not (jointed[a] and jointed[a][b]) and not (jointed[b] and jointed[b][a]) then
				T(a:ShouldCollide(b))["=="](true)
				colliding = colliding + 1
			end
		end
	end

	T(colliding > 50)["=="](true)
	spawned:Remove()
	ground:Remove()
end)

T.TestPhysics("a ragdoll that has come to rest falls asleep instead of rocking on for ever", function()
	local ground = create_ground()
	local spawned

	props.Spawn(
		"models/humans/group01/male_01.mdl",
		Vec3(0, 0.6, 0),
		Quat():Identity(),
		function(entity)
			spawned = entity
		end
	)

	T.WaitUntil(function()
		return spawned ~= nil and spawned.source_ragdoll.bodies[2] ~= nil
	end)

	local ragdoll = spawned.source_ragdoll

	for _ = 1, 900 do
		physics.UpdateFixed(1 / 60)
	end

	for _, body in ipairs(ragdoll.bodies) do
		T(body.Awake)["=="](false)
	end

	local position = ragdoll.bodies[1].Position:Copy()

	for _ = 1, 120 do
		physics.UpdateFixed(1 / 60)
	end

	T(ragdoll.bodies[1].Position:Distance(position))["<"](0.001)
	ragdoll.bodies[3]:Wake()
	ragdoll.bodies[3]:SetVelocity(Vec3(0, 4, 0))

	for _ = 1, 30 do
		physics.UpdateFixed(1 / 60)
	end

	T(ragdoll.bodies[1].Awake)["=="](true)
	spawned:Remove()
	ground:Remove()
end)

T.TestPhysics("a ragdoll of a character model weighs what the standing character weighs and other ragdolls keep their file weights", function()
	local ground = create_ground()
	local CharacterMovement = import("lua/components/character_movement.lua")

	local function total(ragdoll)
		local sum = 0

		for _, body in ipairs(ragdoll.bodies) do
			sum = sum + body.Mass
		end

		return sum
	end

	local citizen

	props.Spawn(
		"models/humans/group01/female_01.mdl",
		Vec3(0, 1, 0),
		Quat():Identity(),
		function(entity)
			citizen = entity
		end
	)

	T.WaitUntil(function()
		return citizen ~= nil and citizen.source_ragdoll.bodies[2] ~= nil
	end)

	T(math.abs(total(citizen.source_ragdoll) - CharacterMovement.BodyMass))["<"](0.001)
	local gib = spawn(Vec3(3, 1, 0))
	local file_weight = 0

	for _, solid in ipairs(gib.source_ragdoll.ragdoll.solids) do
		file_weight = file_weight + solid.weight
	end

	T(math.abs(total(gib.source_ragdoll) - file_weight))["<"](0.001)
	citizen:Remove()
	gib:Remove()
	ground:Remove()
end)

T.TestPhysics("a ragdoll thrown along ordinary ground stops within a few meters and slides on slippery ground", function()
	local function slide(friction)
		local floor = Entity.New{
			transform = {Position = Vec3(0, -0.5, 0)},
			rigid_body = {
				MotionType = "static",
				Shape = BoxShape.New(Vec3(80, 1, 80)),
				Friction = friction,
				WorldGeometry = true,
			},
		}
		local spawned

		props.Spawn(
			"models/humans/group01/male_01.mdl",
			Vec3(0, 0.25, 0),
			Quat():Identity(),
			function(entity)
				spawned = entity
			end
		)

		T.WaitUntil(function()
			return spawned ~= nil and spawned.source_ragdoll.bodies[2] ~= nil
		end)

		local ragdoll = spawned.source_ragdoll

		for _ = 1, 90 do
			physics.UpdateFixed(1 / 60)
		end

		local start = ragdoll.bodies[1].Position:Copy()

		for _, body in ipairs(ragdoll.bodies) do
			body:Wake()
			body:SetVelocity(Vec3(5, 0, 0))
		end

		for _ = 1, 360 do
			physics.UpdateFixed(1 / 60)
		end

		local distance = ragdoll.bodies[1].Position.x - start.x
		spawned:Remove()
		floor:Remove()
		return distance
	end

	T(slide(0.85))["<"](4)
	T(slide(0.1))[">"](slide(0.85) * 2)
end)
