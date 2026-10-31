local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local actors = import("lua/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local stagger = {}
stagger.Fraction = 0.25
stagger.MinDamage = 20
stagger.KnockdownFraction = 0.5
stagger.KnockdownMinDamage = 40
stagger.KnockdownSpeed = 5
stagger.KnockdownMaxSpeed = 9
stagger.KnockdownLift = 3
stagger.Duration = 0.85
stagger.FreezeFraction = 0.3
stagger.Hitstop = 0.08
stagger.MaxHitstop = 0.16
stagger.Knockback = 0.7
stagger.KnockbackTime = 0.3
local CUT_SHARE = 0.6
local TEXT = Color(1, 0.85, 0.35, 1)

function stagger.GetThreshold(before)
	return math.max(stagger.MinDamage, before * stagger.Fraction)
end

function stagger.GetKnockdownThreshold(before)
	return math.max(stagger.KnockdownMinDamage, before * stagger.KnockdownFraction)
end

function stagger.GetHitstop(amount, threshold)
	return math.lerp(math.clamp(amount / threshold - 1, 0, 1), stagger.Hitstop, stagger.MaxHitstop)
end

function stagger.Apply(victim, attacker, push, hitstop, part, direction)
	local freeze = stagger.Duration * stagger.FreezeFraction
	local pose = victim.character_pose
	pose:Freeze(freeze, true)
	pose:PlayAction("stagger", stagger.Duration, part, push)
	local movement = victim.character_movement

	if movement then
		movement:Lunge(push, stagger.Knockback, 0, stagger.KnockbackTime)
	end

	if
		attacker and
		attacker ~= victim and
		attacker:IsValid() and
		attacker.character_pose
	then
		attacker.character_pose:Freeze(freeze)
	end

	effects.Text(victim, "STAGGER", TEXT)
	effects.Stagger(victim, attacker or victim, hitstop, direction)
end

function stagger.Knockdown(victim, attacker, push, hitstop, power, direction)
	victim.character_pose:Freeze(hitstop, true)
	victim.ragdoll:Knockdown(
		push * math.lerp(power, stagger.KnockdownSpeed, stagger.KnockdownMaxSpeed) + Vec3(0, stagger.KnockdownLift, 0),
		attacker
	)

	if
		attacker and
		attacker ~= victim and
		attacker:IsValid() and
		attacker.character_pose
	then
		attacker.character_pose:Freeze(hitstop)
	end

	effects.Text(victim, "KNOCKDOWN", TEXT)
	effects.Stagger(victim, attacker or victim, hitstop, direction)
end

event.AddListener("HealthDamaged", "jrpg_stagger", function(victim, amount, max_health, info)
	if not network.HasAuthority() then return end

	if info.Secondary or info.Status or amount <= 0 then return end

	if not victim.character_pose or victim.health:IsDead() then return end

	local before = victim.health:GetHealth() + amount
	local threshold = stagger.GetThreshold(before)

	if amount < threshold and not victim.character_pose:IsAlwaysStagger() then
		return
	end

	info.Staggered = true
	local attacker = info.Attacker
	local push = Vec3()

	if attacker and attacker:IsValid() and attacker ~= victim then
		push = actors.GetCenter(victim) - actors.GetCenter(attacker)
		push.y = 0
		push = push:GetLength() > 1e-3 and push:GetNormalized() or push
	end

	if info.Direction then
		push = push + Vec3(info.Direction.x, 0, info.Direction.z) * CUT_SHARE
	end

	push = push:GetLength() > 1e-3 and
		push:GetNormalized() or
		actors.GetForward(victim) * -1
	local direction = info.Direction or push
	local hitstop = stagger.GetHitstop(amount, threshold)
	local knockdown = stagger.GetKnockdownThreshold(before)

	if victim.ragdoll and amount >= knockdown then
		stagger.Knockdown(
			victim,
			attacker,
			push,
			hitstop,
			math.clamp(amount / knockdown - 1, 0, 1),
			direction
		)
		return
	end

	stagger.Apply(victim, attacker, push, hitstop, info.Part, direction)
end)

return stagger
