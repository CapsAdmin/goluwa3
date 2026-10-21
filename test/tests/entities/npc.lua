local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local prefab = import("goluwa/entities/prefab.lua")
local navmesh = import("goluwa/navigation/navmesh.lua")
local nav_mesh = import("goluwa/entities/components/nav_mesh.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("locomotion", import("lua/components/locomotion.lua"))
local npcs = import("lua/npcs.lua")
local simulation_lod = import("lua/simulation_lod.lua")

local function rectangle(mesh, id, x1, z1, x2, z2)
	return mesh:AddArea{
		Id = id,
		Polygon = {Vec3(x1, 0, z1), Vec3(x2, 0, z1), Vec3(x2, 0, z2), Vec3(x1, 0, z2)},
	}
end

local function join(mesh, a, b, p, q)
	mesh:Connect(a, b, p, q)
	mesh:Connect(b, a, p, q)
end

local function create_mesh_entity(mesh)
	local entity = Entity.New{Name = "nav", transform = {}, nav_mesh = {}}
	entity.nav_mesh:SetMesh(mesh)
	return entity
end

local function create_bend()
	local mesh = navmesh.New()
	local a = rectangle(mesh, 1, 0, 0, 10, 3)
	local b = rectangle(mesh, 2, 7, 3, 10, 13)
	join(mesh, a, b, Vec3(7, 0, 3), Vec3(10, 0, 3))
	return mesh
end

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(300, 1, 300)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
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

T.TestPhysics("npc has a body and walks the path to a goal around a bend", function()
	create_ground()
	create_mesh_entity(create_bend())
	local entity = create_npc(Vec3(1, 0.05, 1))
	local npc = entity.ai_controller
	T(entity.rigid_body ~= nil)["=="](true)
	T(entity.character_movement ~= nil)["=="](true)
	local arrived = 0

	entity:AddLocalListener("OnNPCArrived", function()
		arrived = arrived + 1
	end)

	run(1)
	local corner_distance = math.huge
	npc:MoveTo(Vec3(8.5, 0, 12))
	run(1)
	T(npc:IsMoving())["=="](true)
	T(npc:GetPath() ~= nil)["=="](true)
	T(
		run(15, function()
			local position = entity.transform:GetPosition()
			corner_distance = math.min(corner_distance, position:Distance(Vec3(7, position.y, 3)))
			return arrived > 0
		end)
	)["=="](true)
	local position = entity.transform:GetPosition()
	T(arrived)["=="](1)
	T(npc:IsMoving())["=="](false)
	T(math.abs(position.x - 8.5) < 0.6)["=="](true)
	T(math.abs(position.z - 12) < 0.6)["=="](true)
	T(entity.rigid_body:GetGrounded())["=="](true)
	T(position.x > 6.5)["=="](true)
end)

T.TestPhysics("npc turns to face where it walks", function()
	create_ground()
	local mesh = navmesh.New()
	rectangle(mesh, 1, -20, -20, 20, 20)
	create_mesh_entity(mesh)
	local entity = create_npc(Vec3(0, 0.05, 0))
	entity.ai_controller:MoveTo(Vec3(10, 0, 0))
	run(3)
	local forward = entity.transform:GetRotation():GetForward()
	T(forward.x > 0.9)["=="](true)
	T(math.abs(forward.z) < 0.2)["=="](true)
	T(entity.transform:GetPosition().x > 3)["=="](true)
end)

T.TestPhysics("npc reports a goal it cannot reach", function()
	create_ground()
	local mesh = navmesh.New()
	rectangle(mesh, 1, 0, 0, 10, 10)
	rectangle(mesh, 2, 20, 0, 30, 10)
	create_mesh_entity(mesh)
	local entity = create_npc(Vec3(2, 0.05, 2))
	local failed = 0

	entity:AddLocalListener("OnNPCPathFailed", function()
		failed = failed + 1
	end)

	entity.ai_controller:MoveTo(Vec3(25, 0, 5))
	run(1)
	T(failed)["=="](1)
	T(entity.ai_controller:IsMoving())["=="](false)
	entity.ai_controller:MoveTo(Vec3(80, 0, 5))
	run(1)
	T(failed)["=="](2)
end)

T.TestPhysics("npc goes around an area it cannot get through", function()
	create_ground()
	local mesh = navmesh.New()
	local start = rectangle(mesh, 1, 0, 0, 4, 4)
	local north = rectangle(mesh, 2, 4, 0, 8, 4)
	local goal = rectangle(mesh, 3, 8, 0, 12, 4)
	local south_a = rectangle(mesh, 4, 0, 4, 4, 14)
	local south_b = rectangle(mesh, 5, 4, 10, 8, 14)
	local south_c = rectangle(mesh, 6, 8, 4, 12, 14)
	join(mesh, start, north, Vec3(4, 0, 0), Vec3(4, 0, 4))
	join(mesh, north, goal, Vec3(8, 0, 0), Vec3(8, 0, 4))
	join(mesh, start, south_a, Vec3(0, 0, 4), Vec3(4, 0, 4))
	join(mesh, south_a, south_b, Vec3(4, 0, 10), Vec3(4, 0, 14))
	join(mesh, south_b, south_c, Vec3(8, 0, 10), Vec3(8, 0, 14))
	join(mesh, south_c, goal, Vec3(8, 0, 4), Vec3(12, 0, 4))
	create_mesh_entity(mesh)
	Entity.New{
		transform = {Position = Vec3(6, 1, 2), Scale = Vec3(0.4, 2, 6)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local entity = create_npc(Vec3(2, 0.05, 2))
	local arrived = false

	entity:AddLocalListener("OnNPCArrived", function()
		arrived = true
	end)

	entity.ai_controller:MoveTo(Vec3(10, 0, 2))
	T(run(40, function()
		return arrived
	end))["=="](true)
	T(next(entity.ai_controller.blocked) ~= nil)["=="](true)
	T(math.abs(entity.transform:GetPosition().x - 10) < 0.6)["=="](true)
end)

T.TestPhysics("npc wanders to places on the mesh it can walk to", function()
	create_ground()
	local mesh = navmesh.New()
	rectangle(mesh, 1, -15, -15, 15, 15)
	rectangle(mesh, 2, 40, 40, 50, 50)
	create_mesh_entity(mesh)
	local entity = create_npc(
		Vec3(0, 0.05, 0),
		{Wander = true, WanderMinDelay = 0, WanderMaxDelay = 0.1, WanderRadius = 20}
	)
	local goals = 0
	T(
		run(30, function()
			if entity.ai_controller:GetGoal() then
				goals = goals + 1
				T(math.abs(entity.ai_controller:GetGoal().x) <= 15)["=="](true)
				T(math.abs(entity.ai_controller:GetGoal().z) <= 15)["=="](true)
			end

			return goals > 0 and entity.transform:GetPosition():Distance(Vec3(0, 0, 0)) > 3
		end)
	)["=="](true)
end)

T.TestPhysics("npc that is off the mesh for a while is put back on it", function()
	create_ground()
	local mesh = navmesh.New()
	rectangle(mesh, 1, 0, 0, 10, 10)
	create_mesh_entity(mesh)
	local entity = create_npc(Vec3(5, 0.05, 5))
	entity.ai_controller:Teleport(Vec3(30, 0.05, 5), 0)
	T(mesh:GetAreaAt(entity.transform:GetPosition(), 2))["=="](nil)
	T(
		run(10, function()
			return mesh:GetAreaAt(entity.transform:GetPosition(), 2) ~= nil
		end)
	)["=="](true)
end)

T.TestPhysics("npc far from every camera follows the mesh and gets a body back when one comes near", function()
	create_ground()
	local mesh = navmesh.New()
	rectangle(mesh, 1, 20, 20, 80, 80)
	create_mesh_entity(mesh)
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
	local mesh = navmesh.New()
	rectangle(mesh, 1, -50, -50, 50, 50)
	create_mesh_entity(mesh)
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
	T(instance.locomotion.WalkSequence)["=="]("walk")
	T(instance.model.ModelPath)["=="]("models/zombie/classic.mdl")
	T(math.abs(npc.WalkSpeed - 45 * UNIT) < 1e-6)["=="](true)
	T(npc:HasAuthority())["=="](true)
	T(instance.character_movement ~= nil)["=="](true)
	instance.prefab:SetInput("WalkSpeed", 2)
	instance.prefab:SetInput("Wander", false)
	T(npc.WalkSpeed)["=="](2)
	T(npc.Wander)["=="](false)
	instance:Remove()
end)

T.Test3D("npc speeds are the ground speeds of the sequences they play", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/zombie/classic.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	for name, info in pairs(npcs.Definitions) do
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
	end
end)
