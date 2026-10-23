local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local prefab = import("goluwa/entities/prefab.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
import("addons/game/lua/autorun/characters.lua")
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
import("lua/weapons.lua")
local npcs = import("lua/npcs.lua")
local simulation_lod = import("lua/simulation_lod.lua")

local function create_box(position, size, world)
	return Entity.New{
		transform = {Position = position, Scale = size},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = world,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
end

local function create_ground(x1, z1, x2, z2)
	x1, z1, x2, z2 = x1 or -150, z1 or -150, x2 or 150, z2 or 150
	return create_box(Vec3((x1 + x2) / 2, -0.5, (z1 + z2) / 2), Vec3(x2 - x1, 1, z2 - z1), true)
end

local function create_npc(position, values)
	values = values or {}
	values.Wander = values.Wander or false
	values.WalkSpeed = values.WalkSpeed or 3
	local entity = Entity.New{
		ComponentSet = {"transform", "ai_controller"},
		transform = {Position = position:Copy()},
		ai_controller = values,
	}
	entity.ai_controller:Teleport(position, 0)
	return entity
end

local function run(seconds, until_done)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)

		if until_done and until_done() then return true end
	end

	return false
end

T.TestPhysics("npc has a body and walks around a wall to a goal", function()
	create_ground()
	create_box(Vec3(5, 1, 0), Vec3(0.4, 2, 8), true)
	local entity = create_npc(Vec3(1, 0.05, 0))
	local npc = entity.ai_controller
	T(entity.rigid_body ~= nil)["=="](true)
	T(entity.character_movement ~= nil)["=="](true)
	local arrived = 0

	entity:AddLocalListener("OnNPCArrived", function()
		arrived = arrived + 1
	end)

	run(1)
	local widest = 0
	npc:MoveTo(Vec3(9, 0, 0))
	run(1)
	T(npc:IsMoving())["=="](true)
	T(
		run(20, function()
			widest = math.max(widest, math.abs(entity.transform:GetPosition().z))
			return arrived > 0
		end)
	)["=="](true)
	local position = entity.transform:GetPosition()
	T(arrived)["=="](1)
	T(npc:IsMoving())["=="](false)
	T(math.abs(position.x - 9) < 0.6)["=="](true)
	T(math.abs(position.z) < 0.6)["=="](true)
	T(entity.rigid_body:GetGrounded())["=="](true)
	T(widest > 4)["=="](true)
end)

T.TestPhysics("npc goes around a rigid body that is not part of the world", function()
	create_ground()
	create_box(Vec3(5, 1, 0), Vec3(0.4, 2, 8), false)
	local entity = create_npc(Vec3(1, 0.05, 0))
	local arrived = false
	local widest = 0

	entity:AddLocalListener("OnNPCArrived", function()
		arrived = true
	end)

	run(1)
	entity.ai_controller:MoveTo(Vec3(9, 0, 0))
	T(
		run(20, function()
			widest = math.max(widest, math.abs(entity.transform:GetPosition().z))
			return arrived
		end)
	)["=="](true)
	T(widest > 4)["=="](true)
end)

T.TestPhysics("npc paths ignore the hitboxes and bodies of characters but not other bodies", function()
	create_ground()
	local nav = import("goluwa/navigation/grid_nav.lua").Get(0.3, 1.4, 0.35, 1.2)
	local entity = create_npc(Vec3(0, 0.05, 0))
	run(1)
	local count = #nav:CollectObstacles()
	Entity.New{
		transform = {Position = Vec3(5, 1, 0), Scale = Vec3(1, 2, 1)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
		ragdoll_part = {},
	}
	T(#nav:CollectObstacles())["=="](count)
	Entity.New{
		transform = {Position = Vec3(8, 1, 0), Scale = Vec3(1, 2, 1)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	T(#nav:CollectObstacles())["=="](count + 1)
end)

T.TestPhysics("npc turns to face where it walks", function()
	create_ground()
	local entity = create_npc(Vec3(0, 0.05, 0))
	run(1)
	entity.ai_controller:MoveTo(Vec3(10, 0, 0))
	run(3)
	local forward = entity.transform:GetRotation():GetForward()
	T(forward.x > 0.9)["=="](true)
	T(math.abs(forward.z) < 0.2)["=="](true)
	T(entity.transform:GetPosition().x > 3)["=="](true)
end)

T.TestPhysics("npc reports a goal it cannot reach", function()
	create_ground(0, 0, 10, 10)
	create_ground(20, 0, 30, 10)
	local entity = create_npc(Vec3(2, 0.05, 2))
	local failed = 0

	entity:AddLocalListener("OnNPCPathFailed", function()
		failed = failed + 1
	end)

	run(1)
	entity.ai_controller:MoveTo(Vec3(25, 0, 5))
	run(2)
	T(failed)["=="](1)
	T(entity.ai_controller:IsMoving())["=="](false)
	entity.ai_controller:MoveTo(Vec3(80, 0, 5))
	run(2)
	T(failed)["=="](2)
end)

T.TestPhysics("npc blocks the cells it got stuck in and plans around them", function()
	create_ground()
	local entity = create_npc(Vec3(0, 0.05, 0))
	local npc = entity.ai_controller
	run(1)
	npc:MoveTo(Vec3(8, 0, 0))
	npc.dir_x, npc.dir_z = 1, 0
	npc:OnStuck(entity.transform:GetPosition())
	T(next(npc.blocked) ~= nil)["=="](true)
	T(npc.path)["=="](nil)
end)

T.TestPhysics("npc wanders to places it can walk to", function()
	create_ground(-15, -15, 15, 15)
	local entity = create_npc(
		Vec3(0, 0.05, 0),
		{Wander = true, WanderMinDelay = 0, WanderMaxDelay = 0.1, WanderRadius = 20}
	)
	local goals = 0
	T(
		run(30, function()
			local goal = entity.ai_controller:GetGoal()

			if goal then
				goals = goals + 1
				T(math.abs(goal.x) <= 15)["=="](true)
				T(math.abs(goal.z) <= 15)["=="](true)
			end

			return goals > 0 and entity.transform:GetPosition():Distance(Vec3(0, 0, 0)) > 3
		end)
	)["=="](true)
end)

T.TestPhysics("npc far from every camera follows the ground and gets a body back when one comes near", function()
	create_ground(20, 20, 80, 80)
	local camera = render3d.GetCamera()
	local camera_position = camera:GetPosition():Copy()
	camera:SetPosition(Vec3(0, 1, 0))
	local entity = create_npc(Vec3(40, 0.05, 40))
	local npc = entity.ai_controller
	run(1)
	T(npc:IsSimulated())["=="](false)
	T(entity.character_movement.mode)["=="]("fly")
	local arrived = false

	entity:AddLocalListener("OnNPCArrived", function()
		arrived = true
	end)

	npc:MoveTo(Vec3(60, 0, 40))
	T(run(15, function()
		return arrived
	end))["=="](true)
	local position = entity.transform:GetPosition()
	T(math.abs(position.x - 60) < 0.6)["=="](true)
	T(math.abs(position.y) < 0.05)["=="](true)
	camera:SetPosition(Vec3(58, 1, 40))
	run(1)
	T(npc:IsSimulated())["=="](true)
	T(entity.character_movement.mode)["=="]("walk")
	T(run(3, function()
		return entity.rigid_body:GetGrounded()
	end))["=="](true)
	camera:SetPosition(camera_position)
end)

T.TestPhysics("npc keeps the bodies of the nearest ones up to the budget", function()
	create_ground()
	local camera = render3d.GetCamera()
	local camera_position = camera:GetPosition():Copy()
	camera:SetPosition(Vec3(0, 1, 0))
	local budget = simulation_lod.MaxSimulated
	simulation_lod.MaxSimulated = 2
	local npcs_near = {}

	for i = 1, 4 do
		npcs_near[i] = create_npc(Vec3(i * 2, 0.05, 0))
	end

	run(1)
	T(npcs_near[1].ai_controller:IsSimulated())["=="](true)
	T(npcs_near[2].ai_controller:IsSimulated())["=="](true)
	T(npcs_near[3].ai_controller:IsSimulated())["=="](false)
	T(npcs_near[4].ai_controller:IsSimulated())["=="](false)
	simulation_lod.MaxSimulated = budget
	camera:SetPosition(camera_position)
end)

T.Test3D("npc prefabs are built in and push their inputs into the npc", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/zombie/classic.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	for name in pairs(npcs.Definitions) do
		local definition = prefab.definitions[npcs.GetPrefabName(name)]
		T(definition ~= nil)["=="](true)
		T(definition.builtin)["=="](true)
	end

	local instance = Entity.New{prefab = {Path = npcs.GetPrefabName("zombie")}, transform = {}}
	local npc = instance.ai_controller
	T(npc ~= nil)["=="](true)
	T(npc.Faction)["=="]("enemy")
	T(instance.source_pose.WalkSequence)["=="]("walk")
	T(instance.model.ModelPath)["=="]("models/zombie/classic.mdl")
	T(math.abs(npc.WalkSpeed - 45 * UNIT) < 1e-6)["=="](true)
	T(npc:HasAuthority())["=="](true)
	T(instance.character_movement ~= nil)["=="](true)
	instance.prefab:SetInput("WalkSpeed", 2)
	instance.prefab:SetInput("Wander", false)
	T(npc.WalkSpeed)["=="](2)
	T(npc.Wander)["=="](false)
	T(instance.weapon_holder == nil)["=="](true)
	instance:Remove()
	local armed = npcs.Spawn("barney", Vec3(0, 0.05, 0), 0)
	T(armed.weapon_holder:GetActiveWeapon().weapon:GetDisplayName())["=="]("Pistol")
	T(armed.ai_controller.Faction)["=="]("friend")
	armed:Remove()
end)

T.Test3D("npc speeds are the ground speeds of the sequences they play", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/zombie/classic.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	for name, info in pairs(npcs.Definitions) do
		if not info.Model then goto continue end

		local skeleton

		model_loader.LoadModel(info.Model, function(data)
			skeleton = data.skeleton
		end)

		T.WaitUntil(function()
			return skeleton ~= nil
		end, 30)

		T(skeleton ~= nil)["=="](true)
		local params = {move_yaw = 0}

		for _, sequence in ipairs{info.Idle, info.Walk, info.Run} do
			T(skeleton.ClipsByName[sequence] ~= nil)["=="](true)
		end

		T(skeleton.ClipsByName[info.Idle]:GetGroundSpeed(params))["=="](0)

		for sequence, speed in pairs{[info.Walk] = info.WalkSpeed, [info.Run] = info.RunSpeed} do
			local ground_speed = skeleton.ClipsByName[sequence]:GetGroundSpeed(params) / UNIT
			T(math.abs(ground_speed - speed) / speed < 0.03)["=="](true)
		end

		::continue::
	end
end)
