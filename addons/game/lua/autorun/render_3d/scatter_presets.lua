local steam = import("goluwa/steam/steam.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local presets = {}
local info = list.find(steam.GetGames(), function(game)
	return game.appid == 17300
end)

if not info then return presets end

local root = info.game_dir .. "Game/Objects.pak/Objects/Natural/"
local GREEN = {0.7, 1.15, 0.5}
local DRY = {1.45, 1.05, 0.55}
local classes = {
	ground_cover = {
		conform = true,
		align_steep = 0.35,
		density_response = 3,
		distance_response = 0.1,
		max_distance = 70,
		full_density_distance = 12,
		distance_scale = 1,
		layers = {1, 0.15, 0, 0},
		slope = {0, 38, 14},
		scale = {0.75, 1.35},
		height = {0.8, 1.25},
		align = 1,
		tilt = 5,
		bending = 1,
		color = {
			surface = 0.55,
			saturation = 1.2,
			brightness = 0.4,
			variation = 0.2,
			tint = {{1, 1, 1}, DRY},
			tint_scale = 18,
			tint_amount = 0.5,
		},
		cluster = {scale = 7, amount = 0.6},
	},
	flower = {
		distance_response = 0.1,
		max_distance = 55,
		full_density_distance = 12,
		layers = {1, 0, 0, 0},
		slope = {0, 30, 12},
		scale = {0.8, 1.3},
		align = 0.8,
		tilt = 4,
		bending = 1,
		color = {surface = 0.2, variation = 0.15},
		cluster = {scale = 5, amount = 0.95},
	},
	bush = {
		distance_response = 0.6,
		shadow = true,
		bvh = true,
		max_distance = 170,
		full_density_distance = 100,
		layers = {1, 0.4, 0, 0},
		slope = {0, 35, 10},
		scale = {0.7, 1.4},
		height = {0.85, 1.2},
		align = 0.2,
		tilt = 3,
		bending = 1,
		sink = {0, 0.1},
		color = {surface = 0.25, variation = 0.2},
		cluster = {scale = 20, amount = 0.7},
	},
	rock = {
		distance_response = 0.6,
		shadow = true,
		bvh = true,
		max_distance = 250,
		full_density_distance = 90,
		layers = {0.5, 1, 1, 0.5},
		slope = {0, 70, 15},
		scale = {0.6, 1.5},
		height = {0.7, 1.2},
		align = 0.35,
		tilt = 8,
		sink = {0.05, 0.3},
		color = {surface = 0.1, variation = 0.25},
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
		slope = {0, 28, 8},
		scale = {0.8, 1.3},
		height = {0.9, 1.2},
		align = 0.1,
		tilt = 2,
		bending = 1,
		sink = {0, 0.3},
		color = {surface = 0.2, variation = 0.15},
		cluster = {scale = 80, amount = 0.85},
	},
}

local function proto(class, path, overrides)
	local out = {model = root .. path .. ".cgf"}

	for k, v in pairs(classes[class]) do
		out[k] = v
	end

	for k, v in pairs(overrides) do
		out[k] = v
	end

	return out
end

presets.crysis_meadow = ScatterSet.New{
	Name = "crysis_meadow",
	Prototypes = {
		proto("ground_cover", "Ground_Plants/grass/nicegrass_green_S", {density = 0.35}),
		proto("ground_cover", "Ground_Plants/grass/grass_b", {density = 0.3}),
		proto("ground_cover", "Ground_Plants/grass/grass_a", {density = 0.25}),
		proto(
			"ground_cover",
			"Ground_Plants/grass/nicegrass_green_L",
			{density = 0.12, cluster = {scale = 11, amount = 0.8}}
		),
		proto(
			"ground_cover",
			"Ground_Plants/grass/nicegrass_drygreen_M",
			{density = 0.08, cluster = {scale = 15, amount = 0.9}}
		),
		proto(
			"ground_cover",
			"Plants/jungle_grass/junglegrass_small_a",
			{density = 0.08, cluster = {scale = 9, amount = 0.8}}
		),
		proto(
			"ground_cover",
			"Ground_Plants/grass/grass_dry_small_a",
			{
				density = 0.06,
				cluster = {scale = 12, amount = 0.9},
				color = {surface = 0.2, tint = {DRY, DRY}, tint_amount = 0.3},
			}
		),
		proto("flower", "Ground_Plants/flower_fern/flower_fern_a", {density = 0.012}),
		proto(
			"flower",
			"Bushes/JungleBush/junglebush_deko_fl_yellow_a",
			{density = 0.006, scale = {0.6, 1}}
		),
		proto(
			"flower",
			"Bushes/JungleBush/junglebush_small_fl_white_a",
			{density = 0.006, scale = {0.5, 0.9}}
		),
		proto(
			"flower",
			"Bushes/JungleBush/junglebush_deko_fl_red_b",
			{density = 0.004, scale = {0.5, 0.9}}
		),
		proto(
			"ground_cover",
			"Rocks/pebbles/pebbles_a",
			{
				density = 0.05,
				layers = {0.5, 1, 1, 0.5},
				scale = {0.8, 1.6},
				height = {1, 1},
				align = 1,
				max_distance = 40,
				color = {surface = 0.1},
				cluster = {scale = 10, amount = 0.9},
				bending = 0,
			}
		),
		proto("rock", "Rocks/Forest_rocks/forest_rock_small_a", {density = 0.012}),
		proto("rock", "Rocks/Forest_rocks/forest_rock_small_b", {density = 0.01}),
		proto("rock", "Rocks/Forest_rocks/forest_rock_med_a", {density = 0.002}),
		proto(
			"bush",
			"Bushes/RoundLeafBush/Round_Leaf_Bush_small_bright_green",
			{density = 0.006}
		),
		proto("bush", "Bushes/Thinleafbush/thin_leaves_bush_small_a", {density = 0.006}),
		proto("bush", "Bushes/TallBush/Tall_Bush_a", {density = 0.002}),
		proto("tree", "Trees/Hill_Tree/hill_tree_small_bright_green", {density = 0.0008}),
		proto("tree", "Trees/Hill_Tree/hill_tree_small_grey_green", {density = 0.0005}),
		proto(
			"tree",
			"Trees/Thin_Leave_Tree/thin_leave_tree_small_bright_green",
			{density = 0.0004}
		),
	},
}
presets.crysis_forest = ScatterSet.New{
	Name = "crysis_forest",
	Prototypes = {
		proto("ground_cover", "Ground_Plants/ground_cover_fern/fern_a", {density = 0.1}),
		proto("ground_cover", "Ground_Plants/GrPl_Fern_Flat_Med_a", {density = 0.06}),
		proto(
			"ground_cover",
			"Ground_Plants/small_leaves/small_Leaves_flat_a",
			{density = 0.2, align = 1, tilt = 0}
		),
		proto(
			"ground_cover",
			"Ground_Plants/small_leaves/small_Leaves_yellow_flat_a",
			{density = 0.08, align = 1, tilt = 0}
		),
		proto(
			"ground_cover",
			"Ground_Plants/Forest_Ground_Patch_a",
			{
				density = 0.1,
				align = 1,
				tilt = 0,
				scale = {0.8, 1.6},
				cluster = {scale = 9, amount = 0.8},
			}
		),
		proto(
			"ground_cover",
			"Ground_Plants/Forest_Ground_Patch_leafs_a",
			{
				density = 0.1,
				align = 1,
				tilt = 0,
				scale = {0.8, 1.6},
				cluster = {scale = 12, amount = 0.8},
			}
		),
		proto(
			"ground_cover",
			"Ground_Plants/moss/moss_a",
			{density = 0.04, layers = {1, 1, 1, 0}, cluster = {scale = 8, amount = 0.9}}
		),
		proto(
			"ground_cover",
			"Ground_Plants/mushrooms/mushroom_group_a",
			{
				density = 0.01,
				scale = {0.7, 1.3},
				max_distance = 35,
				cluster = {scale = 6, amount = 0.95},
			}
		),
		proto(
			"ground_cover",
			"Trees/Branches/Forest_Ground_Branches_1_a",
			{
				density = 0.02,
				align = 1,
				tilt = 0,
				bending = 0,
				cluster = {scale = 10, amount = 0.7},
			}
		),
		proto("bush", "Bushes/GreenFernBush/Green_Fern_Bush_a", {density = 0.006}),
		proto("bush", "Bushes/Groundfernbush/Ground_Fern_Bush_med_a", {density = 0.006}),
		proto("bush", "Bushes/Thinleafbush/thin_leaves_bush_small_b", {density = 0.004}),
		proto(
			"rock",
			"Rocks/Mossy_Rocks/Mossy_Rocks_small_a",
			{density = 0.03, scale = {0.8, 1.8}}
		),
		proto("rock", "Rocks/Forest_rocks/forest_rock_small_a", {density = 0.01}),
		proto("rock", "Rocks/Forest_rocks/forest_rock_med_b_withgreen", {density = 0.003}),
		proto(
			"rock",
			"Rocks/Forest_rocks/forest_rock_big_a_withgreen",
			{density = 0.0004, scale = {0.5, 1}}
		),
		proto(
			"tree",
			"Trees/Thin_Leave_Tree/thin_leave_tree_small_bright_green",
			{density = 0.0016}
		),
		proto(
			"tree",
			"Trees/Thin_Leave_Tree/thin_leave_tree_small_grey_green",
			{density = 0.0012}
		),
		proto("tree", "Trees/Hill_Tree/hill_tree_small_yellow_green", {density = 0.0008}),
		proto("tree", "Trees/Twisted_Tree/twisted_tree_a", {density = 0.0004}),
	},
}

local function clustered(target, amount)
	return target / (1 - 0.5 * amount)
end

local function jungle(class, path, target, cluster_amount, cluster_scale, overrides)
	local out = {
		density = clustered(target, cluster_amount),
		cluster = {scale = cluster_scale, amount = cluster_amount},
	}

	for k, v in pairs(overrides or {}) do
		out[k] = v
	end

	return proto(class, path, out)
end

local CLIFF = {scale = {0.8, 1.8}, slope = {15, 80, 10}, align = 0.8}
local BRANCH = {scale = {1, 2}, align = 1, tilt = 0, bending = 0, max_distance = 80}
local PALM = {scale = {0.8, 1.3}, layers = {1, 0.4, 0, 0.5}, altitude = {0.8, 1e9, 1.5}}
local JUNGLE_TREE = {scale = {0.8, 1.2}}
local HILL_TREE = {scale = {0.7, 1.3}}
local JUNGLE_ROCK = {scale = {1.2, 3.7}, height = {0.8, 1.2}}
presets.crysis_jungle = ScatterSet.New{
	Name = "crysis_jungle",
	Prototypes = {
		jungle(
			"ground_cover",
			"Ground_Plants/grass/bigpatch_medium",
			0.0075,
			0.9,
			40,
			{
				scale = {0.75, 1.05},
				height = {0.9, 1.1},
				max_distance = 130,
				full_density_distance = 60,
				distance_scale = 0.3,
				layers = {1, 0.5, 0, 0},
			}
		),
		jungle(
			"ground_cover",
			"Ground_Plants/small_leaves/small_Leaves_bunch_big_a",
			0.0056,
			0.9,
			35,
			{scale = {0.7, 1.2}, align = 1, tilt = 0, max_distance = 90}
		),
		jungle("ground_cover", "Plants/jungle_grass/junglegrass_med_a", 0.004, 0.9, 25),
		jungle("ground_cover", "Plants/jungle_grass/junglegrass_big_a", 0.0015, 0.9, 30),
		jungle("ground_cover", "Ground_Plants/flower_fern/flower_fern_b", 0.001, 0.9, 30),
		jungle(
			"ground_cover",
			"Trees/Branches/Forest_Ground_Branches_1_h",
			0.0005,
			0.9,
			40,
			BRANCH
		),
		jungle(
			"ground_cover",
			"Trees/Branches/Forest_Ground_Branches_1_e",
			0.0005,
			0.9,
			40,
			BRANCH
		),
		jungle(
			"ground_cover",
			"Trees/Branches/Forest_Ground_Branches_1_g",
			0.0005,
			0.9,
			40,
			BRANCH
		),
		jungle(
			"bush",
			"Bushes/RoundLeafBush/Round_Leaf_Bush_small_bright_green",
			0.00086,
			0.8,
			30
		),
		jungle("bush", "Bushes/RoundLeafBush/Round_Leaf_Bush_med_bright_green", 0.00071, 0.8, 30),
		jungle("bush", "Bushes/RoundLeafBush/Round_Leaf_Bush_med_yellow", 0.00107, 0.8, 30),
		jungle("bush", "Bushes/RoundLeafBush/Round_Leaf_Bush_small_grey_green", 0.00058, 0.8, 30),
		jungle("bush", "Bushes/RoundLeafBush/Round_Leaf_Bush_big_yellow", 0.00136, 0.8, 30),
		jungle("bush", "Bushes/JungleBush/junglebush_big_a", 0.00148, 0.8, 30),
		jungle("bush", "Bushes/JungleBush/junglebush_big_c", 0.00075, 0.8, 30),
		jungle("bush", "Bushes/Groundfernbush/Ground_Fern_Bush_big_a", 0.00115, 0.8, 30),
		jungle("bush", "Bushes/GreenFernBush/Green_Fern_Bush_c", 0.00038, 0.8, 30),
		jungle("bush", "Plants/big_leave_plant/big_leave_plant_med_a", 0.00038, 0.8, 30),
		jungle("bush", "Bushes/CliffBush/cliff_bush_yellow_mini", 0.00045, 0.8, 30, CLIFF),
		jungle("bush", "Bushes/CliffBush/cliff_bush_grey_mini", 0.0004, 0.8, 30, CLIFF),
		jungle("bush", "Bushes/CliffBush/cliff_bush_green_mini", 0.00036, 0.8, 30, CLIFF),
		jungle("tree", "Trees/Palm_Tree/Palm_Tree_Large_d", 0.00113, 0.6, 60, PALM),
		jungle("tree", "Trees/Palm_Tree/Palm_Tree_large_c", 0.00053, 0.6, 60, PALM),
		jungle("tree", "Trees/Palm_Tree/Palm_Tree_large_b", 0.00048, 0.6, 60, PALM),
		jungle("tree", "Trees/Palm_Tree/Palm_Tree_large_a", 0.00032, 0.6, 60, PALM),
		jungle("tree", "Trees/Palm_Tree/Palm_Tree_Large_f", 0.00032, 0.6, 60, PALM),
		jungle("tree", "Trees/Palm_Tree/Palm_Tree_Short_a", 0.00032, 0.6, 60, PALM),
		jungle(
			"tree",
			"Trees/Jungle_Tree_Thin/Jungle_Tree_Thin_d",
			0.00043,
			0.7,
			60,
			JUNGLE_TREE
		),
		jungle(
			"tree",
			"Trees/Jungle_Tree_Thin/Jungle_Tree_Thin_b",
			0.00035,
			0.7,
			60,
			JUNGLE_TREE
		),
		jungle(
			"tree",
			"Trees/Jungle_Tree_Thin/Jungle_Tree_Thin_g",
			0.00031,
			0.7,
			60,
			JUNGLE_TREE
		),
		jungle(
			"tree",
			"Trees/Jungle_Tree_Thin/Jungle_Tree_Thin_e",
			0.00029,
			0.7,
			60,
			JUNGLE_TREE
		),
		jungle(
			"tree",
			"Trees/Hill_Tree/hill_tree_small_bright_green",
			0.00066,
			0.8,
			70,
			HILL_TREE
		),
		jungle("tree", "Trees/Hill_Tree/hill_tree_small_grey_green", 0.00064, 0.8, 70, HILL_TREE),
		jungle(
			"tree",
			"Trees/Hill_Tree/hill_tree_small_yellow_green",
			0.00063,
			0.8,
			70,
			HILL_TREE
		),
		jungle("rock", "Rocks/Jungle_Rocks/Jungle_rock_a", 0.00144, 0.8, 50, JUNGLE_ROCK),
		jungle("rock", "Rocks/Jungle_Rocks/Jungle_rock_b", 0.00089, 0.8, 50, JUNGLE_ROCK),
		jungle("rock", "Rocks/Jungle_Rocks/Jungle_rock_c", 0.0004, 0.8, 50, JUNGLE_ROCK),
	},
}
presets.crysis_rocky = ScatterSet.New{
	Name = "crysis_rocky",
	Prototypes = {
		proto(
			"ground_cover",
			"Ground_Plants/grass/grass_dry_small_a",
			{
				density = 0.12,
				layers = {1, 0.6, 0.1, 0},
				color = {surface = 0.2, tint = {DRY, DRY}, tint_amount = 0.6},
			}
		),
		proto(
			"ground_cover",
			"Ground_Plants/grass/grass_dry_big_a",
			{
				density = 0.05,
				layers = {1, 0.6, 0.1, 0},
				color = {surface = 0.2, tint = {DRY, DRY}, tint_amount = 0.6},
			}
		),
		proto(
			"ground_cover",
			"Ground_Plants/scrub/scrub_a",
			{density = 0.02, layers = {1, 1, 0.2, 0}, cluster = {scale = 12, amount = 0.9}}
		),
		proto(
			"ground_cover",
			"Ground_Plants/scrub/scrub_b",
			{density = 0.012, layers = {1, 1, 0.2, 0}, cluster = {scale = 12, amount = 0.9}}
		),
		proto(
			"ground_cover",
			"Rocks/pebbles/pebbles_b",
			{
				density = 0.08,
				layers = {0.3, 1, 1, 0.5},
				scale = {0.8, 1.6},
				height = {1, 1},
				align = 1,
				max_distance = 45,
				bending = 0,
				color = {surface = 0.1},
			}
		),
		proto(
			"rock",
			"Rocks/Mossy_Rocks/Mossy_Rocks_small_b",
			{density = 0.05, scale = {0.8, 2}}
		),
		proto("rock", "Rocks/Forest_rocks/forest_rock_small_b", {density = 0.03}),
		proto("rock", "Rocks/Forest_rocks/forest_rock_med_a", {density = 0.012}),
		proto("rock", "Rocks/Jungle_Rocks/Jungle_rock_c", {density = 0.01}),
		proto(
			"rock",
			"Rocks/Cliff_Rocks/cliff_rock_a_small",
			{density = 0.004, layers = {0.2, 1, 1, 0.5}}
		),
		proto(
			"rock",
			"Rocks/Cliff_Rocks/cliff_rock_b_small",
			{density = 0.003, layers = {0.2, 1, 1, 0.5}}
		),
		proto(
			"rock",
			"Rocks/Forest_rocks/forest_rock_big_b",
			{
				density = 0.0008,
				layers = {0.2, 1, 1, 0.5},
				scale = {0.5, 1.1},
				slope = {0, 80, 10},
			}
		),
		proto(
			"rock",
			"Rocks/Cliff_Rocks/cliff_rock_a_med",
			{
				density = 0.0002,
				layers = {0, 0.5, 1, 0.5},
				scale = {0.4, 0.8},
				slope = {0, 85, 10},
				max_distance = 400,
			}
		),
	},
}
return presets
