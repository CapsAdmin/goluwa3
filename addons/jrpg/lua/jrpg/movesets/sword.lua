local Vec3 = import("goluwa/structs/vec3.lua")
return {
	Combo = {"light_1", "light_2", "light_3"},
	Heavy = "heavy",
	Air = "jump",
	Dash = "dash",
	Moves = {
		light_1 = {
			Duration = 0.5,
			Stamina = 10,
			Approach = 0.45,
			Hits = {{At = 0.5, Cut = Vec3(-0.94, -0.33, 0), Swing = {0.36, 0.56}}},
			Motion = {{0.25}, {0.5, 0, 1.1}},
			Keys = {
				{0.3, "windup_right", ease = "out", hold = 0.06},
				{0.52, "cut_left", ease = "in", hold = 0.1},
			},
		},
		light_2 = {
			Duration = 0.5,
			Stamina = 10,
			Approach = 0.45,
			Branch = "rising",
			Hits = {{At = 0.5, Cut = Vec3(0.93, 0.37, 0), Swing = {0.36, 0.56}}},
			Motion = {{0.25}, {0.5, -15, 1.1}},
			Keys = {
				{0.3, "windup_left", ease = "out", hold = 0.06},
				{0.52, "cut_right", ease = "in", hold = 0.1},
			},
		},
		light_3 = {
			Duration = 0.7,
			Stamina = 14,
			Approach = 1,
			Hits = {{At = 0.57, Cut = Vec3(0, 0, 1), Damage = 1.6, Swing = {0.46, 0.62}}},
			Motion = {{0.3}, {0.58, 35, 1, ease = "in"}},
			Keys = {
				{0.4, "thrust_windup", ease = "out", hold = 0.06},
				{0.58, "thrust", ease = "in", hold = 0.12},
			},
		},
		heavy = {
			Duration = 1,
			Stamina = 28,
			Approach = 0.9,
			Hits = {{At = 0.66, Cut = Vec3(0, -0.97, 0.25), Damage = 2.6, Swing = {0.56, 0.72}}},
			Motion = {{0.5}, {0.66, 0, 1.1, ease = "in"}},
			Keys = {
				{0.42, "overhead", ease = "out", hold = 0.14},
				{0.66, "slam", ease = "in", hold = 0.12},
			},
		},
		rising = {
			Duration = 0.8,
			Stamina = 20,
			Approach = 0.6,
			Hits = {
				{At = 0.5, Cut = Vec3(-0.5, 0.86, 0), Damage = 1.8, Knock = Vec3(0, 5.5, 0.5)},
			},
			Motion = {{0.2}, {0.5, 0, 1}},
			Keys = {
				{0.28, "low_right", ease = "out", hold = 0.06},
				{0.52, "high_left", ease = "in", body = {0, 0.4, 0, 0, 0.1}},
				{0.66, "high_left", body = {0, 0.45, 0, 0, 0.1}},
				{0.85, body = {0, 0, 0}, ease = "in"},
			},
		},
		jump = {
			Duration = 0.6,
			Stamina = 18,
			Approach = 0.4,
			Hits = {{At = 0.45, Cut = Vec3(0, -0.95, 0.3), Damage = 2, Swing = {0.3, 0.5}}},
			Motion = {{0.2}, {0.45, 0, 1.1}},
			Keys = {
				{0.25, "overhead", ease = "out", hold = 0.05},
				{0.45, "slam", ease = "in", hold = 0.1},
			},
		},
		dash = {
			Duration = 0.75,
			Stamina = 16,
			Reach = 6,
			Approach = 4,
			Retreat = 0.5,
			Hits = {{At = 0.42, Cut = Vec3(0.95, 0.1, 0), Damage = 1.5}},
			Motion = {{0.12}, {0.32, 40, 1.3, ease = "out"}, {0.55, 150, 1.3}},
			Keys = {
				{0.2, "draw_left", ease = "out"},
				{0.44, "cut_right", ease = "in", hold = 0.16},
			},
		},
	},
}
