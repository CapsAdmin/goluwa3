local rigs = {}

local function chains(prefix, names)
	local legs = {}

	for i, chain in ipairs(names) do
		legs[i] = {}

		for j, name in ipairs(chain) do
			legs[i][j] = prefix .. name
		end
	end

	return legs
end

rigs.antlion = {
	Root = "Antlion.Body_Bone",
	Legs = chains(
		"Antlion.",
		{
			{"LegMidR1_Bone", "LegMidR2_Bone", "LegMidR3_Bone"},
			{"LegMidL1_Bone", "LegMidL2_Bone", "LegMidL3_Bone"},
			{"LegR1_Bone", "LegR2_Bone", "LegR3_Bone"},
			{"LegL1_Bone", "LegL2_Bone", "LegL3_Bone"},
		}
	),
}
rigs.antlion_guard = {
	Root = "Antlion_Guard.body",
	Legs = chains(
		"Antlion_Guard.",
		{
			{"leg1_R", "leg2_R", "foot_R"},
			{"leg1_L", "leg2_L", "foot_L"},
		}
	),
}
rigs.hunter = {
	Root = "MiniStrider.body_joint",
	Legs = chains(
		"MiniStrider.",
		{
			{"r_leg2_bone", "r_leg3_bone", "r_foot_bone"},
			{"l_leg2_bone", "l_leg3_bone", "l_foot_bone"},
			{"bck_leg2_bone", "bck_leg3_jnt", "bck_foot_bone"},
		}
	),
}
rigs.headcrab = {
	Root = "HCfast.body",
	Scale = 0.3,
	Legs = chains(
		"HCfast.",
		{
			{"leg_bone1_R", "leg_bone2_R", "leg_bone3_R"},
			{"leg_bone1_L", "leg_bone2_L", "leg_bone3_L"},
			{"clav_R", "arm_bone1_R", "arm_bone2_R"},
			{"clav_L", "arm_bone1_L", "arm_bone2_L"},
		}
	),
}
rigs.headcrab_black = {
	Root = "HCblack.body",
	Scale = 0.3,
	Legs = chains(
		"HCblack.",
		{
			{"leg_bone1_R", "leg_bone2_R"},
			{"leg_bone1_L", "leg_bone2_L"},
			{"arm_bone1_R", "arm_bone2_R"},
			{"arm_bone1_L", "arm_bone2_L"},
		}
	),
}
rigs.lamarr = {
	Root = "HeadcrabClassic.BodyControl",
	Scale = 0.3,
	Legs = chains(
		"HeadcrabClassic.",
		{
			{"ThighR_Bone", "CalfR_Bone"},
			{"ThighL_Bone", "CalfL_Bone"},
			{"UpperArmR_Bone", "ForeArmR_Bone"},
			{"UpperArmL_Bone", "ForeArmL_Bone"},
		}
	),
}
return rigs
