local CREATURE_SEQUENCES = {"physflinch1", "physflinch2", "flinch1", "flinchheavy", "flinch_head", "flinch", "pain"}

local function stagger(push_x, push_z)
	local lean = 0.5
	return {
		Kind = "action",
		Group = "melee",
		Stun = true,
		Exit = 0.25,
		CreatureSequences = CREATURE_SEQUENCES,
		Keys = {
			{
				0.1,
				ease = "out",
				aim = {-push_x * 0.3, 0.45 * push_z},
				torso = 0.45 * push_z,
				head = {0.6, 0.35 * push_z, 0, -0.3 * push_x},
				pelvis = {push_x * 0.2, -0.04, push_z * 0.2, push_x * 0.25, lean * push_z, -lean * push_x},
			},
			{
				0.32,
				aim = {-push_x * 0.2, 0.3 * push_z},
				torso = 0.3 * push_z,
				head = {0.7, 0.2 * push_z, 0, -0.2 * push_x},
				pelvis = {push_x * 0.26, -0.12, push_z * 0.26, push_x * 0.15, 0.3 * push_z, -0.3 * push_x},
			},
			{
				0.6,
				ease = "out",
				aim = {0, -0.1 * push_z},
				torso = -0.2 * push_z,
				head = {1, -0.1 * push_z, 0, 0},
				pelvis = {push_x * 0.1, -0.14, push_z * 0.1, 0, -0.12 * push_z, 0.12 * push_x},
			},
		},
	}
end

return {
	stagger_back = stagger(0, 1),
	stagger_forward = stagger(0, -1),
	stagger_left = stagger(-1, 0),
	stagger_right = stagger(1, 0),
}
