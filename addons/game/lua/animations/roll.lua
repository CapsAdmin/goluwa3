local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local PIVOT = 0.4
local PIVOT_FORWARD = 0.2
local PIVOT_HEIGHT = 0.15
local TURN = math.pi * 2
local RATE = 13
local REFERENCE_SPEED = 220 * UNIT
local SURGE = 0.3
local DRIFT = 0.12
local EASE = math.pi / 2
local LOOK_PITCH = -1.1
local HUNCH = -0.1875
local HEAD_TUCK = -0.1125
local THIGH = 0.525
local CALF = -0.75
local UPPER_ARM = 0.3375
local FOREARM = 0.4125
local WOBBLE = 0.35
local AXES = {
	forward = {"RotatePitch", -1},
	back = {"RotatePitch", 1},
	left = {"RotateRoll", 1},
	right = {"RotateRoll", -1},
}
local UPPER = {
	"spine",
	"chest",
	"back",
	"neck",
	"head",
	"clavicle_r",
	"upperarm_r",
	"forearm_r",
	"hand_r",
	"clavicle_l",
	"upperarm_l",
	"forearm_l",
	"hand_l",
}
local HEAD = {"head"}
local LEG_R = {"thigh_r", "calf_r", "foot_r"}
local LEG_L = {"thigh_l", "calf_l", "foot_l"}
local ARM_R = {"upperarm_r", "forearm_r", "hand_r"}
local ARM_L = {"upperarm_l", "forearm_l", "hand_l"}
local LOWER_LEG_R = {"calf_r", "foot_r"}
local LOWER_LEG_L = {"calf_l", "foot_l"}
local FOREARM_R = {"forearm_r", "hand_r"}
local FOREARM_L = {"forearm_l", "hand_l"}
local pivot = Vec3(0, PIVOT, 0) + Quat(0, 0, 0, 1):GetForward() * PIVOT_FORWARD
local look = Quat()

local function apply_turn(inst, target)
	local axis = AXES[inst.arg]
	target[axis[1]](target, axis[2] * inst.cycle)
end

return {
	roll = {
		BoneKeys = {
			Time = "cycle",
			{Pivot = "waist", Chain = UPPER, Pitch = HUNCH, Wobble = WOBBLE, Frequency = 1, Offset = 1.3},
			{Pivot = "neck", Chain = HEAD, Pitch = HEAD_TUCK, Wobble = WOBBLE, Frequency = 2, Offset = 2.6},
			{Pivot = "thigh_r", Chain = LEG_R, Pitch = THIGH, Wobble = WOBBLE, Frequency = 1, Offset = 3.9},
			{Pivot = "calf_r", Chain = LOWER_LEG_R, Pitch = CALF, Wobble = WOBBLE, Frequency = 3, Offset = 5.2},
			{Pivot = "thigh_l", Chain = LEG_L, Pitch = THIGH, Wobble = WOBBLE, Frequency = 2, Offset = 6.5},
			{Pivot = "calf_l", Chain = LOWER_LEG_L, Pitch = CALF, Wobble = WOBBLE, Frequency = 3, Offset = 7.8},
			{Pivot = "upperarm_r", Chain = ARM_R, Pitch = UPPER_ARM, Wobble = WOBBLE, Frequency = 1, Offset = 9.1},
			{Pivot = "forearm_r", Chain = FOREARM_R, Pitch = FOREARM, Wobble = WOBBLE, Frequency = 2, Offset = 10.4},
			{Pivot = "upperarm_l", Chain = ARM_L, Pitch = UPPER_ARM, Wobble = WOBBLE, Frequency = 3, Offset = 11.7},
			{Pivot = "forearm_l", Chain = FOREARM_L, Pitch = FOREARM, Wobble = WOBBLE, Frequency = 1, Offset = 13},
		},
		Kind = "state",
		Enter = 0.15,
		Exit = 0.3,
		Period = TURN,
		Crouch = true,
		Locomotion = false,
		Legs = false,
		Advance = function(inst, pose, dt)
			local speed = math.clamp(
				math.sqrt(pose.forward_speed ^ 2 + pose.right_speed ^ 2) / REFERENCE_SPEED,
				0.4,
				2
			)
			return RATE * speed * dt * (
					1 - SURGE * math.cos(inst.cycle) + DRIFT * math.sin(inst.time * 3 + pose.seed * TURN)
				)
		end,
		Aim = function(inst, aim)
			look:Identity():RotatePitch(LOOK_PITCH)
			return aim:GetLerped(inst.weight, look)
		end,
		View = apply_turn,
		Body = function(inst, pose, position, base)
			local turned = base:Copy()
			apply_turn(inst, turned)
			local blend = math.min(inst.cycle / EASE, 1)

			if inst.end_cycle then
				blend = math.min(blend, (inst.end_cycle - inst.cycle) / EASE)
			end

			local height = math.lerp(math.clamp(blend, 0, 1), PIVOT, PIVOT_HEIGHT)
			local moved = position + base:VecMul(pivot) + Vec3(0, height - PIVOT, 0) - turned:VecMul(pivot)
			position:Set(moved.x, moved.y, moved.z)
			base:Set(turned.x, turned.y, turned.z, turned.w)
		end,
	},
}
