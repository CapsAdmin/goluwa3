local Vec3 = import("goluwa/structs/vec3.lua")
local TAU = math.pi * 2
local PULL = Vec3(0, 1.5, -3)
return {
	ComboWindow = 0.6,
	Combo = {"reap", "reap_back", "carousel"},
	Heavy = "gallows",
	Air = "drop",
	Dash = "harvest",
	Poses = {
		hook_high = {
			aim = {-0.4, 0.4},
			hand = {0.15, 0.25, 0.1, 1.1, -0.3, -0.8},
			torso = 0.3,
			pelvis = {0.04, -0.02, 0.08, -0.25},
			head = {0.15},
		},
		hook_low = {
			aim = {0.5, -0.4},
			hand = {-0.08, -0.15, -0.25, -1.1, 0.3, 0.7},
			torso = -0.35,
			pelvis = {-0.03, -0.12, -0.12, 0.2},
			head = {0.15},
		},
	},
	Moves = {
		reap = {
			Duration = 0.6,
			Stamina = 10,
			Approach = 0.7,
			Hits = {{At = 0.52, Cut = Vec3(-0.95, -0.2, 0), Knock = PULL}},
			Motion = {{0.2}, {0.62, 50, 1.2}},
			Keys = {
				{0.3, "windup_right", ease = "out", hold = 0.05, body = {0, 0, 0, 0, -0.1}},
				{0.54, "cut_left", ease = "in", hold = 0.12, body = {0, 0, 0, 0, -0.15}},
			},
		},
		reap_back = {
			Duration = 0.6,
			Stamina = 10,
			Approach = 0.5,
			Hits = {{At = 0.52, Cut = Vec3(0.93, 0.3, 0), Knock = PULL}},
			Motion = {{0.2}, {0.62, -60, 1.2}},
			Keys = {
				{0.3, "windup_left", ease = "out", hold = 0.05, body = {0, 0, 0, 0, -0.1}},
				{0.54, "cut_right", ease = "in", hold = 0.12, body = {0, 0, 0, 0, -0.15}},
			},
		},
		carousel = {
			Duration = 1.45,
			Stamina = 24,
			Approach = 0.8,
			Retreat = 0.6,
			Hits = {
				{At = 0.34, Cut = Vec3(-0.95, -0.2, 0), Damage = 0.8},
				{At = 0.54, Cut = Vec3(0.93, 0.3, 0), Damage = 0.8},
				{At = 0.76, Cut = Vec3(0, -0.95, 0.3), Damage = 1.6, Knock = Vec3(0, 4.5, -1)},
			},
			Motion = {{0.12}, {0.82, 360, 1.3}},
			Keys = {
				{0.18, "windup_right", ease = "out", body = {0, 0, 0, 0, -0.2}},
				{0.36, "cut_left", ease = "in", body = {0, 0, 0, 0, -0.25}},
				{0.44, "windup_left", ease = "out", body = {0, 0, 0, 0, -0.25}},
				{0.56, "cut_right", ease = "in", body = {0, 0, 0, 0, -0.25}},
				{0.66, "hook_high", ease = "out", body = {0, 0, 0, 0, -0.1}},
				{0.78, "hook_low", ease = "in", hold = 0.1, body = {0, 0, 0, 0, -0.2}},
			},
		},
		gallows = {
			Duration = 1.25,
			Stamina = 30,
			Reach = 5,
			Approach = 2.5,
			Retreat = 0.5,
			Hits = {
				{At = 0.42, Cut = Vec3(0, -1, 0), Damage = 1},
				{At = 0.72, Cut = Vec3(0, -0.95, 0.3), Damage = 2.4, Knock = Vec3(0, 4, -1.5)},
			},
			Motion = {{0.15}, {0.7, 180, 1.25}},
			Keys = {
				{0.15, "hook_high", ease = "out", body = {0, 0, 0, 0, 0, 0}},
				{0.42, "hook_low", body = {0, 1, 0, 0, 0, -math.pi}},
				{0.56, "hook_high", ease = "out", body = {0, 0.6, 0, 0, 0, -math.pi * 1.6}},
				{0.72, "hook_low", ease = "in", hold = 0.12, body = {0, 0, 0, 0, 0, -TAU}},
				{1, body = {0, 0, 0, 0, 0, -TAU}},
			},
		},
		drop = {
			Duration = 0.6,
			Stamina = 16,
			Approach = 0.6,
			Hits = {{At = 0.45, Cut = Vec3(0, -0.95, 0.3), Damage = 2, Knock = PULL}},
			Motion = {{0.2}, {0.45, 0, 1.1}},
			Keys = {
				{0.25, "hook_high", ease = "out", hold = 0.05},
				{0.45, "hook_low", ease = "in", hold = 0.15},
			},
		},
		harvest = {
			Duration = 0.85,
			Stamina = 16,
			Reach = 6,
			Approach = 4,
			Hits = {{At = 0.46, Cut = Vec3(-0.95, -0.2, 0), Damage = 1.4, Knock = PULL}},
			Motion = {{0.1}, {0.32, 30, 1.2, ease = "out"}, {0.6, 110, 1.2}},
			Keys = {
				{0.25, "windup_right", ease = "out", body = {0, 0, 0, 0, -0.2}},
				{0.48, "cut_left", ease = "in", hold = 0.15, body = {0, 0, 0, 0, -0.25}},
			},
		},
	},
}
