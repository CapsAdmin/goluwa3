local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local actors = import("lua/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local stagger = {}
stagger.Fraction = 0.25
stagger.MinDamage = 20
stagger.Duration = 0.85
stagger.Hitstop = 0.08
stagger.MaxHitstop = 0.16
stagger.Knockback = 0.7
stagger.KnockbackTime = 0.3
local CUT_SHARE = 0.6
local TEXT = Color(1, 0.85, 0.35, 1)

function stagger.GetThreshold(victim)
	return math.max(stagger.MinDamage, victim.health:GetMaxHealth() * stagger.Fraction)
end

function stagger.GetHitstop(amount, threshold)
	return math.lerp(math.clamp(amount / threshold - 1, 0, 1), stagger.Hitstop, stagger.MaxHitstop)
end

local function pick_action(victim, push)
	local rotation = victim.transform:GetRotation()
	local side = push:Dot(rotation:GetRight())
	local back = -push:Dot(rotation:GetForward())

	if math.abs(side) > math.abs(back) then
		return side > 0 and "stagger_right" or "stagger_left"
	end

	return back > 0 and "stagger_back" or "stagger_forward"
end

function stagger.Apply(victim, attacker, push, hitstop)
	local pose = victim.character_pose
	pose:Freeze(hitstop)
	pose:PlayAction(pick_action(victim, push), stagger.Duration)
	local movement = victim.character_movement

	if movement then
		movement:Lunge(push, stagger.Knockback, hitstop, stagger.KnockbackTime)
	end

	if
		attacker and
		attacker ~= victim and
		attacker:IsValid() and
		attacker.character_pose
	then
		attacker.character_pose:Freeze(hitstop)
	end

	effects.Text(victim, "STAGGER", TEXT)
	effects.Stagger(victim, attacker or victim, hitstop)
end

event.AddListener("HealthDamaged", "jrpg_stagger", function(victim, amount, max_health, info)
	if not network.HasAuthority() then return end

	if info.Secondary or info.Status or amount <= 0 then return end

	if not victim.character_pose or victim.health:IsDead() then return end

	local threshold = stagger.GetThreshold(victim)

	if amount < threshold then return end

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
	stagger.Apply(victim, attacker, push, stagger.GetHitstop(amount, threshold))
end)

return stagger
