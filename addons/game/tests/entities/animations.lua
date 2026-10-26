local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local animations = import("lua/animations/definitions.lua")
import("addons/game/lua/autorun/characters.lua")

local function create()
	return Entity.New{transform = {Position = Vec3(0, 0, 0)}, character_pose = {}}
end

local function step(pose, seconds)
	for _ = 1, math.floor(seconds * 60) do
		pose:OnUpdate(1 / 60)
	end
end

T.Test("every definition has a valid kind and states have timings", function()
	for name, def in pairs(animations.Definitions) do
		T(def.Name)["=="](name)

		if def.Kind == "state" then
			T(def.Enter > 0)["=="](true)
			T(def.Exit > 0)["=="](true)
		elseif def.Kind == "impulse" then
			T(def.Decay > 0)["=="](true)
		end
	end
end)

T.Test("a state fades in and a cyclic state finishes its turn before fading out", function()
	local entity = create()
	local pose = entity.character_pose
	pose:SetState("roll", "forward")
	step(pose, 0.5)
	T(pose:GetWeight("roll"))["=="](1)
	T(pose.forced_crouch)["=="](true)
	T(pose.legs)["=="](false)
	T(entity.transform.OverridePosition ~= nil)["=="](true)
	pose:SetState("roll", nil)
	step(pose, 0.05)
	local inst = pose.anims[1]
	T(inst.end_cycle)["=="](math.ceil(inst.cycle / (math.pi * 2)) * math.pi * 2)
	step(pose, 3)
	T(#pose.anims)["=="](0)
	T(pose:IsPlaying("roll"))["=="](false)
	T(entity.transform.OverridePosition)["=="](nil)
	entity:Remove()
end)

T.Test("actions and impulses play at the same time as a state and expire", function()
	local entity = create()
	local pose = entity.character_pose
	pose:SetState("roll", "left")
	pose:PlayAction("cast_r", 0.4)
	pose:SetHits(pose.Hits + 1)
	step(pose, 0.1)
	T(pose:IsPlaying("roll"))["=="](true)
	T(pose:IsPlaying("cast_r"))["=="](true)
	T(pose:GetWeight("flinch") > 0)["=="](true)
	local name, phase = pose:GetActiveAction()
	T(name)["=="]("cast_r")
	T(phase > 0 and phase < 1)["=="](true)
	step(pose, 0.5)
	T(pose:IsPlaying("cast_r"))["=="](false)
	T(pose:IsPlaying("flinch"))["=="](false)
	T(pose:IsPlaying("roll"))["=="](true)
	entity:Remove()
end)

T.Test("key sampling eases per segment and holds the ends", function()
	local out = {}
	local keys = {{0, 0}, {1, 1, ease = "in"}, {2, 3, ease = "linear"}}
	T(animations.SampleKeys(keys, 0.5, out, 1)[1])["~"](0.125, 1e-9)
	T(animations.SampleKeys(keys, 1.5, out, 1)[1])["~"](2, 1e-9)
	T(animations.SampleKeys(keys, -1, out, 1)[1])["=="](0)
	T(animations.SampleKeys(keys, 5, out, 1)[1])["=="](3)
end)

T.Test("an action of a group replaces the running one", function()
	animations.Register("group_a", {Kind = "action", Group = "test_group"})
	animations.Register("group_b", {Kind = "action", Group = "test_group"})
	local entity = create()
	local pose = entity.character_pose
	pose:PlayAction("group_a", 1)
	step(pose, 0.1)
	pose:PlayAction("group_b", 1)
	step(pose, 0.1)
	T(pose:IsPlaying("group_a"))["=="](false)
	T(pose:IsPlaying("group_b"))["=="](true)
	entity:Remove()
end)

T.Test("an action with PoseWeapon asks for the weapon pose while it plays", function()
	animations.Register("pose_weapon_test", {Kind = "action", PoseWeapon = true})
	local entity = create()
	local pose = entity.character_pose
	T(animations.PosesWeapon(pose))["=="](false)
	pose:PlayAction("pose_weapon_test", 0.3)
	step(pose, 0.1)
	T(animations.PosesWeapon(pose))["=="](true)
	step(pose, 0.5)
	T(animations.PosesWeapon(pose))["=="](false)
	entity:Remove()
end)

local Vec3 = import("goluwa/structs/vec3.lua")

local function hit(pose, direction, intensity)
	pose:OnTakeDamage{
		Reaction = intensity,
		Direction = direction,
		Force = Vec3(),
		Normal = Vec3(0, 1, 0),
	}
end

T.Test("a reaction restarts on every hit and follows the direction and intensity of the hit", function()
	local entity = create()
	local pose = entity.character_pose
	local out = {0, 0, 0, 0, 0, 0}
	hit(pose, Vec3(1, 0, 0), 1)
	step(pose, 0.1)
	local inst = pose.anims[#pose.anims]
	T(inst.def.Name)["=="]("hit_react")
	inst.def.Pelvis(inst, pose, out)
	local first = out[1]
	T(first > 0)["=="](true)
	T(out[2] ~= out[1])["=="](true)
	T(math.abs(out[3]) < 1e-6)["=="](true)
	T(out[6] < 0)["=="](true)
	step(pose, 0.1)
	hit(pose, Vec3(0, 0, -1), 2)
	step(pose, 0.02)
	inst = pose.anims[#pose.anims]
	T(inst.time < 0.05)["=="](true)
	T(inst.intensity)["~"](2, 1e-6)
	inst.time = 0.12
	inst.def.Pelvis(inst, pose, out)
	T(out[3] < -0.3)["=="](true)
	T(math.abs(out[1]) < 1e-6)["=="](true)
	step(pose, 0.7)
	T(pose:IsPlaying("hit_react"))["=="](false)
	entity:Remove()
end)

T.Test("the reaction snaps out fast, holds and settles back with a small overshoot", function()
	local entity = create()
	local pose = entity.character_pose
	local out = {0, 0, 0, 0, 0, 0}
	hit(pose, Vec3(1, 0, 0), 1)
	step(pose, 0.02)
	local inst = pose.anims[#pose.anims]
	local peak, low = 0, 0

	for _, time in ipairs{0.02, 0.05, 0.08, 0.12, 0.2, 0.3, 0.4, 0.49} do
		inst.time = time
		inst.def.Pelvis(inst, pose, out)
		peak = math.max(peak, out[1])
		low = math.min(low, out[1])

		if time == 0.05 then T(out[1] > 0.9 * peak)["=="](true) end
	end

	T(peak)["~"](0.22, 0.01)
	T(low < 0)["=="](true)
	T(low > -0.2 * peak)["=="](true)
	inst.time = 0.49
	inst.def.Pelvis(inst, pose, out)
	T(math.abs(out[1]) < 0.02)["=="](true)
	entity:Remove()
end)

T.Test("a damage with a reaction triggers the reaction and not the flinch", function()
	local entity = create()
	local pose = entity.character_pose
	local info = {Force = Vec3(), Normal = Vec3(0, 1, 0)}
	info.Reaction = true
	pose:OnTakeDamage(info)
	T(pose.Reacts)["=="](1)
	T(pose.Hits)["=="](0)
	T(pose.ReactDirection.y)["~"](-1, 1e-6)
	T(pose.ReactIntensity)["=="](1)
	pose:OnTakeDamage{Force = Vec3(), Normal = Vec3(0, 1, 0)}
	T(pose.Hits)["=="](1)
	entity:Remove()
end)

T.Test("states replicate through the states string", function()
	local entity = create()
	local pose = entity.character_pose
	pose:SetState("roll", "back")
	T(pose.States)["=="]("roll=back")
	pose:SetStates("")
	step(pose, 0.1)
	T(pose:IsPlaying("roll"))["=="](false)
	pose:SetStates("roll=right")
	step(pose, 0.1)
	T(pose.anims[1].arg)["=="]("right")
	entity:Remove()
end)

local Matrix44 = import("goluwa/structs/matrix44.lua")
local bone_keys = import("lua/bone_keys.lua")

local function chain_bones()
	local bones = {}

	for name, y in pairs{root = 0, tip = 1} do
		bones[name] = Matrix44():Identity()
		bones[name]:SetTranslation(0, y, 0)
	end

	return bones
end

local function tip_after(entry, phase)
	local bones = chain_bones()
	local inst = animations.NewInstance("cast_r", 1)
	inst.phase = phase
	bone_keys.Apply(bones, {Time = "phase", entry}, inst, {seed = 0})
	return bones.tip
end

T.Test("bone keys rotate a chain about its pivot, sampled by phase and scaled by weight", function()
	local entry = {Pivot = "root", Chain = {"root", "tip"}, Pitch = {{0, 0}, {0.5, 1}, {1, 0}}}
	local rest = tip_after(entry, 0)
	T(rest.m31)["~"](1, 1e-6)
	local bent = tip_after(entry, 0.5)
	T(bent.m31)["~"](math.cos(1), 1e-6)
	T(math.abs(bent.m32))["~"](math.sin(1), 1e-6)
	T(tip_after(entry, 1).m31)["~"](1, 1e-6)
	local yawed = tip_after({Pivot = "root", Chain = {"root", "tip"}, Yaw = 1}, 0)
	T(yawed.m31)["~"](1, 1e-6)
	local rolled = tip_after({Pivot = "root", Chain = {"root", "tip"}, Roll = 1}, 0)
	T(math.abs(rolled.m30))["~"](math.sin(1), 1e-6)
	T(rolled.m31)["~"](math.cos(1), 1e-6)
end)

T.Test("the air state follows the airborne flag and a hard landing triggers the land action", function()
	local entity = create()
	local pose = entity.character_pose
	pose.grounded = false
	pose.vertical_speed = -6.75
	pose:UpdateAirborne()
	T(pose.airborne)["=="](true)
	pose:UpdateAnimations(1 / 60)

	for _ = 1, 20 do
		pose:UpdateAnimations(1 / 60)
	end

	T(pose:GetWeight("air"))["=="](1)
	local air = animations.Get("air")
	local clips = {}
	T(air.Sequence(pose.anims[1], "all", clips))["=="]("jump_passive")
	T(air.Sequence(pose.anims[1], "pistol", clips))["=="]("jump_pistol")
	clips.jump_holding_jump = {Duration = 0.43}
	pose.anims[1].time = 0.2
	T(air.Sequence(pose.anims[1], "all", clips))["=="]("jump_holding_jump")
	pose.anims[1].time = 0.6
	T(air.Sequence(pose.anims[1], "all", clips))["=="]("jump_holding_glide")
	pose.grounded = true
	pose.vertical_speed = 0
	pose:UpdateAirborne()
	T(pose.airborne)["=="](false)
	T(pose:GetWeight("land"))["~"](0.5, 1e-6)
	T(animations.Get("land").Sequence(pose.anims[#pose.anims], "all", {jump_holding_land = {}}))["=="]("jump_holding_land")

	for _ = 1, 12 do
		pose:UpdateAnimations(1 / 60)
	end

	T(pose:GetWeight("land") > 0 and pose:GetWeight("land") < 0.5)["=="](true)

	for _ = 1, 30 do
		pose:UpdateAnimations(1 / 60)
	end

	T(pose:IsPlaying("air"))["=="](false)
	T(pose:IsPlaying("land"))["=="](false)
	pose.grounded = false
	pose.vertical_speed = -1
	pose:UpdateAirborne()
	pose.grounded = true
	pose:UpdateAirborne()
	T(pose:IsPlaying("land"))["=="](false)
	entity:Remove()
end)

T.Test("the air state tilts the body with the ground speeds while rising and the other way while falling", function()
	local def = animations.Get("air")
	local inst = animations.NewInstance("air", 1)
	local entry = def.BoneKeys[1]

	local function pose(forward, right, vertical)
		return {
			forward_speed = forward,
			right_speed = right,
			vertical_speed = vertical,
			seed = 0,
		}
	end

	T(entry.Pitch(inst, pose(0, 0, 5)))["=="](0)
	T(entry.Pitch(inst, pose(5, 0, 5)) < 0)["=="](true)
	T(entry.Pitch(inst, pose(5, 0, -5)) > 0)["=="](true)
	T(entry.Pitch(inst, pose(5, 0, 5)))["~"](-entry.Pitch(inst, pose(5, 0, -5)), 1e-9)
	T(entry.Pitch(inst, pose(5, 0, 0)))["=="](0)
	T(entry.Pitch(inst, pose(50, 0, 50)) >= -0.46)["=="](true)
	T(entry.Roll(inst, pose(0, 5, 5)) < 0)["=="](true)
	T(entry.Roll(inst, pose(0, 5, -5)) > 0)["=="](true)

	local function head_after(p)
		local bones = {}

		for _, name in ipairs(entry.Chain) do
			bones[name] = Matrix44():Identity()
			bones[name]:SetTranslation(0, name == "head" and 1.2 or 0.7, 0)
		end

		bone_keys.Apply(bones, def.BoneKeys, inst, p)
		return bones.head
	end

	T(head_after(pose(5, 0, 5)).m32 < -0.05)["=="](true)
	T(head_after(pose(5, 0, -5)).m32 > 0.05)["=="](true)
	T(head_after(pose(0, 5, 5)).m30 > 0.05)["=="](true)
	T(head_after(pose(0, 5, -5)).m30 < -0.05)["=="](true)
end)

T.Test("the landing strength follows the fall speed and cuts the land clip short", function()
	local land = animations.Get("land")
	local clips = {jump_holding_land = {}}
	local soft = animations.NewInstance("land", 0.1)
	local hard = animations.NewInstance("land", 1)
	T(hard.duration)["~"](land.Duration, 1e-9)
	T(soft.duration < land.Duration * 0.4)["=="](true)
	T(soft.duration < animations.NewInstance("land", 0.4).duration)["=="](true)
	T(land.Sequence(soft, "all", clips))["=="]("jump_holding_land")
	soft.weight = soft.strength * 0.1
	T(land.Sequence(soft, "all", clips))["=="](nil)
	local entity = create()
	local pose = entity.character_pose

	local function land_with(speed)
		pose.grounded = false
		pose.vertical_speed = -speed
		pose.fall_speed = 0
		pose.airborne = false
		pose:UpdateAirborne()
		pose.grounded = true
		pose:UpdateAirborne()
		local weight = pose:GetWeight("land")
		pose.anims = {}
		return weight
	end

	T(land_with(1.5))["=="](0)
	T(land_with(5))["~"](3 / 9.5, 1e-6)
	T(land_with(11.5))["=="](1)
	T(land_with(30))["=="](1)
	entity:Remove()
end)

T.Test("the hold weight eases in and out with the wanted flag", function()
	local entity = create()
	local pose = entity.character_pose
	pose.hold_wanted = true
	step(pose, 0.1)
	local rising = pose:GetWeight("hold")
	T(rising > 0 and rising < 1)["=="](true)
	step(pose, 0.3)
	T(pose:GetWeight("hold"))["=="](1)
	pose.hold_wanted = false
	step(pose, 0.1)
	local falling = pose:GetWeight("hold")
	T(falling > 0 and falling < 1)["=="](true)
	step(pose, 0.3)
	T(pose:IsPlaying("hold"))["=="](false)
	entity:Remove()
end)
