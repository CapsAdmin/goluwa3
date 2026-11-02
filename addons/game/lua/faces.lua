local faces = {}
faces.Presets = {
	neutral = {Scale = 1, Flex = {}},
	indifferent = {
		Scale = 2,
		Flex = {
			right_lid_raiser = 0.02,
			left_lid_raiser = 1,
			right_lid_tightener = 0.98,
			left_lid_tightener = 0.59,
			right_lid_droop = 0.6,
			left_lid_droop = 0.89,
			right_lid_closer = 0.36,
			left_lid_closer = 0.53,
			half_closed = 0.76,
			right_inner_raiser = 0.19,
			left_inner_raiser = 0.94,
			right_outer_raiser = 0.1,
			left_outer_raiser = 0.87,
			right_lowerer = 0.39,
			left_lowerer = 0.03,
			right_cheek_raiser = 0.13,
			left_cheek_raiser = 0.41,
			wrinkler = 0.14,
			dilator = 0.45,
			right_upper_raiser = 0.73,
			left_upper_raiser = 0.64,
			right_corner_puller = 0.57,
			left_corner_puller = 0.36,
			right_corner_depressor = 1,
			left_corner_depressor = 0.18,
			chin_raiser = 0.48,
			right_part = 0.22,
			left_part = 0.3,
			right_puckerer = 0.97,
			left_puckerer = 0.04,
			right_funneler = 0.22,
			left_funneler = 0.15,
			right_stretcher = 0.08,
			left_stretcher = 0.16,
			bite = 0.07,
			presser = 1,
			tightener = 0.3,
			jaw_clencher = 0.05,
			jaw_drop = 0.03,
			right_mouth_drop = 0.54,
			left_mouth_drop = 0.33,
			smile = 0.68,
			lower_lip = 0.5,
		},
	},
	annoyed = {
		Scale = 2,
		Flex = {
			right_lid_raiser = 1,
			left_lid_raiser = 1,
			right_lid_closer = 0.2,
			left_lid_closer = 0.23,
			right_inner_raiser = 0.49,
			left_inner_raiser = 0.2,
			right_outer_raiser = 0.31,
			left_outer_raiser = 0.96,
			right_lowerer = 0.9,
			left_lowerer = 0.77,
			right_cheek_raiser = 0.97,
			left_cheek_raiser = 0.29,
			wrinkler = 0.37,
			dilator = 0.51,
			right_upper_raiser = 0.53,
			left_upper_raiser = 0.34,
			right_corner_puller = 0.61,
			left_corner_puller = 0.44,
			right_corner_depressor = 0.79,
			left_corner_depressor = 0.75,
			chin_raiser = 0.05,
			right_part = 0.1,
			left_part = 0.84,
			right_puckerer = 0.03,
			left_puckerer = 0.91,
			right_funneler = 0.69,
			left_funneler = 0.01,
			right_stretcher = 0.73,
			left_stretcher = 0.67,
			bite = 0.93,
			presser = 0.85,
			jaw_clencher = 0.68,
			jaw_drop = 0.15,
			right_mouth_drop = 0.11,
			left_mouth_drop = 0.88,
			smile = 0.6,
			lower_lip = 0.79,
		},
	},
	blowing = {
		Scale = 1,
		Flex = {
			right_lid_raiser = 1,
			left_lid_raiser = 1,
			right_lid_droop = 1,
			left_lid_droop = 1,
			right_lid_closer = 1,
			left_lid_closer = 1,
			half_closed = 1,
			right_inner_raiser = 0.03,
			left_inner_raiser = 0.04,
			right_upper_raiser = 1,
			left_upper_raiser = 1,
			right_corner_puller = 0.46,
			left_corner_puller = 0.47,
			right_corner_depressor = 0.37,
			left_corner_depressor = 0.87,
			right_part = 0.11,
			left_part = 0.1,
			right_puckerer = 0.13,
			left_puckerer = 0.12,
			right_funneler = 0.89,
			left_funneler = 0.78,
			right_stretcher = 0.71,
			left_stretcher = 0.95,
			bite = 1,
			presser = 1,
			tightener = 1,
			jaw_drop = 0.8,
			left_mouth_drop = 1,
			smile = 0.23,
			lower_lip = 0.75,
		},
	},
	sorry = {
		Scale = 1,
		Flex = {
			right_lid_raiser = 1,
			left_lid_raiser = 1,
			right_inner_raiser = 1,
			left_inner_raiser = 1,
			wrinkler = 0.47,
			right_corner_depressor = 1,
			left_corner_depressor = 1,
			chin_raiser = 0.99,
			left_part = 0.54,
			right_puckerer = 1,
			left_puckerer = 1,
			left_stretcher = 1,
			bite = 1,
			jaw_clencher = 1,
			right_mouth_drop = 1,
			left_mouth_drop = 1,
		},
	},
	joker = {
		Scale = 7.24,
		Flex = {
			right_lid_raiser = 1,
			left_lid_raiser = 1,
			right_lid_tightener = 1,
			left_lid_tightener = 1,
			right_lid_droop = 1,
			left_lid_droop = 1,
			right_outer_raiser = 0.66,
			left_outer_raiser = 0.49,
			dilator = 1,
			right_upper_raiser = 1,
			left_upper_raiser = 1,
			right_corner_puller = 1,
			left_corner_puller = 1,
			right_part = 1,
			left_part = 1,
			right_funneler = 1,
			left_funneler = 1,
			right_stretcher = 1,
			left_stretcher = 1,
			right_mouth_drop = 1,
			smile = 0.63,
		},
	},
	happy = {
		Scale = 2.4,
		Flex = {
			right_lid_raiser = 1,
			left_lid_raiser = 1,
			right_lid_droop = 0.65,
			left_lid_droop = 0.43,
			right_inner_raiser = 0.65,
			left_inner_raiser = 0.68,
			right_lowerer = 0.48,
			left_lowerer = 0.46,
			right_cheek_raiser = 0.14,
			left_cheek_raiser = 0.37,
			wrinkler = 0.91,
			dilator = 0.17,
			right_corner_puller = 1,
			left_corner_puller = 1,
			right_corner_depressor = 0.79,
			left_corner_depressor = 0.78,
			right_part = 1,
			left_part = 1,
			right_stretcher = 1,
			left_stretcher = 1,
			jaw_clencher = 1,
			jaw_drop = 0.44,
			smile = 0.75,
			lower_lip = 0.14,
		},
	},
	disbelief = {
		Scale = 2.4,
		Flex = {
			right_lid_raiser = 1,
			left_lid_raiser = 1,
			right_inner_raiser = 1,
			left_inner_raiser = 1,
			right_outer_raiser = 0.58,
			left_outer_raiser = 0.56,
			right_corner_puller = 1,
			left_corner_puller = 1,
			right_corner_depressor = 1,
			left_corner_depressor = 1,
			right_part = 1,
			left_part = 1,
			right_stretcher = 1,
			left_stretcher = 1,
			jaw_clencher = 1,
			jaw_drop = 1,
			right_mouth_drop = 1,
			left_mouth_drop = 1,
		},
	},
	grin = {
		Scale = 2,
		Flex = {
			right_upper_raiser = 1,
			left_upper_raiser = 1,
			right_corner_puller = 1,
			left_corner_puller = 1,
			right_part = 1,
			left_part = 1,
			right_stretcher = 1,
			left_stretcher = 1,
			jaw_drop = 1,
			smile = 1,
			lower_lip = 1,
		},
	},
	smile = {
		Scale = 2,
		Flex = {
			right_upper_raiser = 1,
			left_upper_raiser = 1,
			right_corner_puller = 1,
			left_corner_puller = 1,
			right_part = 0.6,
			left_part = 0.4,
			right_stretcher = 1,
			left_stretcher = 1,
			right_mouth_drop = 1,
			left_mouth_drop = 1,
		},
	},
	sad = {
		Scale = 2,
		Flex = {
			right_inner_raiser = 1,
			left_inner_raiser = 1,
			right_corner_depressor = 1,
			left_corner_depressor = 1,
			right_lid_raiser = 1,
			left_lid_raiser = 1,
			chin_raiser = 0.5,
		},
	},
	fury = {
		Scale = 2,
		Flex = {
			right_lid_tightener = 0.7,
			left_lid_tightener = 0.7,
			right_lowerer = 1,
			left_lowerer = 1,
			wrinkler = 0.8,
			dilator = 0.6,
			right_upper_raiser = 1,
			left_upper_raiser = 1,
			right_corner_depressor = 0.3,
			left_corner_depressor = 0.3,
			right_part = 1,
			left_part = 1,
			right_stretcher = 0.8,
			left_stretcher = 0.8,
			jaw_drop = 0.75,
			right_mouth_drop = 0.6,
			left_mouth_drop = 0.6,
		},
	},
	determined = {
		Scale = 1.8,
		Flex = {
			right_lid_tightener = 0.6,
			left_lid_tightener = 0.6,
			right_lowerer = 0.7,
			left_lowerer = 0.7,
			right_corner_depressor = 0.2,
			left_corner_depressor = 0.2,
			chin_raiser = 0.4,
			presser = 0.5,
			tightener = 0.4,
			jaw_clencher = 1,
		},
	},
	smirk = {
		Scale = 2,
		Flex = {
			right_lid_tightener = 0.3,
			left_lid_tightener = 0.3,
			right_outer_raiser = 0.4,
			left_lowerer = 0.4,
			right_cheek_raiser = 0.5,
			right_corner_puller = 1,
			presser = 0.3,
			smile = 0.3,
		},
	},
	pain = {
		Scale = 1.7,
		Flex = {
			right_lid_closer = 0.35,
			left_lid_closer = 0.35,
			right_lid_tightener = 0.6,
			left_lid_tightener = 0.6,
			right_inner_raiser = 1,
			left_inner_raiser = 1,
			right_lowerer = 0.5,
			left_lowerer = 0.5,
			right_cheek_raiser = 0.8,
			left_cheek_raiser = 0.8,
			wrinkler = 1,
			right_upper_raiser = 0.8,
			left_upper_raiser = 0.8,
			right_corner_depressor = 0.5,
			left_corner_depressor = 0.5,
			right_part = 0.7,
			left_part = 0.7,
			right_stretcher = 1,
			left_stretcher = 1,
			jaw_drop = 0.25,
		},
	},
	shock = {
		Scale = 2,
		Flex = {
			right_lid_raiser = 1,
			left_lid_raiser = 1,
			right_inner_raiser = 1,
			left_inner_raiser = 1,
			right_outer_raiser = 1,
			left_outer_raiser = 1,
			dilator = 0.5,
			right_part = 1,
			left_part = 1,
			right_stretcher = 0.6,
			left_stretcher = 0.6,
			jaw_drop = 0.7,
			right_mouth_drop = 0.4,
			left_mouth_drop = 0.4,
		},
	},
	dead = {
		Scale = 1,
		Flex = {
			right_lid_droop = 1,
			left_lid_droop = 1,
			half_closed = 0.7,
			right_part = 0.5,
			left_part = 0.5,
			jaw_drop = 0.4,
		},
	},
}

function faces.Sample(keys, phase)
	local attacker, victim

	for i = 1, #keys do
		local key = keys[i]

		if key[1] > phase then break end

		attacker = key[2] or attacker
		victim = key.victim or victim
	end

	return attacker, victim
end

function faces.GetRig(entity)
	local animator = entity.animator
	local rig = animator and animator:GetRig()

	if rig and rig.skeleton.Flex then return rig end

	local avatar = entity.player_avatar
	rig = avatar and avatar:GetEyeRig()

	if rig and rig.skeleton.Flex then return rig end
end

do
	local shown = table.weak("k")

	function faces.Show(rig, name)
		if shown[rig] == name or rig:IsHeld() then return end

		for controller in pairs(faces.Presets[shown[rig] or "neutral"].Flex) do
			if rig:HasFlex(controller) then rig:SetFlex(controller, 0) end
		end

		local preset = faces.Presets[name or "neutral"]

		for controller, value in pairs(preset.Flex) do
			if rig:HasFlex(controller) then rig:SetFlex(controller, value) end
		end

		rig:SetFlexScale(preset.Scale)
		shown[rig] = name
	end
end

return faces
