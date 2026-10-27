local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local physics = import("goluwa/physics.lua")
local BUTTON = usercmd.BUTTON
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
import("lua/weapons.lua")
import("addons/game/lua/autorun/characters.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(200, 1, 200)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
end

local function create_player(position, buffer_target)
	local player = Entity.New{
		ComponentSet = {"transform", "player_controller", "character_movement"},
		transform = {Position = position or Vec3(0, 3, 0)},
		player_controller = {Source = "queue"},
	}
	player.player_controller.buffer_target = buffer_target or 1
	return player
end

local function make_command(number, setup)
	local cmd = usercmd.New()
	cmd.number = number
	cmd.mode = "walk"
	cmd.buttons = BUTTON.ACTIVE

	if setup then setup(cmd) end

	return cmd
end

local function drive(player, ticks, setup, first)
	local controller = player.player_controller
	local number = first or controller.last_queued

	for _ = 1, ticks do
		number = number + 1
		controller:PushCommands({make_command(number, setup)})
		physics.UpdateFixed(1 / 60)
	end
end

T.TestPhysics("player controller buffers commands before consuming them", function()
	local player = create_player(nil, 6)
	local controller = player.player_controller
	local start = controller.buffer_target

	for number = 1, start - 1 do
		controller:PushCommands({make_command(number)})
	end

	local cmd = controller:NextCommand(1 / 60)
	T(controller.number)["=="](0)
	T(controller:GetQueueSize())["=="](start - 1)
	controller:PushCommands({make_command(start)})
	cmd = controller:NextCommand(1 / 60)
	T(cmd.number)["=="](1)
	T(controller.number)["=="](1)
	cmd = controller:NextCommand(1 / 60)
	T(cmd.number)["=="](2)
end)

T.TestPhysics("player controller ignores old and duplicate commands", function()
	local player = create_player()
	local controller = player.player_controller
	controller:PushCommands{make_command(5), make_command(6)}
	controller:PushCommands{make_command(5), make_command(6), make_command(7)}
	T(controller:GetQueueSize())["=="](3)
end)

T.TestPhysics("player controller computes pressed edges from consecutive commands", function()
	local player = create_player(nil, 6)
	local controller = player.player_controller
	local commands = {}

	for number = 1, controller.buffer_target + 1 do
		commands[number] = make_command(number, function(cmd)
			if number >= 3 and number <= 5 then
				cmd.buttons = bit.bor(cmd.buttons, BUTTON.JUMP)
			end
		end)
	end

	controller:PushCommands(commands)
	local pressed = {}

	for number = 1, 6 do
		pressed[number] = usercmd.WasPressed(controller:NextCommand(1 / 60), BUTTON.JUMP)
	end

	T(pressed[2])["=="](false)
	T(pressed[3])["=="](true)
	T(pressed[4])["=="](false)
	T(pressed[5])["=="](false)
	T(pressed[6])["=="](false)
end)

T.TestPhysics("player controller repeats the last command when starved then stops moving", function()
	local player = create_player(nil, 6)
	local controller = player.player_controller
	local commands = {}

	for number = 1, controller.buffer_target do
		commands[number] = make_command(number, function(cmd)
			cmd.forward = 1
		end)
	end

	controller:PushCommands(commands)

	for _ = 1, controller.buffer_target do
		controller:NextCommand(1 / 60)
	end

	local consumed = controller.number
	local repeated = controller:NextCommand(1 / 60)
	T(repeated.forward)["=="](1)
	T(repeated.number)["=="](consumed)
	T(controller.number)["=="](consumed)
	T(controller.buffering)["=="](true)

	for _ = 1, 20 do
		repeated = controller:NextCommand(1 / 60)
	end

	T(repeated.forward)["=="](0)
end)

T.TestPhysics("player controller drops commands from a runaway backlog", function()
	local player = create_player(nil, 6)
	local controller = player.player_controller
	local commands = {}

	for number = 1, 200 do
		commands[number] = make_command(number)
	end

	controller:PushCommands(commands)
	local cmd = controller:NextCommand(1 / 60)
	T(cmd.number)[">"](150)
end)

local function settle(player)
	drive(player, 90)
	player.player_controller.buffer_target = 2
end

T.TestPhysics("player controller drains a surplus of idle commands while at rest", function()
	local ground = create_ground()
	local player = create_player(Vec3(0, 1, 0))
	local controller = player.player_controller
	settle(player)
	local number = controller.last_queued
	local commands = {}

	for i = 1, 12 do
		commands[i] = make_command(number + i)
	end

	controller:PushCommands(commands)

	for _ = 1, 8 do
		physics.UpdateFixed(1 / 60)
	end

	T(controller:GetQueueSize())["<="](controller.buffer_target + 2)
	T(controller.skipped)[">="](4)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player controller drains a surplus of moving commands slowly", function()
	local ground = create_ground()
	local player = create_player(Vec3(0, 1, 0))
	local controller = player.player_controller
	settle(player)
	local forward = function(cmd)
		cmd.forward = 1
	end
	local number = controller.last_queued
	local commands = {}

	for i = 1, 12 do
		commands[i] = make_command(number + i, forward)
	end

	controller:PushCommands(commands)
	drive(player, 59, forward)
	T(controller.skipped)["=="](1)
	T(controller:GetQueueSize())["=="](11)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player controller lowers its buffer target to the slack it does not need", function()
	local ground = create_ground()
	local player = create_player(Vec3(0, 1, 0))
	local controller = player.player_controller
	settle(player)
	controller.buffer_target = 10
	local number = controller.last_queued
	local commands = {}

	for i = 1, 8 do
		commands[i] = make_command(number + i)
	end

	controller:PushCommands(commands)
	drive(player, 240)
	T(controller.buffer_target)["<"](10)
	T(controller:GetQueueSize())["<="](controller.buffer_target + 1)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player controller never skips a button change while draining", function()
	local ground = create_ground()
	local player = create_player(Vec3(0, 1, 0))
	local controller = player.player_controller
	settle(player)
	local number = controller.last_queued
	local commands = {}

	for i = 1, 12 do
		commands[i] = make_command(number + i, function(cmd)
			if i % 2 == 1 then cmd.buttons = bit.bor(cmd.buttons, BUTTON.USE) end
		end)
	end

	controller:PushCommands(commands)
	local presses = 0

	for _ = 1, 12 do
		local cmd = controller:NextCommand(1 / 60)

		if usercmd.WasPressed(cmd, BUTTON.USE) then presses = presses + 1 end
	end

	T(controller.skipped)["=="](0)
	T(presses)["=="](6)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player movement lands on the ground, walks and jumps", function()
	local ground = create_ground()
	local player = create_player()
	drive(player, 120)
	local body = player.rigid_body
	T(body:GetGrounded())["=="](true)
	T(math.abs(body:GetPosition().y - 0.6858))["<"](0.01)
	local start = body:GetPosition():Copy()

	drive(player, 60, function(cmd)
		cmd.forward = 1
	end)

	T((body:GetPosition() - start):GetLength())[">"](2)
	local height = body:GetPosition().y

	drive(player, 6, function(cmd)
		cmd.forward = 1
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.JUMP)
	end)

	T(body:GetPosition().y)[">"](height + 0.2)
	ground:Remove()
end)

T.TestPhysics("player origin is at the feet and the eye is above it", function()
	local ground = create_ground()
	local player = create_player()
	drive(player, 120)
	local body = player.rigid_body
	local movement = player.character_movement
	T(body:GetGrounded())["=="](true)
	T(math.abs(player.transform:GetPosition().y))["<"](0.01)
	T(math.abs(body:GetPosition().y - player.transform:GetPosition().y - 0.6858))["<"](0.001)
	T(math.abs(movement:GetViewOffset().y - 1.2192))["<"](0.001)

	drive(player, 40, function(cmd)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.CROUCH)
	end)

	T(math.abs(player.transform:GetPosition().y))["<"](0.01)
	T(math.abs(movement:GetViewOffset().y - 0.5334))["<"](0.001)
	T(math.abs(body:GetPosition().y - player.transform:GetPosition().y - 0.3429))["<"](0.001)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player cannot stand up under a ceiling lower than its height", function()
	local ground = create_ground()
	local player = create_player()
	local movement = player.character_movement
	drive(player, 120)

	drive(player, 30, function(cmd)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.CROUCH)
	end)

	T(movement:IsCrouching())["=="](true)
	local ceiling = Entity.New{
		transform = {Position = Vec3(0, 1.0 + 0.5, 0), Scale = Vec3(10, 1, 10)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	drive(player, 40)
	T(movement:IsCrouching())["=="](true)
	T(math.abs(movement:GetViewOffset().y - 0.5334))["<"](0.001)
	T(player.rigid_body:GetPosition().y + 0.3429)["<"](1.0)
	ceiling:Remove()
	drive(player, 40)
	T(movement:IsCrouching())["=="](false)
	T(math.abs(movement:GetViewOffset().y - 1.2192))["<"](0.001)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player stands up under a ceiling that leaves room", function()
	local ground = create_ground()
	local player = create_player()
	local movement = player.character_movement
	drive(player, 120)

	drive(player, 30, function(cmd)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.CROUCH)
	end)

	local ceiling = Entity.New{
		transform = {Position = Vec3(0, 1.6 + 0.5, 0), Scale = Vec3(10, 1, 10)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	drive(player, 40)
	T(movement:IsCrouching())["=="](false)
	player:Remove()
	ceiling:Remove()
	ground:Remove()
end)

T.TestPhysics("player rides a moving platform and keeps its momentum when jumping off", function()
	local ground = create_ground()
	local platform = Entity.New{
		transform = {Position = Vec3(0, 0.25, 0), Scale = Vec3(6, 0.5, 6)},
		rigid_body = {MotionType = "kinematic", Shape = BoxShape.New(Vec3(1, 1, 1)), Friction = 1},
	}
	local player = create_player(Vec3(0, 0.6, 0))
	local x = 0

	local function step(ticks, setup)
		for _ = 1, ticks do
			x = x + 2 / 60
			platform.transform:SetPosition(Vec3(x, 0.25, 0))
			drive(player, 1, setup)
		end
	end

	step(120)
	T(player.rigid_body:GetGrounded())["=="](true)
	T(math.abs(player.rigid_body:GetPosition().x - x))["<"](0.3)
	local offset = player.rigid_body:GetPosition().x - x
	step(60)
	T(math.abs(player.rigid_body:GetPosition().x - x - offset))["<"](0.15)

	step(6, function(cmd)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.JUMP)
	end)

	T(player.rigid_body:GetVelocity().x)[">"](1.5)
	player:Remove()
	platform:Remove()
	ground:Remove()
end)

T.TestPhysics("ground yaw velocity follows a turntable only while grounded on it", function()
	local ground = create_ground()
	local turntable = Entity.New{
		transform = {Position = Vec3(0, 0.25, 0), Scale = Vec3(8, 0.5, 8)},
		rigid_body = {MotionType = "kinematic", Shape = BoxShape.New(Vec3(1, 1, 1)), Friction = 1},
	}
	local player = create_player(Vec3(2.5, 0.6, 0))
	local movement = player.character_movement
	local rate = 0.6
	local angle = 0

	local function step(ticks, setup)
		for _ = 1, ticks do
			angle = angle + rate / 60
			turntable.transform:SetRotation(QuatFromAxis(angle, Vec3(0, 1, 0)))
			drive(player, 1, setup)
		end
	end

	step(90)
	T(movement:GetGrounded())["=="](true)
	T(math.abs(movement:GetGroundYawVelocity() - rate))["<"](0.05)
	local view_yaw = 0

	for _ = 1, 60 do
		step(1)
		view_yaw = view_yaw + movement:GetGroundYawVelocity() / 60
	end

	T(math.abs(view_yaw - rate))["<"](0.05)

	step(6, function(cmd)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.JUMP)
	end)

	T(movement:GetGrounded())["=="](false)
	T(movement:GetGroundYawVelocity())["=="](0)
	player:Remove()
	turntable:Remove()
	ground:Remove()
end)

T.TestPhysics("ground yaw velocity is zero on static ground", function()
	local ground = create_ground()
	local player = create_player()
	drive(player, 90)
	T(player.character_movement:GetGrounded())["=="](true)
	T(player.character_movement:GetGroundYawVelocity())["=="](0)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("a body with a center offset keeps its entity origin and stays stable", function()
	local entity = Entity.New{
		transform = {Position = Vec3(1, 2, 3)},
		rigid_body = {Shape = BoxShape.New(Vec3(1, 1, 1)), GravityScale = 0},
	}
	local body = entity.rigid_body
	body:SetCenterOffset(Vec3(0, 0.5, 0))
	body:SynchronizeFromTransform()
	T((body:GetPosition() - Vec3(1, 2.5, 3)):GetLength())["<"](0.00001)
	T((body:GetOriginPosition() - Vec3(1, 2, 3)):GetLength())["<"](0.00001)

	for _ = 1, 30 do
		body:SynchronizeFromTransform()
		physics.UpdateFixed(1 / 60)
	end

	T((entity.transform:GetPosition() - Vec3(1, 2, 3)):GetLength())["<"](0.00001)
	T((body:GetPosition() - Vec3(1, 2.5, 3)):GetLength())["<"](0.00001)
	entity:Remove()
end)

local function run_scenario()
	local ground = create_ground()
	local player = create_player()
	drive(player, 90)

	drive(player, 80, function(cmd)
		cmd.forward = 1
		cmd.side = 1
		cmd.view = QuatDeg3(-10, 33, 0)
	end)

	drive(player, 30, function(cmd)
		cmd.forward = 1
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.JUMP, BUTTON.SPRINT)
	end)

	drive(player, 40, function(cmd)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.CROUCH)
	end)

	local position = player.rigid_body:GetPosition():Copy()
	local velocity = player.rigid_body:GetVelocity():Copy()
	player:Remove()
	ground:Remove()
	return position, velocity
end

T.TestPhysics("player movement is deterministic for the same commands", function()
	local position_a, velocity_a = run_scenario()
	local position_b, velocity_b = run_scenario()
	T((position_a - position_b):GetLength())["<"](0.00001)
	T((velocity_a - velocity_b):GetLength())["<"](0.00001)
end)

T.TestPhysics("player movement mode switching keeps the eye position", function()
	local player = create_player(Vec3(0, 5, 0))
	local body = player.rigid_body

	drive(player, 5, function(cmd)
		cmd.mode = "fly"
	end)

	local movement = player.character_movement
	local eye = player.transform:GetPosition() + movement:GetViewOffset()

	drive(player, 1, function(cmd)
		cmd.mode = "walk"
	end)

	T(math.abs(player.transform:GetPosition().y + movement:GetViewOffset().y - eye.y))["<"](0.1)

	drive(player, 1, function(cmd)
		cmd.mode = "fly"
	end)

	T(math.abs(player.transform:GetPosition().y + movement:GetViewOffset().y - eye.y))["<"](0.2)
end)

T.TestPhysics("player controller reconciliation corrects mispredictions and shifts history", function()
	local ground = create_ground()
	local player = create_player()
	local controller = player.player_controller
	local body = player.rigid_body
	drive(player, 100)
	local number = controller.number
	local entry = controller:GetHistory(number - 10)
	T(
		controller:Reconcile(number - 10, entry.position:Copy(), entry.velocity:Copy(), entry.distance)
	)["=="](0)
	local before = body:GetPosition():Copy()
	local later_before = controller:GetHistory(number - 5).position:Copy()
	local magnitude = controller:Reconcile(
		number - 10,
		entry.position + Vec3(1.5, 0, 0),
		entry.velocity:Copy(),
		entry.distance
	)
	T(math.abs(magnitude - 1.5))["<"](0.0001)
	T(math.abs(body:GetPosition().x - (before.x + 1.5)))["<"](0.0001)
	T(math.abs(controller:GetHistory(number - 5).position.x - (later_before.x + 1.5)))["<"](0.0001)
	T(math.abs(controller.correction_offset.x + 1.5))["<"](0.0001)
	T(controller.corrections)["=="](1)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player controller does not correct a small velocity only disagreement but does a large one", function()
	local ground = create_ground()
	local player = create_player()
	local controller = player.player_controller
	local body = player.rigid_body
	drive(player, 100)
	local number = controller.number
	local entry = controller:GetHistory(number - 10)
	local velocity_before = body:GetVelocity():Copy()
	T(
		controller:Reconcile(
			number - 10,
			entry.position:Copy(),
			entry.velocity + Vec3(0.1, 0, 0),
			entry.distance
		)
	)["=="](0)
	T(controller.corrections)["=="](0)
	T((body:GetVelocity() - velocity_before):GetLength())["<"](0.0001)
	T(math.abs(controller.last_ack.velocity_error - 0.1))["<"](0.0001)
	T(controller.last_ack.corrected)["=="](false)
	controller:Reconcile(
		number - 10,
		entry.position:Copy(),
		entry.velocity + Vec3(2, 0, 0),
		entry.distance
	)
	T(controller.corrections)["=="](1)
	T(controller.last_ack.corrected)["=="](true)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player controller ignores acknowledgements it has no history for", function()
	local player = create_player()
	local controller = player.player_controller
	T(controller:Reconcile(999, Vec3(100, 100, 100), Vec3(), 0))["=="](0)
	T((player.transform:GetPosition() - Vec3(0, 3, 0)):GetLength())["<"](0.001)
end)

T.TestPhysics("player controller start keeps the command numbers going so a server queue keeps accepting them", function()
	local ground = create_ground()
	local player = create_player()

	drive(player, 60, function(cmd)
		cmd.forward = 1
	end)

	local controller = player.player_controller
	local number = controller.number
	T(number)[">"](0)
	controller:Start(Vec3(10, 3, 10))
	T(controller.number)["=="](number)
	T(controller:GetHistory(number))["=="](nil)
	controller.last_queued = number
	local cmd = usercmd.New()
	cmd.number = number + 1
	controller:PushCommands({cmd})
	T(controller:GetQueueSize())["=="](1)
	T(player.character_movement:GetMode())["=="]("fly")
	T((player.transform:GetPosition() - Vec3(10, 3, 10)):GetLength())["<"](0.001)
	T(controller.synced)["=="](true)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player physgun grabs, holds, rotates, scrolls and freezes bodies from commands", function()
	local ground = create_ground()
	local player = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"weapon_holder",
		},
		transform = {Position = Vec3(0, 3, 0)},
		player_controller = {Source = "queue"},
	}
	local physgun_entity = player.weapon_holder:Give("weapon_physgun")
	player.player_controller.buffer_target = 1
	local crate = Entity.New{
		transform = {Position = Vec3(0, 0.5, -4)},
		rigid_body = {Shape = BoxShape.New(Vec3(1, 1, 1))},
	}

	drive(player, 90, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
	end)

	local controller = player.player_controller
	local physgun = physgun_entity.weapon_physgun
	T(player.character_pose:IsHolding())["=="](false)

	drive(player, 5, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1)
	end)

	T(physgun.held_body == crate.rigid_body)["=="](true)
	T(player.character_pose:IsHolding())["=="](true)
	T(crate.rigid_body:GetCollisionGroup())["=="](usercmd.HELD_COLLISION_GROUP)
	T(bit.band(player.rigid_body:GetCollisionMask(), usercmd.HELD_COLLISION_GROUP))["=="](0)
	local distance = physgun.held_distance

	drive(player, 5, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1)
		cmd.scroll = 1
	end)

	T(physgun.held_distance)[">"](distance)
	local offset = physgun.held_rotation_offset:Copy()

	drive(player, 5, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1)
		cmd.rotate_x = 0.1
	end)

	T(physgun.held_rotation_offset:Dot(offset))["<"](0.9999)

	drive(player, 1, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1, BUTTON.ATTACK2)
	end)

	T(crate.rigid_body:GetMotionType())["=="]("static")
	T(player.character_pose:IsHolding())["=="](false)
	T(crate.rigid_body:GetCollisionGroup())["=="](1)

	drive(player, 5, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1)
	end)

	T(physgun.held_body == nil)["=="](true)
	crate:Remove()
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player physgun releases when the primary button is released", function()
	local ground = create_ground()
	local player = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"weapon_holder",
		},
		transform = {Position = Vec3(0, 3, 0)},
		player_controller = {Source = "queue"},
	}
	local physgun_entity = player.weapon_holder:Give("weapon_physgun")
	player.player_controller.buffer_target = 1
	local ball = Entity.New{
		transform = {Position = Vec3(0, 0.5, -4)},
		rigid_body = {Shape = SphereShape.New(0.5)},
	}

	drive(player, 90, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
	end)

	drive(player, 5, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1)
	end)

	T(physgun_entity.weapon_physgun.held_body ~= nil)["=="](true)

	drive(player, 3, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
	end)

	T(physgun_entity.weapon_physgun.held_body == nil)["=="](true)
	T(player.character_pose:IsHolding())["=="](false)
	T(ball.rigid_body:GetCollisionGroup())["=="](1)
	ball:Remove()
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("weapon holder switches weapons by slot and the pistol pushes bodies", function()
	local ground = create_ground()
	local player = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"weapon_holder",
		},
		transform = {Position = Vec3(0, 3, 0)},
		player_controller = {Source = "queue"},
	}
	player.player_controller.buffer_target = 1
	local holder = player.weapon_holder
	local camera = holder:Give("weapon_camera")
	local physgun = holder:Give("weapon_physgun")
	local pistol = holder:Give("weapon_pistol")
	local crate = Entity.New{
		transform = {Position = Vec3(0, 0.5, -4)},
		rigid_body = {Shape = BoxShape.New(Vec3(1, 1, 1))},
	}

	drive(player, 90, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
	end)

	T(#holder:GetWeapons())["=="](3)
	T(camera.rigid_body == nil)["=="](true)
	T(camera.weapon:GetModel().transform:GetAttachment())["=="]("grip_r")
	T(holder:GetWeapon("right") == camera)["=="](true)

	drive(player, 1, function(cmd)
		cmd.select = 1
	end)

	T(holder:GetWeapon("right") == physgun)["=="](true)

	drive(player, 5, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1)
	end)

	T(physgun.weapon_physgun.held_body == crate.rigid_body)["=="](true)

	drive(player, 1, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.select = 2
	end)

	T(holder:GetWeapon("right") == pistol)["=="](true)
	T(physgun.weapon_physgun.held_body == nil)["=="](true)
	T(player.character_pose:IsHolding())["=="](false)
	T(crate.rigid_body:GetCollisionGroup())["=="](1)
	local eye = player.transform:GetPosition() + player.character_movement:GetViewOffset()
	crate:Remove()
	crate = Entity.New{
		transform = {Position = Vec3(0, eye.y, -6)},
		rigid_body = {Shape = BoxShape.New(Vec3(1, 1, 1)), GravityScale = 0},
	}

	drive(player, 2, function(cmd)
		cmd.view = QuatDeg3(0, 0, 0)
	end)

	drive(player, 1, function(cmd)
		cmd.view = QuatDeg3(0, 0, 0)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1)
	end)

	T(crate.rigid_body:GetVelocity().z)["<"](-0.5)
	crate:Remove()
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player body turns with the view in yaw only and stays upright", function()
	local ground = create_ground()
	local player = create_player()
	drive(player, 120)
	local feet = player.transform:GetPosition():Copy()

	drive(player, 10, function(cmd)
		cmd.view = QuatDeg3(-30, 90, 0)
	end)

	local body = player.rigid_body
	local forward = player.transform:GetRotation():GetForward()
	local up = player.transform:GetRotation():GetUp()
	T(math.abs(forward.x + 1))["<"](0.001)
	T(math.abs(forward.y))["<"](0.001)
	T(math.abs(up.y - 1))["<"](0.001)
	T((player.transform:GetPosition() - feet):GetLength())["<"](0.01)
	T((body:GetOriginPosition() - player.transform:GetPosition()):GetLength())["<"](0.0001)
	T(math.abs(body:GetPosition().y - player.transform:GetPosition().y - 0.6858))["<"](0.001)
	T(body:GetGrounded())["=="](true)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("the view offset follows the head of a command within two capsule radii", function()
	local ground = create_ground()
	local player = create_player()
	drive(player, 120)
	local movement = player.character_movement
	local eye = movement:GetEyeOffset()

	drive(player, 5, function(cmd)
		cmd.head:Set(0.1, -0.2, 0.05)
	end)

	local view = movement:GetViewOffset()
	T(math.abs(view.x - 0.1))["<"](0.0001)
	T(math.abs(view.y - (eye.y - 0.2)))["<"](0.0001)
	T(math.abs(view.z - 0.05))["<"](0.0001)

	drive(player, 5, function(cmd)
		cmd.head:Set(0, 5, 0)
	end)

	T(math.abs(movement:GetHeadOffset():GetLength() - movement:GetRadius() * 2))["<"](0.0001)
	drive(player, 5)
	T(movement:GetViewOffset():Distance(eye))["<"](0.0001)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("the distance walked follows the ground speed and a reconcile pulls it to the server value", function()
	local ground = create_ground()
	local player = create_player()
	drive(player, 120)
	local movement = player.character_movement
	local controller = player.player_controller
	T(movement.distance < 0.5)["=="](true)
	local start_position = player.transform:GetPosition():Copy()
	local start_distance = movement.distance

	drive(player, 120, function(cmd)
		cmd.forward = 1
	end)

	local walked = (player.transform:GetPosition() - start_position):GetLength()
	T(movement.distance - start_distance)["~"](walked, 0.25)
	T(movement.distance - start_distance > 1)["=="](true)
	local number = controller.number - 10
	local entry = controller:GetHistory(number)
	local before = movement.distance
	controller:Reconcile(number, entry.position:Copy(), entry.velocity:Copy(), entry.distance + 0.5)
	T(movement.distance)["~"](before + 0.5, 1e-6)
	controller:Reconcile(number, entry.position:Copy(), entry.velocity:Copy(), entry.distance)
	T(movement.distance)["~"](before + 0.5, 1e-6)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("alt walks at half speed, shift sprints at double speed, and walking wins over sprinting", function()
	local ground = create_ground()
	local player = create_player()
	drive(player, 120)
	local movement = player.character_movement
	local body = player.rigid_body

	local function speed_with(buttons)
		drive(player, 120, function(cmd)
			cmd.forward = 1
			cmd.buttons = bit.bor(cmd.buttons, buttons)
		end)

		local velocity = body:GetVelocity()
		local speed = math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
		drive(player, 60)
		return speed
	end

	local run = speed_with(0)
	local walk = speed_with(BUTTON.WALK)
	local sprint = speed_with(BUTTON.SPRINT)
	local both = speed_with(bit.bor(BUTTON.WALK, BUTTON.SPRINT))
	T(run)["~"](movement:GetGroundSpeed(), 0.3)
	T(walk)["~"](run * movement:GetWalkMultiplier(), 0.3)
	T(sprint)["~"](run * movement:GetSprintMultiplier(), 0.6)
	T(both)["~"](walk, 0.3)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("the stride odometer runs faster while strafing than while walking forward", function()
	local ground = create_ground()
	local player = create_player()
	drive(player, 120)
	local movement = player.character_movement

	local function measure(setup)
		drive(player, 60, setup)
		local before_distance = movement.distance
		local before_position = player.transform:GetPosition():Copy()
		drive(player, 60, setup)
		local walked = (player.transform:GetPosition() - before_position):GetLength()
		return (movement.distance - before_distance) / walked
	end

	local forward = measure(function(cmd)
		cmd.forward = 1
	end)
	drive(player, 60)
	local side = measure(function(cmd)
		cmd.side = 1
	end)
	T(forward)["~"](1, 0.05)
	T(side)["~"](1 / 0.7, 0.07)
	player:Remove()
	ground:Remove()
end)
