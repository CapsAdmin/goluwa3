local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local physics = import("goluwa/physics.lua")
local BUTTON = usercmd.BUTTON
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("player_movement", import("lua/components/player_movement.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
Entity.RegisterComponent("weapon_physgun", import("lua/components/weapon_physgun.lua"))
Entity.RegisterComponent("weapon_pistol", import("lua/components/weapon_pistol.lua"))
Entity.RegisterComponent("weapon_camera", import("lua/components/weapon_camera.lua"))
local SphereShape = import("goluwa/physics/shapes/sphere.lua")

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(200, 1, 200)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
end

local function create_player(position, buffer_target)
	local player = Entity.New{
		ComponentSet = {"transform", "player_controller", "player_movement"},
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

	for number = 1, controller.buffer_target + 3 do
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

	local eye = body:GetPosition():Copy()

	drive(player, 1, function(cmd)
		cmd.mode = "walk"
	end)

	local movement = player.player_movement
	T(math.abs(body:GetPosition().y + movement:GetEyeOffset().y - eye.y))["<"](0.1)

	drive(player, 1, function(cmd)
		cmd.mode = "fly"
	end)

	T(math.abs(body:GetPosition().y - eye.y))["<"](0.2)
end)

T.TestPhysics("player controller reconciliation corrects mispredictions and shifts history", function()
	local ground = create_ground()
	local player = create_player()
	local controller = player.player_controller
	local body = player.rigid_body
	drive(player, 100)
	local number = controller.number
	local entry = controller:GetHistory(number - 10)
	T(controller:Reconcile(number - 10, entry.position:Copy(), entry.velocity:Copy()))["=="](0)
	local before = body:GetPosition():Copy()
	local later_before = controller:GetHistory(number - 5).position:Copy()
	local magnitude = controller:Reconcile(number - 10, entry.position + Vec3(1.5, 0, 0), entry.velocity:Copy())
	T(math.abs(magnitude - 1.5))["<"](0.0001)
	T(math.abs(body:GetPosition().x - (before.x + 1.5)))["<"](0.0001)
	T(math.abs(controller:GetHistory(number - 5).position.x - (later_before.x + 1.5)))["<"](0.0001)
	T(math.abs(controller.correction_offset.x + 1.5))["<"](0.0001)
	T(controller.corrections)["=="](1)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player controller ignores acknowledgements it has no history for", function()
	local player = create_player()
	local controller = player.player_controller
	T(controller:Reconcile(999, Vec3(100, 100, 100), Vec3()))["=="](0)
	T((player.rigid_body:GetPosition() - Vec3(0, 3, 0)):GetLength())["<"](0.001)
end)

T.TestPhysics("player controller start resets the simulation state", function()
	local ground = create_ground()
	local player = create_player()

	drive(player, 60, function(cmd)
		cmd.forward = 1
	end)

	local controller = player.player_controller
	controller:Start(Vec3(10, 3, 10))
	T(controller.number)["=="](0)
	T(player.player_movement:GetMode())["=="]("fly")
	T((player.rigid_body:GetPosition() - Vec3(10, 3, 10)):GetLength())["<"](0.001)
	T(controller.synced)["=="](true)
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("player physgun grabs, holds, rotates, scrolls and freezes bodies from commands", function()
	local ground = create_ground()
	local player = Entity.New{
		ComponentSet = {"transform", "player_controller", "player_movement", "weapon_holder"},
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
	T(controller:IsHolding())["=="](false)

	drive(player, 5, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1)
	end)

	T(physgun.held_body == crate.rigid_body)["=="](true)
	T(controller:IsHolding())["=="](true)
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
	T(controller:IsHolding())["=="](false)
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
		ComponentSet = {"transform", "player_controller", "player_movement", "weapon_holder"},
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
	T(player.player_controller:IsHolding())["=="](false)
	T(ball.rigid_body:GetCollisionGroup())["=="](1)
	ball:Remove()
	player:Remove()
	ground:Remove()
end)

T.TestPhysics("weapon holder switches weapons by slot and the pistol pushes bodies", function()
	local ground = create_ground()
	local player = Entity.New{
		ComponentSet = {"transform", "player_controller", "player_movement", "weapon_holder"},
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
	T(holder:GetActiveWeapon() == camera)["=="](true)

	drive(player, 1, function(cmd)
		cmd.select = 1
	end)

	T(holder:GetActiveWeapon() == physgun)["=="](true)

	drive(player, 5, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.ATTACK1)
	end)

	T(physgun.weapon_physgun.held_body == crate.rigid_body)["=="](true)

	drive(player, 1, function(cmd)
		cmd.view = QuatDeg3(-15, 0, 0)
		cmd.select = 2
	end)

	T(holder:GetActiveWeapon() == pistol)["=="](true)
	T(physgun.weapon_physgun.held_body == nil)["=="](true)
	T(player.player_controller:IsHolding())["=="](false)
	T(crate.rigid_body:GetCollisionGroup())["=="](1)
	local eye = player.transform:GetPosition() + player.player_movement:GetViewOffset()
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
