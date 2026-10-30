local rigs = {}

local function chains(prefix, names)
	local legs = {}

	for i, chain in ipairs(names) do
		legs[i] = {prefix .. chain[1], prefix .. chain[2], prefix .. chain[3]}
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
return rigs
