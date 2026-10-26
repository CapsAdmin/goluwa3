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
	pose:PlayAction("slash_r", 0.4)
	pose:SetHits(pose.Hits + 1)
	step(pose, 0.1)
	T(pose:IsPlaying("roll"))["=="](true)
	T(pose:IsPlaying("slash_r"))["=="](true)
	T(pose:GetWeight("flinch") > 0)["=="](true)
	local name, phase = pose:GetActiveAction()
	T(name)["=="]("slash_r")
	T(phase > 0 and phase < 1)["=="](true)
	step(pose, 0.5)
	T(pose:IsPlaying("slash_r"))["=="](false)
	T(pose:IsPlaying("flinch"))["=="](false)
	T(pose:IsPlaying("roll"))["=="](true)
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
	local inst = animations.NewInstance("slash_r", 1)
	inst.phase = phase
	bone_keys.Apply(bones, {Time = "phase", entry}, inst, 0)
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
	pose.vertical_speed = -6
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
	T(pose:GetWeight("land"))["~"](0.75, 1e-6)
	T(animations.Get("land").Sequence(pose.anims[#pose.anims], "all", {jump_holding_land = {}}))["=="]("jump_holding_land")
	for _ = 1, 22 do
		pose:UpdateAnimations(1 / 60)
	end

	T(pose:GetWeight("land") > 0 and pose:GetWeight("land") < 0.75)["=="](true)

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
