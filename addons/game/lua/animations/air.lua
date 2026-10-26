return {
	air = {
		Kind = "state",
		Enter = 0.08,
		Exit = 0.12,
		Loop = false,
		Sequence = function(inst, suffix, clips)
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
		Exit = 0.2,
		Speed = 1.4,
		Loop = false,
		Crouch = true,
		Sequence = function(inst, suffix, clips)
			if inst.weight > 0.5 and clips.jump_holding_land then return "jump_holding_land" end
		end,
		BoneKeys = {
			{Pivot = "waist", Chain = {"spine", "chest", "back", "neck", "head", "clavicle_r", "upperarm_r", "forearm_r", "hand_r", "clavicle_l", "upperarm_l", "forearm_l", "hand_l"}, Pitch = -0.2},
			{Pivot = "thigh_r", Chain = {"thigh_r", "calf_r", "foot_r"}, Pitch = 0.5},
			{Pivot = "calf_r", Chain = {"calf_r", "foot_r"}, Pitch = -0.9},
			{Pivot = "thigh_l", Chain = {"thigh_l", "calf_l", "foot_l"}, Pitch = 0.5},
			{Pivot = "calf_l", Chain = {"calf_l", "foot_l"}, Pitch = -0.9},
		},
	},
}
