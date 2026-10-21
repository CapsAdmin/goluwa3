local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local foliage = import("lua/foliage/foliage.lua")
local sets = {}
local GREEN = {0.75, 1.1, 0.6}
local DRY = {1.4, 1.1, 0.6}
local classes = {
	ground_cover = {
		conform = true,
		align_steep = 0.35,
		density_response = 3,
		distance_response = 0.1,
		max_distance = 60,
		full_density_distance = 12,
		distance_scale = 1,
		layers = {1, 0.15, 0, 0},
		slope = {0, 38, 14},
		scale = {0.8, 1.3},
		height = {0.8, 1.25},
		align = 1,
		tilt = 5,
		color = {
			surface = 0.35,
			saturation = 1.1,
			brightness = 0.5,
			variation = 0.15,
			tint = {GREEN, DRY},
			tint_scale = 18,
			tint_amount = 0.35,
		},
		cluster = {scale = 7, amount = 0.5},
	},
	flower = {
		distance_response = 0.1,
		max_distance = 45,
		full_density_distance = 10,
		layers = {1, 0, 0, 0},
		slope = {0, 30, 12},
		scale = {0.8, 1.3},
		align = 0.6,
		tilt = 6,
		color = {surface = 0, variation = 0.1},
		cluster = {scale = 5, amount = 0.95},
	},
	litter = {
		conform = true,
		density_response = 2,
		distance_response = 0.1,
		max_distance = 40,
		full_density_distance = 10,
		layers = {1, 1, 0.3, 0},
		slope = {0, 40, 10},
		scale = {0.8, 1.5},
		align = 1,
		tilt = 0,
		color = {surface = 0.1, variation = 0.15},
		cluster = {scale = 9, amount = 0.7},
	},
	bush = {
		distance_response = 0.6,
		shadow = true,
		bvh = true,
		max_distance = 160,
		full_density_distance = 90,
		layers = {1, 0.4, 0, 0},
		slope = {0, 35, 10},
		scale = {0.7, 1.3},
		height = {0.85, 1.2},
		align = 0.2,
		tilt = 4,
		sink = {0, 0.08},
		color = {surface = 0.1, variation = 0.15},
		cluster = {scale = 20, amount = 0.7},
	},
	rock = {
		distance_response = 0.6,
		shadow = true,
		bvh = true,
		max_distance = 240,
		full_density_distance = 90,
		layers = {0.5, 1, 1, 0.5},
		slope = {0, 70, 15},
		scale = {0.6, 1.6},
		height = {0.8, 1.2},
		align = 0.4,
		tilt = 8,
		sink = {0, 0.15},
		color = {surface = 0.1, variation = 0.2},
		cluster = {scale = 25, amount = 0.6},
	},
	tree = {
		distance_response = 1,
		billboard = {distance = 150},
		shadow = true,
		bvh = true,
		max_distance = 450,
		full_density_distance = 300,
		layers = {1, 0.3, 0, 0},
		slope = {0, 30, 8},
		scale = {0.8, 1.25},
		height = {0.9, 1.15},
		align = 0.05,
		tilt = 2,
		sink = {0, 0.2},
		color = {surface = 0, variation = 0.12},
		cluster = {scale = 80, amount = 0.85},
	},
}

local function proto(class, category, preset, overrides)
	local out = {model = foliage.GetModelPath(category, preset)}

	for key, value in pairs(classes[class]) do
		out[key] = value
	end

	for key, value in pairs(overrides or {}) do
		out[key] = value
	end

	return out
end

local function grass(preset, density, overrides)
	overrides = overrides or {}
	overrides.density = density
	return proto("ground_cover", "grass", preset, overrides)
end

sets.foliage_meadow = ScatterSet.New{
	Name = "foliage_meadow",
	Prototypes = {
		grass("meadow_a", 1.1),
		grass("meadow_b", 0.9),
		grass("lawn_a", 1.2, {cluster = {scale = 6, amount = 0.5}}),
		grass("lawn_b", 0.9, {cluster = {scale = 9, amount = 0.5}}),
		grass("wild_a", 0.18, {cluster = {scale = 11, amount = 0.85}}),
		grass("wild_b", 0.15, {cluster = {scale = 14, amount = 0.85}}),
		grass("tussock_a", 0.04, {cluster = {scale = 12, amount = 0.8}}),
		proto("flower", "plants", "daisies_a", {density = 0.04}),
		proto("flower", "plants", "poppies_a", {density = 0.02}),
		proto("flower", "plants", "cornflowers_a", {density = 0.02}),
		proto("flower", "plants", "buttercups_a", {density = 0.04}),
		proto("flower", "plants", "lupines_a", {density = 0.006, cluster = {scale = 8, amount = 0.95}}),
		proto("rock", "rocks", "boulder_a", {density = 0.002}),
		proto("rock", "rocks", "pebbles_a", {density = 0.01, scale = {0.8, 1.4}, max_distance = 50, align = 1, shadow = false, bvh = false}),
		proto("bush", "plants", "bush_a", {density = 0.004}),
		proto("bush", "plants", "berry_bush_a", {density = 0.002}),
		proto("tree", "trees", "oak_a", {density = 0.0004}),
		proto("tree", "trees", "oak_b", {density = 0.0003}),
		proto("tree", "trees", "birch_a", {density = 0.0004}),
	},
}
sets.foliage_forest = ScatterSet.New{
	Name = "foliage_forest",
	Prototypes = {
		proto("ground_cover", "plants", "fern_a", {density = 0.08, cluster = {scale = 9, amount = 0.7}, color = {surface = 0.1, variation = 0.15}}),
		proto("ground_cover", "plants", "fern_b", {density = 0.06, cluster = {scale = 12, amount = 0.7}, color = {surface = 0.1, variation = 0.15}}),
		proto("litter", "plants", "leaf_litter_a", {density = 0.25}),
		proto("litter", "plants", "leaf_litter_b", {density = 0.2}),
		proto("litter", "plants", "branches_a", {density = 0.03}),
		grass("tussock_a", 0.05, {cluster = {scale = 10, amount = 0.85}}),
		grass("meadow_a", 0.12, {cluster = {scale = 8, amount = 0.85}}),
		proto("flower", "plants", "fly_agaric_a", {density = 0.006}),
		proto("flower", "plants", "boletes_b", {density = 0.008}),
		proto("rock", "rocks", "mossy_boulder_a", {density = 0.004}),
		proto("rock", "rocks", "mossy_boulder_b", {density = 0.003}),
		proto("rock", "plants", "log_a", {density = 0.0012, align = 1, tilt = 0, scale = {0.8, 1.2}, height = {1, 1}, sink = {0, 0.05}, layers = {1, 1, 0, 0}, slope = {0, 25, 8}}),
		proto("rock", "plants", "pine_log_a", {density = 0.0006, align = 1, tilt = 0, scale = {0.8, 1.2}, height = {1, 1}, sink = {0, 0.05}, layers = {1, 1, 0, 0}, slope = {0, 25, 8}}),
		proto("rock", "plants", "stump_a", {density = 0.0012, align = 0.3, scale = {0.8, 1.3}}),
		proto("bush", "plants", "berry_bush_a", {density = 0.004}),
		proto("bush", "plants", "juniper_a", {density = 0.002}),
		proto("tree", "trees", "pine_a", {density = 0.002, cluster = {scale = 60, amount = 0.6}}),
		proto("tree", "trees", "pine_b", {density = 0.002, cluster = {scale = 60, amount = 0.6}}),
		proto("tree", "trees", "pine_c", {density = 0.0015, cluster = {scale = 60, amount = 0.6}}),
		proto("tree", "trees", "oak_c", {density = 0.0006}),
		proto("tree", "trees", "birch_b", {density = 0.0008}),
		proto("tree", "trees", "dead_tree_a", {density = 0.0002}),
	},
}
sets.foliage_tropical = ScatterSet.New{
	Name = "foliage_tropical",
	Prototypes = {
		grass("wild_a", 0.2, {cluster = {scale = 14, amount = 0.8}}),
		grass("meadow_a", 0.4),
		grass("meadow_b", 0.3),
		proto("ground_cover", "plants", "fern_a", {density = 0.06, cluster = {scale = 10, amount = 0.8}}),
		proto("ground_cover", "plants", "fern_b", {density = 0.05, cluster = {scale = 13, amount = 0.8}}),
		proto("flower", "plants", "poppies_b", {density = 0.01}),
		proto("flower", "plants", "buttercups_b", {density = 0.02}),
		proto("bush", "plants", "bush_a", {density = 0.006}),
		proto("bush", "plants", "bush_b", {density = 0.006}),
		proto("bush", "plants", "berry_bush_b", {density = 0.003}),
		proto("rock", "rocks", "boulder_b", {density = 0.002}),
		proto("rock", "rocks", "mossy_boulder_a", {density = 0.0015}),
		proto("tree", "trees", "palm_a", {density = 0.0015, cluster = {scale = 60, amount = 0.6}, layers = {1, 0.4, 0, 0.6}}),
		proto("tree", "trees", "palm_b", {density = 0.0012, cluster = {scale = 60, amount = 0.6}, layers = {1, 0.4, 0, 0.6}}),
		proto("tree", "trees", "palm_c", {density = 0.0012, cluster = {scale = 60, amount = 0.6}, layers = {1, 0.4, 0, 0.6}}),
	},
}
sets.foliage_rocky = ScatterSet.New{
	Name = "foliage_rocky",
	Prototypes = {
		grass("dry_a", 0.3, {layers = {1, 0.6, 0.15, 0}, color = {surface = 0.2, tint = {DRY, DRY}, tint_amount = 0.3}}),
		grass("dry_b", 0.25, {layers = {1, 0.6, 0.15, 0}, color = {surface = 0.2, tint = {DRY, DRY}, tint_amount = 0.3}}),
		grass("tussock_b", 0.05, {layers = {1, 0.5, 0.2, 0}, cluster = {scale = 10, amount = 0.8}}),
		proto("rock", "rocks", "scree_a", {density = 0.02, layers = {0.3, 1, 1, 0.3}, align = 0.8, max_distance = 120}),
		proto("rock", "rocks", "scree_b", {density = 0.015, layers = {0.3, 1, 1, 0.3}, align = 0.8, max_distance = 120}),
		proto("rock", "rocks", "pebbles_b", {density = 0.03, layers = {0.5, 1, 1, 0.5}, align = 1, max_distance = 50, shadow = false, bvh = false}),
		proto("rock", "rocks", "boulder_a", {density = 0.004}),
		proto("rock", "rocks", "boulder_b", {density = 0.003}),
		proto("rock", "rocks", "slab_a", {density = 0.002, align = 0.8}),
		proto("rock", "rocks", "crag_a", {density = 0.0008, slope = {10, 80, 10}, scale = {0.8, 2.5}}),
		proto("rock", "rocks", "crag_b", {density = 0.0006, slope = {10, 80, 10}, scale = {0.8, 2.5}}),
		proto("bush", "plants", "juniper_a", {density = 0.003}),
		proto("tree", "trees", "dead_tree_a", {density = 0.0002}),
		proto("tree", "trees", "dead_tree_b", {density = 0.0002}),
		proto("tree", "trees", "pine_c", {density = 0.0003}),
	},
}
sets.foliage_wetland = ScatterSet.New{
	Name = "foliage_wetland",
	Prototypes = {
		proto("ground_cover", "plants", "reeds_a", {density = 0.1, cluster = {scale = 10, amount = 0.85}, scale = {0.8, 1.2}, align = 0.3}),
		proto("ground_cover", "plants", "reeds_b", {density = 0.08, cluster = {scale = 13, amount = 0.85}, scale = {0.8, 1.2}, align = 0.3}),
		grass("tussock_a", 0.12),
		grass("tussock_b", 0.1),
		grass("meadow_b", 0.4),
		proto("flower", "plants", "buttercups_a", {density = 0.03}),
		proto("rock", "rocks", "mossy_boulder_b", {density = 0.002}),
		proto("rock", "rocks", "pebbles_a", {density = 0.01, align = 1, max_distance = 50, shadow = false, bvh = false}),
		proto("tree", "trees", "willow_a", {density = 0.0006}),
		proto("tree", "trees", "willow_b", {density = 0.0005}),
		proto("tree", "trees", "birch_c", {density = 0.0006}),
	},
}
return sets
