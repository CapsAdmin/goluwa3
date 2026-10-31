local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
import("lua/weapons.lua")
import("addons/game/lua/autorun/characters.lua")
import("addons/jrpg/lua/autorun/weapons.lua")
import("addons/jrpg/lua/autorun/jrpg.lua")
local damage = import("lua/damage.lua")
local slash = import("lua/jrpg/slash.lua")
local movesets = import("lua/movesets.lua")
local actors = import("lua/actors.lua")
local grab = import("lua/grab.lua")
local jrpg = import("lua/jrpg/jrpg.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local BUTTON = usercmd.BUTTON

local function create_character(position, health, ragdoll)
	local entity = Entity.New{
		ComponentSet = {
			"transform",
			"ai_controller",
			"character_pose",
			"weapon_holder",
			"health",
			ragdoll and "ragdoll" or nil,
		},
		transform = {Position = position:Copy()},
		ai_controller = {Wander = false},
		health = {Health = health or 100, MaxHealth = health or 100},
	}
	entity.ai_controller:Teleport(position, 0)
	return entity
end

local function create_ground()
	Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = true,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
end

local function run(seconds, poses)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)

		for _, pose in ipairs(poses or {}) do
			pose:UpdateAnimations(1 / 60)
		end
	end
end

local function command(entity, forward, buttons, pressed)
	local cmd = usercmd.New()
	cmd.number = entity.character_movement:GetCommand().number
	cmd.forward = forward
	cmd.buttons = bit.bor(BUTTON.ACTIVE, buttons or 0)
	cmd.pressed = pressed or 0
	return cmd
end

local function track_height(entity, seconds, poses)
	local top = actors.GetCenter(entity).y

	for _ = 1, seconds * 60 do
		run(1 / 60, poses)
		top = math.max(top, actors.GetCenter(entity).y)
	end

	return top
end

local function count_fall_damage()
	local event = import("goluwa/event.lua")
	local falls = {count = 0}

	event.AddListener("HealthDamaged", falls, function(_, amount, _, info)
		if info.Inflictor == Entity.World and amount > 0 then
			falls.count = falls.count + 1
		end
	end)

	return falls
end

local VICTIM_BONES = {
	upperarm_r = {m30 = 0.15, m31 = 1.08, m32 = 0},
	upperarm_l = {m30 = -0.15, m31 = 1.08, m32 = 0},
}

T.Test("every moveset move is a registered action and its hits are in order", function()
	for _, name in ipairs{"sword", "greatsword", "rapier", "reaper"} do
		local set = movesets.Get(name)
		T(#set.Combo > 0)["=="](true)
		T(set.Heavy ~= nil)["=="](true)

		for _, move in pairs(set.Moves) do
			T(movesets.GetMove(move.Action))["=="](move)
			T(import("lua/animations.lua").Get(move.Action))["=="](move)
			T(move.Cancel >= (move.Events[#move.Events] or {At = 0}).At)["=="](true)
		end
	end
end)

T.Test("moveset motion orbits the focus at the keyed distance", function()
	local move = movesets.Get("reaper").Moves.carousel
	local frame = {bearing = Vec3(0, 0, 1), right = Vec3(1, 0, 0), distance = 2}
	local out = Vec3()
	movesets.SampleMotion(move, 0, frame, Vec3(0, 0, 0), out)
	T(out.z)["~"](2, 1e-6)
	movesets.SampleMotion(move, 1, frame, Vec3(0, 0, 0), out)
	T(out.z)["~"](1.3, 1e-3)
	T(out.x)["~"](0, 1e-3)
	local quarter = {0.12 + (0.82 - 0.12) / 4}
	movesets.SampleMotion(move, quarter[1], frame, Vec3(0, 0, 0), out)
	T(out.x > 0.5)["=="](true)
end)

T.TestPhysics("a light attack draws the sheathed sword, steps in and hits the target", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -2.2), 1000)
	local sword = attacker.weapon_holder:Give("weapon_sword")
	run(0.5)
	T(sword.weapon:IsSheathed())["=="](true)
	T(attacker.weapon_holder:GetPosedWeapon("right"))["=="](nil)
	sword.weapon_melee:Request("light", attacker.character_movement:GetCommand(), true)
	T(sword.weapon:IsSheathed())["=="](false)
	T(attacker.weapon_holder:GetPosedWeapon("right"))["=="](sword)
	T(attacker.character_pose.Action)["=="]("sword_light_1")
	T(attacker.character_pose:GetFocus())["=="](victim)
	run(0.7)
	T(victim.health:GetHealth() < 1000)["=="](true)
	T(attacker.transform:GetPosition().z < -0.3)["=="](true)
	T(attacker.health:GetHealth())["=="](100)
	T(attacker.move_runner.move)["=="](nil)
end)

T.TestPhysics("a sheathed weapon goes back on the back after its delay", function()
	create_ground()
	local holder = create_character(Vec3(0, 0.05, 0))
	local sword = holder.weapon_holder:Give("weapon_sword")
	sword.weapon:SetDrawn(true)
	T(sword.weapon:IsSheathed())["=="](false)
	T(sword.weapon:GetModel().transform:GetAttachment())["=="]("grip_r")
	run(sword.weapon:GetSheathDelay() + 0.2)
	T(sword.weapon:IsSheathed())["=="](true)
	T(sword.weapon:GetModel().transform:GetAttachment())["=="]("back")
end)

T.TestPhysics("a hit over the threshold freezes both fighters and staggers the victim", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -1.5))
	damage.Deal(victim, {Attacker = attacker, Damage = 10, Direction = Vec3(0, 0, -1)})
	T(victim.character_pose:IsFrozen())["=="](false)
	damage.Deal(
		victim,
		{Attacker = attacker, Damage = 40, Direction = Vec3(0, 0, -1), Type = "blunt"}
	)
	T(victim.character_pose:IsFrozen())["=="](false)
	T(attacker.character_pose:IsFrozen())["=="](false)
	T(victim.character_pose.Action)["=="]("stagger")
	run(1.2, {victim.character_pose})
	damage.Deal(
		victim,
		{Attacker = attacker, Damage = 40, Direction = Vec3(0, 0, -1), Type = "slash"}
	)
	T(victim.character_pose:IsFrozen())["=="](true)
	T(attacker.character_pose:IsFrozen())["=="](true)
	T(victim.character_pose.Action)["=="]("stagger")
	local start = victim.transform:GetPosition():Copy()
	run(0.2, {victim.character_pose})
	local strength = 0

	for _, inst in ipairs(victim.character_pose.anims) do
		if inst.def.Name:starts_with("stagger_") then
			strength = strength + inst.strength
		end
	end

	T(math.abs(strength - 1) < 0.01)["=="](true)
	T(victim.character_pose:IsStunned())["=="](true)
	run(0.5, {victim.character_pose})
	T(victim.transform:GetPosition().z < start.z - 0.3)["=="](true)
	run(0.6, {victim.character_pose})
	T(victim.character_pose:IsStunned())["=="](false)
end)

T.TestPhysics("a killing slash freezes both fighters without the stagger action", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -1.5), 30)
	damage.Deal(
		victim,
		{Attacker = attacker, Damage = 40, Direction = Vec3(0, 0, -1), Type = "slash"}
	)
	T(victim.health:IsDead())["=="](true)
	T(victim.character_pose:IsFrozen())["=="](true)
	T(attacker.character_pose:IsFrozen())["=="](true)
	T(victim.character_pose.Action ~= "stagger")["=="](true)
end)

T.TestPhysics("a hit over half the victim's health knocks a ragdoll victim down and it stands back up", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -1.5), 100, true)
	run(1, {victim.character_pose})
	damage.Deal(victim, {Attacker = attacker, Damage = 40, Direction = Vec3(0, 0, -1)})
	T(victim.ragdoll.Limp)["=="](false)
	damage.Deal(victim, {Attacker = attacker, Damage = 40, Direction = Vec3(0, 0, -1)})
	run(0.2, {victim.character_pose})
	T(victim.ragdoll.Limp)["=="](true)
	T(victim.health:IsDead())["=="](false)
	run(8, {victim.character_pose})
	T(victim.ragdoll.Limp)["=="](false)
end)

T.TestPhysics("a predicted action is adopted when the server's copy arrives instead of restarting", function()
	create_ground()
	local pose = create_character(Vec3(0, 0.05, 0)).character_pose

	local function count(name)
		local found, time = 0, nil

		for _, inst in ipairs(pose.anims) do
			if inst.def.Name == name then
				found = found + 1
				time = inst.time
			end
		end

		return found, time
	end

	pose:PredictAction("sword_light_1", 0.5)
	pose:UpdateAnimations(0.1)
	pose:SetAction("sword_light_1")
	pose:SetActionDuration(0.5)
	pose:SetActions(pose.Actions + 1)
	pose:UpdateAnimations(0.1)
	local found, time = count("sword_light_1")
	T(found)["=="](1)
	T(time)["~"](0.2, 1e-6)
	pose:SetAction("sword_light_2")
	pose:SetActions(pose.Actions + 1)
	pose:UpdateAnimations(0.1)
	T((count("sword_light_2")))["=="](1)
end)

T.TestPhysics("the sword dive throw latches onto the target and throws it", function()
	local grab = import("lua/grab.lua")
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -2), 1000, true)
	victim.source_pose = {
		bones = {
			upperarm_r = {m30 = 0.15, m31 = 1.08, m32 = 0},
			upperarm_l = {m30 = -0.15, m31 = 1.08, m32 = 0},
		},
	}
	local sword = attacker.weapon_holder:Give("weapon_sword")
	run(0.3)
	sword.weapon_melee:StartMove(movesets.Get("sword").Moves.dive_throw, true)
	local held = false

	for _ = 1, 450 do
		run(1 / 60, {attacker.character_pose, victim.character_pose})
		held = held or grab.IsHeld(victim)
	end

	T(held)["=="](true)
	T(grab.IsHeld(victim))["=="](false)
	T(victim.health:GetHealth() < 1000)["=="](true)
	T(sword.weapon_melee.grabbed)["=="](nil)
	T(victim.ragdoll.thrown or victim.ragdoll.flinging or victim.ragdoll.Limp)["~="](nil)
end)

T.TestPhysics("a move preview scrubs both characters to a phase without simulating the move", function()
	local grab = import("lua/grab.lua")
	local move_preview = import("lua/jrpg/move_preview.lua")
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -2.6), 1000, true)
	victim.source_pose = {
		bones = {
			upperarm_r = {m30 = 0.15, m31 = 1.08, m32 = 0},
			upperarm_l = {m30 = -0.15, m31 = 1.08, m32 = 0},
		},
	}
	local move = movesets.Get("sword").Moves.dive_throw
	local preview = move_preview.Start(attacker, victim, move)
	local poses = {attacker.character_pose, victim.character_pose}
	preview:SetPhase(0.3)
	run(0.2, poses)
	local name, phase = attacker.character_pose:GetActiveAction()
	T(name)["=="](move.Action)
	T(phase)["~"](0.3, 1e-3)
	T(grab.IsHeld(victim))["=="](false)
	local out = Vec3()
	movesets.SampleMotion(move, 0.3, preview.Frame, preview.Frame.point, out)
	T(attacker.transform:GetPosition().z)["~"](out.z, 1e-3)
	preview:SetPhase(0.5)
	run(0.2, poses)
	T(select(2, attacker.character_pose:GetActiveAction()))["~"](0.5, 1e-3)
	T(grab.IsHeld(victim))["=="](true)
	preview:SetPhase(0.2)
	run(0.2, poses)
	T(grab.IsHeld(victim))["=="](false)
	T(victim.transform:GetPosition().z)["~"](-2.6, 0.05)
	preview:Stop()
	run(0.1, poses)
	T(attacker.character_movement.latch)["=="](nil)
	T(attacker.character_pose.scrub)["=="](nil)
	T(attacker.transform:GetPosition().z)["~"](0, 0.05)
end)

T.TestPhysics("the move preview scrubs every move of every moveset", function()
	local move_preview = import("lua/jrpg/move_preview.lua")
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -2.6), 1000)
	victim.source_pose = {
		bones = {
			upperarm_r = {m30 = 0.15, m31 = 1.08, m32 = 0},
			upperarm_l = {m30 = -0.15, m31 = 1.08, m32 = 0},
		},
	}
	local count = 0

	for _, name in ipairs{"sword", "greatsword", "rapier", "reaper"} do
		for _, move in pairs(movesets.Get(name).Moves) do
			local preview = move_preview.Start(attacker, victim, move)

			for _, f in ipairs{0, 0.3, 0.6, 0.95} do
				preview:SetPhase(f)
				run(0.05, {attacker.character_pose})
				local active, phase = attacker.character_pose:GetActiveAction()
				T(active)["=="](move.Action)
				T(phase)["~"](f, 1e-3)
			end

			preview:Stop()
			run(0.05, {attacker.character_pose})
			count = count + 1
		end
	end

	T(count > 10)["=="](true)
end)

T.Test("moveset data is validated with a message that names the field", function()
	local function check(def, expected)
		local ok, err = pcall(movesets.Validate, "test", def)
		T(ok)["=="](false)
		T(tostring(err):find(expected, 1, true) ~= nil)["=="](true)
	end

	local Vec3 = import("goluwa/structs/vec3.lua")

	local function move(extra)
		return table.merge({Duration = 1, Keys = {{0.5, torso = 1}}}, extra or {})
	end

	check(
		{Moves = {a = move{Events = {{At = 0.5, Type = "hit", Cut = Vec3(0, 0, 1)}}}}},
		"not plain data"
	)
	check({Moves = {a = move{Wobble = 1}}}, "unknown field Wobble")
	check({Moves = {a = move{Events = {{At = 0.5, Type = "kick"}}}}}, "unknown Type kick")
	check({Moves = {a = move{Events = {{At = 0.5, Type = "hit"}}}}}, "needs Cut")
	check(
		{
			Moves = {a = move{Events = {{At = 0.5, Type = "hit", Cut = {0, 0, 1}, Spin = 1}}}},
		},
		"unknown field Spin"
	)
	check(
		{
			Moves = {
				a = move{
					Events = {{At = 0.6, Type = "latch", Range = 1}, {At = 0.5, Type = "latch", Range = 1}},
				},
			},
		},
		".At must be in order"
	)
	check({Moves = {a = move{Keys = {{0.5, wobble = 1}}}}}, "unknown field wobble")
	check({Moves = {a = move{Keys = {{0.5, "nope"}}}}}, "unknown pose nope")
	check(
		{Moves = {a = move{Keys = {{0.5, motion = {0, 1, 1, 1, 1}}}}}},
		"takes at most 4 numbers"
	)
	check(
		{Moves = {a = move{Keys = {{0.5, torso = 1}, {0.4, torso = 0}}}}},
		"not later than the previous torso key"
	)
	check({Crouch = "nope", Moves = {a = move()}}, "Crouch names an unknown move nope")
	check({Guard = "nope", Moves = {a = move()}}, "Guard names an unknown pose nope")
	check({Moves = {a = move{GripHands = "both"}}}, "GripHands must be right or left")
	check({Moves = {a = move{Dodge = {0}}}}, "Dodge must be a list of 2 numbers")
end)

T.Test("a move's motion is a track of the same timeline and holds its last key", function()
	local move = movesets.Get("greatsword").Moves.cleave
	local out = {0, 0, 0}
	import("lua/animations.lua").SampleKeys(move.MotionKeys, 1, out, 3)
	T(out[1])["~"](math.rad(-10), 1e-6)
	T(out[2])["~"](1.6, 1e-6)
	T(out[3])["=="](1)
	T(movesets.GetEvent(move, "hit").At)["=="](0.6)
	T(movesets.GetEvent(move, "latch"))["=="](nil)
end)

T.TestPhysics("the debug weapon strikes and shoots with the picked damage and type", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -1.5), 1000)
	local debug_weapon = attacker.weapon_holder:Give("weapon_debug")
	local usercmd = import("goluwa/network/usercmd.lua")
	local cmd = usercmd.New()
	cmd.aim = Quat(0, 0, 0, 1)
	debug_weapon.weapon_debug.type_index = 2
	debug_weapon.weapon_debug.damage_index = 5
	debug_weapon.weapon_debug:OnWeaponPrimary(cmd)
	T(victim.health:GetHealth() < 1000)["=="](true)
	local after_strike = victim.health:GetHealth()
	debug_weapon.weapon_debug.type_index = 1
	debug_weapon.weapon_debug:OnWeaponPrimary(cmd)
	T(victim.health:GetHealth() < after_strike)["=="](true)
end)

T.TestPhysics("a strike keeps its assisted hit and takes the part under the aim when it has a target", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -1.5), 1000, true)
	run(1)
	local head = victim.ragdoll.part_by_name.head.body.Position
	local actors = import("lua/actors.lua")
	local forward = actors.GetForward(attacker)
	local types = {"slash"}
	local _, _, assisted = slash.Strike(attacker, attacker, forward, Vec3(1, 0, 0), 1, 1, 3, types)
	T(#assisted)["=="](1)
	T(assisted[1].part ~= "head")["=="](true)
	local _, _, aimed = slash.Strike(
		attacker,
		attacker,
		forward,
		Vec3(1, 0, 0),
		1,
		1,
		3,
		types,
		{Origin = Vec3(0, head.y, 0), Direction = forward}
	)
	T(aimed[1].part)["=="]("head")
	local _, _, named = slash.Strike(attacker, attacker, forward, Vec3(1, 0, 0), 1, 1, 3, types, {Part = "head"})
	T(named[1].part)["=="]("head")
	local _, _, missed = slash.Strike(
		attacker,
		attacker,
		forward,
		Vec3(1, 0, 0),
		1,
		1,
		3,
		types,
		{Origin = Vec3(5, head.y, 0), Direction = forward}
	)
	T(#missed)["=="](1)
	T(missed[1].part)["=="](assisted[1].part)
end)

T.TestPhysics("crouching launches the victim, which hangs briefly at the top and falls back down without a follow-up", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -1.6), 1000)
	local sword = attacker.weapon_holder:Give("weapon_sword")
	run(0.3)
	local ground = actors.GetCenter(attacker).y
	local victim_ground = actors.GetCenter(victim).y
	sword.weapon_melee:Request("light", command(attacker, 0, BUTTON.CROUCH), true)
	T(attacker.character_pose.Action)["=="]("sword_rising_edge")
	local poses = {attacker.character_pose, victim.character_pose}
	local victim_top = victim_ground
	local attacker_top = ground

	for _ = 1, 50 do
		run(1 / 60, poses)
		victim_top = math.max(victim_top, actors.GetCenter(victim).y)
		attacker_top = math.max(attacker_top, actors.GetCenter(attacker).y)
	end

	T(victim.health:GetHealth() < 1000)["=="](true)
	T(attacker_top > ground + 1.4)["=="](true)
	T(victim_top > victim_ground + 0.8)["=="](true)
	T(victim.character_movement:IsHanging())["=="](true)
	run(1, poses)
	T(victim.character_movement:IsHanging())["=="](false)
	T(actors.GetCenter(victim).y)["~"](victim_ground, 0.1)
	run(2, poses)
	T(actors.GetCenter(attacker).y)["~"](ground, 0.1)
	T(actors.GetCenter(victim).y)["~"](victim_ground, 0.1)
end)

T.TestPhysics("a plunge from the air dives to the ground and strikes around the landing", function()
	create_ground()
	local attacker = create_character(Vec3(0, 3, 0))
	local victim = create_character(Vec3(0, 0.05, -1.2), 1000)
	run(0.3)
	local sword = attacker.weapon_holder:Give("weapon_sword")
	T(attacker.character_movement:GetGrounded())["=="](false)
	sword.weapon_melee:Request("light", command(attacker, 0, BUTTON.CROUCH), true)
	T(attacker.character_pose.Action)["=="]("sword_falling_star")
	run(0.45, {attacker.character_pose})
	T(attacker.character_movement:GetGrounded())["=="](true)
	T(victim.health:GetHealth() < 1000)["=="](true)
	T(attacker.health:GetHealth())["=="](100)
end)

T.TestPhysics("back and jump flips away from the target and dodges hits during the flip", function()
	create_ground()
	local player = create_character(Vec3(0, 0.05, 0))
	local enemy = create_character(Vec3(0, 0.05, -1.6), 1000)
	jrpg.SetEnabled(player, true, true)
	run(0.3)
	local sword = player.weapon_holder:FindWeapon("weapon_sword")
	local start = (actors.GetCenter(player) - actors.GetCenter(enemy)):GetLength()
	sword.weapon_melee:Step(1 / 60, command(player, -1, BUTTON.JUMP, BUTTON.JUMP), true)
	T(player.character_pose.Action)["=="]("sword_backflip")
	run(0.1, {player.character_pose})
	local health = player.health:GetHealth()
	damage.Deal(player, {Attacker = enemy, Damage = 30, Type = "slash"})
	T(player.health:GetHealth())["=="](health)
	local top = track_height(player, 0.6, {player.character_pose})
	T(top > actors.GetCenter(enemy).y + 0.5)["=="](true)
	T((actors.GetCenter(player) - actors.GetCenter(enemy)):GetLength() > start + 1.5)["=="](true)
	damage.Deal(player, {Attacker = enemy, Damage = 30, Type = "slash"})
	T(player.health:GetHealth() < health)["=="](true)
end)

T.TestPhysics("jumping toward a target vaults over it and lands behind it", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -2), 1000)
	local sword = attacker.weapon_holder:Give("weapon_sword")
	run(0.3)
	local ground = actors.GetCenter(attacker).y
	sword.weapon_melee:Step(1 / 60, command(attacker, 1, BUTTON.JUMP, BUTTON.JUMP), true)
	T(attacker.character_pose.Action)["=="]("sword_skyward_flip")
	local top = track_height(attacker, 1.2, {attacker.character_pose, victim.character_pose})
	T(top > ground + 1.8)["=="](true)
	T(actors.GetCenter(attacker).z < actors.GetCenter(victim).z - 0.6)["=="](true)
	T(actors.GetCenter(attacker).y)["~"](ground, 0.1)
	T(victim.health:GetHealth() < 1000)["=="](true)
end)

T.TestPhysics("the greatsword impale lift pins the victim to the blade and slams it down", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -2), 1000, true)
	victim.source_pose = {bones = VICTIM_BONES}
	local blade = attacker.weapon_holder:Give("weapon_greatsword")
	run(0.3)
	local falls = count_fall_damage()
	blade.weapon_melee:Request("heavy", command(attacker, 0, BUTTON.CROUCH), true)
	T(attacker.character_pose.Action)["=="]("greatsword_impale_lift")
	local held = false
	local pinned = math.huge
	local position, rotation = Vec3(), Quat()

	local function node_position(name)
		return Vec3(blade.prefab:GetNode(name).transform:GetWorldMatrix():GetTranslation())
	end

	for _ = 1, 150 do
		run(1 / 60, {attacker.character_pose, victim.character_pose})

		if grab.IsHeld(victim) then
			held = true
			grab.Get(victim):GetWantedFrame(position, rotation, true)
			local chest = position + rotation:VecMul(Vec3(0, 1.08, 0))
			local point = node_position("blade_base"):GetLerped(0.7, node_position("blade_tip"))
			pinned = math.min(pinned, (chest - point):GetLength())
		end
	end

	T(pinned < 0.05)["=="](true)
	T(held)["=="](true)
	T(grab.IsHeld(victim))["=="](false)
	T(victim.health:GetHealth() < 1000)["=="](true)
	T(victim.ragdoll.thrown or victim.ragdoll.Limp)["~="](nil)
	run(3, {attacker.character_pose, victim.character_pose})
	T(falls.count)["=="](0)
end)

T.TestPhysics("the sword heavens grasp skewers the victim, leaps with it and throws it down", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -1.8), 1000, true)
	victim.source_pose = {bones = VICTIM_BONES}
	local sword = attacker.weapon_holder:Give("weapon_sword")
	run(0.3)
	local ground = actors.GetCenter(attacker).y
	local falls = count_fall_damage()
	sword.weapon_melee:Request("heavy", command(attacker, 0, BUTTON.CROUCH), true)
	T(attacker.character_pose.Action)["=="]("sword_heavens_grasp")
	local top = ground
	local held_damage = false

	for _ = 1, 180 do
		run(1 / 60, {attacker.character_pose, victim.character_pose})
		top = math.max(top, actors.GetCenter(attacker).y)

		if grab.IsHeld(victim) and victim.health:GetHealth() < 1000 then
			held_damage = true
		end
	end

	T(top > ground + 1.5)["=="](true)
	T(held_damage)["=="](true)
	T(grab.IsHeld(victim))["=="](false)
	T(sword.weapon_melee.grabbed)["=="](nil)
	T(actors.GetCenter(attacker).y)["~"](ground, 0.1)
	run(3, {attacker.character_pose, victim.character_pose})
	T(falls.count)["=="](0)
end)

T.TestPhysics("a hit of a move that kills throws the body like a knockdown and freezes both fighters", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -1.6), 10, true)
	local sword = attacker.weapon_holder:Give("weapon_sword")
	sword.weapon:SetAttributes({})
	run(1, {victim.character_pose})
	sword.weapon_melee:Request("light", command(attacker, 0), true)
	local frozen = false

	for _ = 1, 40 do
		run(1 / 60, {attacker.character_pose, victim.character_pose})
		frozen = frozen or attacker.character_pose:IsFrozen() and victim.character_pose:IsFrozen()
	end

	T(victim.health:IsDead())["=="](true)
	T(frozen)["=="](true)
	T(victim.ragdoll.thrown)["=="](true)
end)

T.TestPhysics("back and secondary raise the blade guard, which parries when fresh and blocks part of a hit after", function()
	create_ground()
	local player = create_character(Vec3(0, 0.05, 0))
	local enemy = create_character(Vec3(0, 0.05, -1.5), 1000)
	jrpg.SetEnabled(player, true, true)
	local holder = player.weapon_holder
	local blade = holder:FindWeapon("weapon_greatsword")
	holder:Equip(blade, "right")
	run(0.3)
	player.transform:SetRotation(Quat():Identity())
	local health = player.health:GetHealth()
	damage.Deal(player, {Attacker = enemy, Damage = 30, Type = "slash"})
	local open = health - player.health:GetHealth()
	T(open > 0)["=="](true)
	local script = blade.weapon_melee
	script:Step(1 / 60, command(player, -1, BUTTON.ATTACK2), true)
	T(player.character_pose:IsBlocking())["=="](true)
	T(player.character_pose.state_args.greatsword_guard)["=="]("")
	health = player.health:GetHealth()
	damage.Deal(player, {Attacker = enemy, Damage = 30, Type = "slash"})
	T(player.health:GetHealth())["=="](health)
	T(enemy.character_pose.Action)["=="]("stagger")
	script.guard.Raised = script.guard.Raised - 1
	damage.Deal(player, {Attacker = enemy, Damage = 30, Type = "slash"})
	local guarded = health - player.health:GetHealth()
	T(guarded > 0)["=="](true)
	T(guarded < open * 0.5)["=="](true)
	script:Step(1 / 60, command(player, 0, 0), true)
	T(player.character_pose:IsBlocking())["=="](false)
	T(player.character_pose.state_args.greatsword_guard)["=="](nil)
end)

T.TestPhysics("a grab on a victim without the carry bones pins it by its centre", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -2), 1000)
	local blade = attacker.weapon_holder:Give("weapon_greatsword")
	run(0.3)
	T(victim.source_pose)["=="](nil)
	blade.weapon_melee:Request("heavy", command(attacker, 0, BUTTON.CROUCH), true)
	local held = false

	for _ = 1, 150 do
		run(1 / 60, {attacker.character_pose, victim.character_pose})
		held = held or grab.IsHeld(victim)
	end

	T(held)["=="](true)
	T(blade.weapon_melee ~= nil)["=="](true)
	T(grab.IsHeld(victim))["=="](false)
	T(victim.health:GetHealth() < 1000)["=="](true)
end)

T.TestPhysics("reloading a weapon script in the middle of a move drops the move instead of stepping the removed script", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	create_character(Vec3(0, 0.05, -2), 1000)
	local sword = attacker.weapon_holder:Give("weapon_sword")
	run(0.3)
	sword.weapon_melee:Request("light", command(attacker, 0), true)
	T(attacker.move_runner:IsPlaying())["=="](true)
	sword.script:Reload()
	import("goluwa/objects/objects.lua").CheckRemovedObjects()
	run(0.5, {attacker.character_pose})
	T(sword.script.Error)["=="](nil)
	T(attacker.move_runner:IsPlaying())["=="](false)
	sword.weapon_melee:Request("light", command(attacker, 0), true)
	T(attacker.character_pose.Action)["=="]("sword_light_1")
	run(0.6, {attacker.character_pose})
	T(sword.script.Error)["=="](nil)
end)

T.TestPhysics("a grab whose victim dies and is removed before the throw ends without an error", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -2), 5)
	victim.health:SetRemoveOnDeath(true)
	local blade = attacker.weapon_holder:Give("weapon_greatsword")
	blade.weapon:SetAttributes({})
	run(0.3)
	blade.weapon_melee:Request("heavy", command(attacker, 0, BUTTON.CROUCH), true)
	local objects = import("goluwa/objects/objects.lua")

	for _ = 1, 150 do
		run(1 / 60, {attacker.character_pose})
		objects.CheckRemovedObjects()
	end

	T(victim:IsValid())["=="](false)
	T(blade.script.Error)["=="](nil)
	T(blade.weapon_melee.grabbed)["=="](nil)
	blade.weapon_melee:Request("light", command(attacker, 0), true)
	T(attacker.character_pose.Action)["=="]("greatsword_cleave")
end)
