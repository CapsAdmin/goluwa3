local UNIT = import("goluwa/source_engine/units.lua").meters
local REFERENCE_SPEED = 200 * UNIT
local MAX_RATIO = 1.5
local TILT = 0.3
local FLIP_SPEED = 2.5
local BODY = {
	"body",
	"waist",
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
	"thigh_r",
	"calf_r",
	"foot_r",
	"thigh_l",
	"calf_l",
	"foot_l",
}

local function tilt_pitch(inst, pose)
	return -math.clamp(pose.forward_speed / REFERENCE_SPEED, -MAX_RATIO, MAX_RATIO) * TILT * math.clamp(pose.vertical_speed / FLIP_SPEED, -1, 1)
end

local function tilt_roll(inst, pose)
	return -math.clamp(pose.right_speed / REFERENCE_SPEED, -MAX_RATIO, MAX_RATIO) * TILT * math.clamp(pose.vertical_speed / FLIP_SPEED, -1, 1)
end

return {
	air = {
		BoneKeys = {{Pivot = "body", Chain = BODY, Pitch = tilt_pitch, Roll = tilt_roll}},
		Kind = "state",
		Enter = 0.08,
		Exit = 0.12,
		Loop = false,
		Sequence = function(inst, suffix, clips)
			if inst.weight <= 0.5 then return end

			local jump = clips.jump_holding_jump

			if jump then
				return inst.time < jump.Duration and "jump_holding_jump" or "jump_holding_glide"
			end

			return "jump_" .. (suffix == "all" and "passive" or suffix)
		end,
	},
	land = {
		Kind = "action",
		Duration = 0.45,
		Cutoff = function(strength)
			return strength
		end,
		Exit = 0.2,
		Speed = 1.4,
		Loop = false,
		Crouch = true,
		Sequence = function(inst, suffix, clips)
			if inst.weight > inst.strength * 0.25 and clips.jump_holding_land then
				return "jump_holding_land"
			end
		end,
		BoneKeys = {
			{
				Pivot = "waist",
				Chain = {
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
				},
				Pitch = -0.2,
			},
			{Pivot = "thigh_r", Chain = {"thigh_r", "calf_r", "foot_r"}, Pitch = 0.5},
			{Pivot = "calf_r", Chain = {"calf_r", "foot_r"}, Pitch = -0.9},
			{Pivot = "thigh_l", Chain = {"thigh_l", "calf_l", "foot_l"}, Pitch = 0.5},
			{Pivot = "calf_l", Chain = {"calf_l", "foot_l"}, Pitch = -0.9},
		},
	},
}
