local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local aim_pose = import("lua/aim_pose.lua")
local LIMB_ANGLE = 0.9
local LIMB_ATTACK = 0.06
local LIMB_HOLD = 0.05
local LIMB_DAMP = 5
local LIMB_SPRING = 8
local LIMB_DROP = 0.25
local PARTS = {head = {pivot = "neck", reach = "head", chain = {"head"}, body = 0.5}}

for _, side in ipairs{"r", "l"} do
	PARTS["upperarm_" .. side] = {
		pivot = "upperarm_" .. side,
		reach = "hand_" .. side,
		chain = {"upperarm_" .. side, "forearm_" .. side, "hand_" .. side},
		body = 0.35,
	}
	PARTS["forearm_" .. side] = {
		pivot = "forearm_" .. side,
		reach = "hand_" .. side,
		chain = {"forearm_" .. side, "hand_" .. side},
		body = 0.3,
	}
end

local axis = Quat()
local matrix = Matrix44():Identity()

local function limb_envelope(t)
	if t < LIMB_ATTACK then return 1 - (1 - t / LIMB_ATTACK) ^ 3 end

	local h = t - LIMB_ATTACK - LIMB_HOLD

	if h < 0 then return 1 end

	return math.exp(-LIMB_DAMP * h) * math.cos(LIMB_SPRING * h)
end

local function apply_limb(bones, inst)
	local limb = inst.limb

	if not limb then return end

	local pivot = bones[limb.pivot]
	local reach = bones[limb.reach]
	local vx, vy, vz = reach.m30 - pivot.m30, reach.m31 - pivot.m31, reach.m32 - pivot.m32
	local dx, dy, dz = inst.push_x, -LIMB_DROP, inst.push_z
	matrix:SetRotation(
		axis:Identity():Rotate(
			LIMB_ANGLE * limb_envelope(inst.time) * inst.weight,
			vy * dz - vz * dy,
			vz * dx - vx * dz,
			vx * dy - vy * dx
		)
	)
	aim_pose.RotateChain(bones, limb.chain, #limb.chain, pivot, matrix)
end

local CREATURE_SEQUENCES = {
	"physflinch1",
	"physflinch2",
	"flinch1",
	"flinchheavy",
	"flinch_head",
	"flinch",
	"pain",
}
local LEAN = 0.5

local function direction(name, push_x, push_z)
	return {
		Kind = "action",
		Passive = true,
		Group = name,
		Exit = 0.25,
		Keys = {
			{
				0.1,
				ease = "out",
				aim = {-push_x * 0.3, 0.45 * push_z},
				torso = 0.45 * push_z,
				head = {1, 0.35 * push_z, 0, -0.3 * push_x},
				pelvis = {push_x * 0.2, 0, push_z * 0.2, push_x * 0.25, LEAN * push_z, -LEAN * push_x},
			},
			{
				0.32,
				aim = {-push_x * 0.2, 0.3 * push_z},
				torso = 0.3 * push_z,
				head = {1, 0.2 * push_z, 0, -0.2 * push_x},
				pelvis = {push_x * 0.26, 0, push_z * 0.26, push_x * 0.15, 0.3 * push_z, -0.3 * push_x},
			},
			{
				0.6,
				ease = "out",
				aim = {0, -0.1 * push_z},
				torso = -0.2 * push_z,
				head = {1, -0.1 * push_z, 0, 0},
				pelvis = {push_x * 0.1, 0, push_z * 0.1, 0, -0.12 * push_z, 0.12 * push_x},
			},
		},
	}
end

local DIRECTIONS = {
	{name = "stagger_right", x = 1, z = 0},
	{name = "stagger_left", x = -1, z = 0},
	{name = "stagger_back", x = 0, z = 1},
	{name = "stagger_forward", x = 0, z = -1},
}

local function init(inst, pose)
	inst.limb = PARTS[inst.part]
	inst.body_scale = inst.limb and inst.limb.body or 1
	local local_push = pose.Owner.transform:GetRotation():GetConjugated():VecMul(pose.ActionDirection)
	local length = math.sqrt(local_push.x ^ 2 + local_push.z ^ 2)
	inst.push_x, inst.push_z = 0, 1

	if length > 1e-3 then
		inst.push_x, inst.push_z = local_push.x / length, local_push.z / length
	end

	for _, entry in ipairs(DIRECTIONS) do
		pose:StartAction(entry.name, inst.duration)
		local component = pose.anims[#pose.anims]
		component.strength = math.max(inst.push_x * entry.x + inst.push_z * entry.z, 0) * inst.strength
		component.body_scale = inst.body_scale
	end
end

local function base(extra)
	local def = {
		Kind = "action",
		Exit = 0.25,
		Init = init,
		Bones = apply_limb,
		Keys = {
			{0.1, ease = "out", head = {0.6}, pelvis = {0, -0.04}},
			{0.32, head = {0.7}, pelvis = {0, -0.12}},
			{0.6, ease = "out", head = {1}, pelvis = {0, -0.14}},
		},
	}

	for key, value in pairs(extra) do
		def[key] = value
	end

	return def
end

local definitions = {
	stagger = base{Group = "melee", Stun = true, CreatureSequences = CREATURE_SEQUENCES},
	flinch = base{Group = "flinch", Passive = true, Exit = 0.15},
}

for _, entry in ipairs(DIRECTIONS) do
	definitions[entry.name] = direction(entry.name, entry.x, entry.z)
end

return definitions
