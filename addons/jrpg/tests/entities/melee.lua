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
local movesets = import("lua/movesets.lua")

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
	damage.Deal(victim, {Attacker = attacker, Damage = 40, Direction = Vec3(0, 0, -1)})
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
		{Moves = {a = move{Keys = {{0.5, motion = {0, 1, 1, 1}}}}}},
		"takes at most 3 numbers"
	)
	check(
		{Moves = {a = move{Keys = {{0.5, torso = 1}, {0.4, torso = 0}}}}},
		"not later than the previous torso key"
	)
end)

T.Test("a move's motion is a track of the same timeline and holds its last key", function()
	local move = movesets.Get("greatsword").Moves.cleave
	local out = {0, 0, 0}
	import("lua/animations.lua").SampleKeys(move.MotionKeys, 1, out, 3)
	T(out[1])["~"](math.rad(-10), 1e-6)
	T(out[2])["~"](1.6, 1e-6)
	T(out[3])["=="](1)
	T(movesets.GetEvent(move, "hit").At)["=="](0.56)
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
