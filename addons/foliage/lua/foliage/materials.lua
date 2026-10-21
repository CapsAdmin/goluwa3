local Color = import("goluwa/structs/color.lua")
local foliage = import("lua/foliage/foliage.lua")
local add = foliage.AddMaterial
local BARK = {
	MetallicMultiplier = 0,
	SpecularMultiplier = 0.6,
	Bending = 1,
	DetailBending = "leaves",
	BendDetailFrequency = 1,
}
local SMALL = {
	Bending = 3,
	DetailBending = "grass",
	BendDetailBranchAmplitude = 0.03,
	BendDetailLeafAmplitude = 0.05,
	BendDetailPhase = 1,
	BendDetailFrequency = 3,
}
local STONE = {MetallicMultiplier = 0, SpecularMultiplier = 0.7}

local function leaves(extra)
	local out = {
		MetallicMultiplier = 0,
		SpecularMultiplier = 0.6,
		AlphaTest = true,
		DoubleSided = true,
		BentNormals = true,
		DiffuseTransmission = 0.45,
		TransmissionColor = Color(0.85, 1.1, 0.45, 1),
		TransmissionScattering = 0.6,
		Bending = 1,
		DetailBending = "leaves",
		BendDetailPhase = 1,
		BendDetailFrequency = 1,
	}

	for key, value in pairs(extra or {}) do
		out[key] = value
	end

	return out
end

local function merge(a, b)
	local out = {}

	for key, value in pairs(a) do
		out[key] = value
	end

	for key, value in pairs(b) do
		out[key] = value
	end

	return out
end

local function bark(config)
	return {
		textures = {
			albedo = {"bark", config},
			normal = {"bark", config},
			roughness = {"bark", config},
		},
		material = BARK,
	}
end

add(
	"oak_bark",
	bark{
		seed = 11,
		style = 0,
		color_crack = {0.09, 0.08, 0.06},
		color_bark = {0.3, 0.27, 0.23},
		color_ridge = {0.47, 0.44, 0.39},
	}
)
add(
	"pine_bark",
	bark{
		seed = 12,
		style = 1,
		plates_u = 6,
		plates_v = 3,
		color_crack = {0.08, 0.05, 0.04},
		color_bark = {0.45, 0.24, 0.13},
		color_ridge = {0.44, 0.38, 0.33},
		lichen = 0.1,
	}
)
add(
	"birch_bark",
	bark{
		seed = 13,
		style = 2,
		color_bark = {0.86, 0.85, 0.8},
		color_ridge = {0.82, 0.72, 0.64},
		color_crack = {0.08, 0.07, 0.07},
		lichen = 0,
		roughness = 0.7,
	}
)
add(
	"palm_bark",
	bark{
		seed = 14,
		style = 3,
		rings = 16,
		color_crack = {0.16, 0.13, 0.1},
		color_bark = {0.42, 0.37, 0.3},
		color_ridge = {0.55, 0.51, 0.45},
		lichen = 0,
	}
)
add(
	"willow_bark",
	bark{
		seed = 15,
		style = 0,
		plates_u = 12,
		plates_v = 3,
		crack_width = 0.28,
		color_crack = {0.1, 0.09, 0.08},
		color_bark = {0.33, 0.31, 0.27},
		color_ridge = {0.45, 0.43, 0.39},
	}
)
add(
	"dead_bark",
	bark{
		seed = 16,
		style = 0,
		plates_u = 10,
		plates_v = 2,
		crack_width = 0.12,
		color_crack = {0.18, 0.16, 0.14},
		color_bark = {0.52, 0.5, 0.47},
		color_ridge = {0.66, 0.64, 0.6},
		lichen = 0.45,
		color_lichen = {0.55, 0.62, 0.45},
	}
)
add(
	"twig_bark",
	bark{
		seed = 17,
		style = 4,
		color_bark = {0.3, 0.24, 0.18},
		color_ridge = {0.4, 0.33, 0.25},
		color_crack = {0.15, 0.11, 0.08},
		lichen = 0,
	}
)

do
	local shape = {
		seed = 21,
		lobes = 4.5,
		lobe_depth = 0.55,
		shape_base = 0.9,
		shape_tip = 0.45,
		leaf_width = 0.55,
		leaf_count = 6,
		leaf_length = 0.4,
		petiole = 0.02,
		veins = 5,
	}
	add(
		"oak_leaves",
		{
			textures = {
				albedo = {
					"leaves",
					merge(shape, {color_dark = {0.1, 0.2, 0.05}, color_light = {0.25, 0.38, 0.09}}),
				},
				normal = {"leaves", shape},
				roughness = {"leaves", shape},
				transmission = {"leaves", shape},
			},
			material = leaves(),
		}
	)
end

do
	local shape = {
		seed = 22,
		leaf_count = 9,
		leaf_length = 0.26,
		leaf_width = 0.62,
		shape_base = 0.45,
		shape_tip = 0.75,
		teeth = 14,
		serration = 0.12,
		petiole = 0.06,
		twig_width = 0.008,
		leaf_angle = 0.9,
		twig_bend = 0.25,
	}
	add(
		"birch_leaves",
		{
			textures = {
				albedo = {
					"leaves",
					merge(
						shape,
						{
							color_dark = {0.2, 0.36, 0.08},
							color_light = {0.42, 0.56, 0.14},
							color_twig = {0.3, 0.2, 0.15},
							variation = 0.1,
						}
					),
				},
				normal = {"leaves", shape},
				roughness = {"leaves", shape},
				transmission = {"leaves", shape},
			},
			material = leaves{TransmissionColor = Color(0.9, 1.1, 0.4, 1), DiffuseTransmission = 0.5},
		}
	)
end

do
	local shape = {
		seed = 23,
		leaf_count = 14,
		leaf_length = 0.3,
		leaf_width = 0.17,
		shape_base = 0.5,
		shape_tip = 1.2,
		leaf_angle = 0.35,
		leaf_angle_variation = 0.15,
		twig_length = 1,
		twig_width = 0.006,
		twig_bend = 0.08,
		petiole = 0.01,
		veins = 0,
		curl = 0.25,
	}
	add(
		"willow_leaves",
		{
			textures = {
				albedo = {
					"leaves",
					merge(
						shape,
						{
							color_dark = {0.2, 0.32, 0.1},
							color_light = {0.4, 0.5, 0.2},
							color_twig = {0.45, 0.38, 0.18},
							color_vein = {0.55, 0.6, 0.35},
							variation = 0.1,
						}
					),
				},
				normal = {"leaves", shape},
				roughness = {"leaves", shape},
				transmission = {"leaves", shape},
			},
			material = leaves{TransmissionColor = Color(0.9, 1.1, 0.5, 1)},
		}
	)
end

add(
	"pine_needles",
	{
		textures = {
			albedo = {"needles", {seed = 24}},
			normal = {"needles", {seed = 24}},
			roughness = {"needles", {seed = 24}},
		},
		material = leaves{
			DiffuseTransmission = 0.25,
			TransmissionColor = Color(0.8, 1.1, 0.6, 1),
			TransmissionScattering = 0.4,
		},
	}
)
add(
	"palm_frond",
	{
		textures = {
			albedo = {"frond", {seed = 25}},
			normal = {"frond", {seed = 25}},
			roughness = {"frond", {seed = 25}},
		},
		material = leaves{DiffuseTransmission = 0.4},
	}
)
add(
	"palm_frond_dry",
	{
		textures = {
			albedo = {
				"frond",
				{
					seed = 26,
					color_dark = {0.35, 0.26, 0.14},
					color_light = {0.55, 0.43, 0.25},
					color_rachis = {0.5, 0.42, 0.28},
					color_tip = {0.4, 0.3, 0.18},
					leaflet_width = 0.008,
				},
			},
			normal = {"frond", {seed = 26, leaflet_width = 0.008}},
			roughness = {"frond", {seed = 26, leaflet_width = 0.008}},
		},
		material = leaves{DiffuseTransmission = 0.2, TransmissionColor = Color(1.1, 0.95, 0.6, 1)},
	}
)

do
	local shape = {
		seed = 27,
		leaflets = 26,
		leaflet_length = 0.2,
		leaflet_width = 0.022,
		leaflet_slope = 0.35,
		droop = 0.2,
		lobes = 7,
		lobe_depth = 0.5,
		frond_width = 0.4,
		base_gap = 0.12,
		rachis_width = 0.006,
		tip_dry = 0.1,
	}
	add(
		"fern_frond",
		{
			textures = {
				albedo = {
					"frond",
					merge(
						shape,
						{
							color_dark = {0.1, 0.25, 0.05},
							color_light = {0.25, 0.45, 0.1},
							color_rachis = {0.3, 0.38, 0.12},
						}
					),
				},
				normal = {"frond", shape},
				roughness = {"frond", shape},
			},
			material = leaves{
				DiffuseTransmission = 0.5,
				BendDetailLeafAmplitude = 0.03,
				BendDetailBranchAmplitude = 0.1,
			},
		}
	)
end

do
	local shape = {
		seed = 28,
		leaf_count = 8,
		leaf_length = 0.3,
		leaf_width = 0.75,
		shape_base = 0.55,
		shape_tip = 0.6,
		leaf_angle = 1.0,
		petiole = 0.03,
		twig_bend = 0.3,
	}
	add(
		"bush_leaves",
		{
			textures = {
				albedo = {
					"leaves",
					merge(
						shape,
						{
							color_dark = {0.07, 0.18, 0.05},
							color_light = {0.2, 0.35, 0.08},
							color_variation = {0.3, 0.36, 0.1},
							variation = 0.1,
						}
					),
				},
				normal = {"leaves", shape},
				roughness = {"leaves", shape},
				transmission = {"leaves", shape},
			},
			material = leaves{DiffuseTransmission = 0.35, RoughnessMultiplier = 0.8},
		}
	)
	local berries = merge(shape, {seed = 29, berries = 7})
	add(
		"berry_leaves",
		{
			textures = {
				albedo = {
					"leaves",
					merge(
						berries,
						{
							color_dark = {0.08, 0.2, 0.06},
							color_light = {0.22, 0.36, 0.1},
							color_variation = {0.3, 0.36, 0.1},
							variation = 0.05,
						}
					),
				},
				normal = {"leaves", berries},
				roughness = {"leaves", berries},
			},
			material = leaves{DiffuseTransmission = 0.35},
		}
	)
end

do
	local shape = {
		seed = 30,
		single = 1,
		shape_base = 0.6,
		shape_tip = 0.7,
		leaf_width = 0.6,
		lobes = 3.5,
		lobe_depth = 0.35,
	}
	add(
		"litter_leaves",
		{
			textures = {
				albedo = {
					"leaves",
					merge(
						shape,
						{
							color_dark = {0.27, 0.17, 0.09},
							color_light = {0.46, 0.31, 0.15},
							color_variation = {0.52, 0.42, 0.18},
							color_vein = {0.42, 0.32, 0.18},
							variation = 0.4,
							brightness_variation = 0.3,
						}
					),
				},
				normal = {"leaves", shape},
				roughness = {"leaves", shape},
			},
			material = leaves{
				DiffuseTransmission = 0.15,
				TransmissionColor = Color(1.1, 0.9, 0.5, 1),
				Bending = 0,
				DetailBending = "none",
			},
		}
	)
end

local function grass(seed, colors, extra)
	local config = merge({seed = seed}, colors)
	return {
		textures = {
			albedo = {"blade", config},
			normal = {"blade", {seed = seed}},
			roughness = {"blade", config},
		},
		material = merge(
			merge(
				{
					MetallicMultiplier = 0,
					SpecularMultiplier = 0.5,
					DoubleSided = true,
					DiffuseTransmission = 0.45,
					TransmissionColor = Color(0.9, 1.07, 0.55, 1),
					TransmissionScattering = 0.5,
				},
				SMALL
			),
			extra or {}
		),
	}
end

add(
	"grass_lawn",
	grass(
		31,
		{
			color_root = {0.2, 0.3, 0.1},
			color_mid = {0.18, 0.38, 0.07},
			color_tip = {0.3, 0.48, 0.1},
			dry = 0,
			dry_tips = 0.1,
		}
	)
)
add("grass_meadow", grass(32, {dry = 0.15, dry_tips = 0.25}))
add(
	"grass_wild",
	grass(
		33,
		{
			color_mid = {0.3, 0.42, 0.12},
			color_tip = {0.48, 0.52, 0.2},
			dry = 0.3,
			dry_tips = 0.4,
		}
	)
)
add(
	"grass_dry",
	grass(
		34,
		{
			color_root = {0.4, 0.36, 0.22},
			color_mid = {0.62, 0.54, 0.3},
			color_tip = {0.75, 0.66, 0.42},
			color_dry = {0.7, 0.6, 0.38},
			dry = 0.4,
			dry_tips = 0.5,
		},
		{DiffuseTransmission = 0.3, TransmissionColor = Color(1.1, 0.95, 0.6, 1)}
	)
)
add(
	"grass_sedge",
	grass(
		35,
		{
			color_root = {0.25, 0.3, 0.15},
			color_mid = {0.14, 0.3, 0.1},
			color_tip = {0.25, 0.38, 0.14},
			dry = 0.05,
			dry_tips = 0.2,
		}
	)
)
add(
	"grass_reed",
	grass(
		37,
		{
			color_root = {0.3, 0.32, 0.18},
			color_mid = {0.2, 0.33, 0.12},
			color_tip = {0.32, 0.4, 0.16},
			dry = 0.1,
			dry_tips = 0.25,
		},
		{BendDetailFrequency = 0.8, BendDetailLeafAmplitude = 0.08}
	)
)
add(
	"plant_stem",
	grass(
		36,
		{
			color_root = {0.2, 0.3, 0.1},
			color_mid = {0.25, 0.4, 0.12},
			color_tip = {0.3, 0.45, 0.15},
			dry = 0,
			dry_tips = 0,
			variation = 0.1,
		}
	)
)

local function cutout(kind, config, extra)
	return {
		textures = {albedo = {kind, config}, normal = {kind, config}, roughness = {kind, config}},
		material = leaves(extra),
	}
end

add(
	"seed_oat",
	cutout(
		"seed_head",
		{seed = 41, style = 0},
		merge(SMALL, {DiffuseTransmission = 0.3, TransmissionColor = Color(1.1, 1, 0.6, 1)})
	)
)
add(
	"seed_timothy",
	cutout(
		"seed_head",
		{
			seed = 42,
			style = 1,
			spikelets = 28,
			spikelet_length = 0.05,
			spikelet_width = 0.03,
			head_start = 0.6,
			color_seed = {0.55, 0.58, 0.35},
			color_seed_tip = {0.7, 0.68, 0.45},
		},
		merge(SMALL, {DiffuseTransmission = 0.3})
	)
)
add(
	"seed_plume",
	cutout(
		"seed_head",
		{
			seed = 43,
			style = 2,
			spikelets = 40,
			spikelet_length = 0.12,
			spikelet_width = 0.03,
			head_start = 0.55,
			color_seed = {0.75, 0.68, 0.55},
			color_seed_tip = {0.92, 0.88, 0.8},
		},
		merge(SMALL, {DiffuseTransmission = 0.5, TransmissionColor = Color(1.1, 1, 0.8, 1)})
	)
)
add(
	"cattail",
	{
		textures = {
			albedo = {
				"bark",
				{
					seed = 44,
					style = 4,
					color_bark = {0.3, 0.18, 0.1},
					color_ridge = {0.38, 0.24, 0.14},
					color_crack = {0.2, 0.12, 0.07},
					lichen = 0,
				},
			},
			normal = {"bark", {seed = 44, style = 4, lichen = 0}},
			roughness = {"bark", {seed = 44, style = 4, lichen = 0}},
		},
		material = merge(BARK, {DetailBending = "grass", RoughnessMultiplier = 1}),
	}
)
local FLOWER = merge(
	SMALL,
	{
		DiffuseTransmission = 0.5,
		TransmissionColor = Color(1, 1, 1, 1),
		TransmissionScattering = 0.3,
	}
)
add("flower_daisy", cutout("flower", {seed = 51}, FLOWER))
add(
	"flower_poppy",
	cutout(
		"flower",
		{
			seed = 52,
			petals = 5,
			petal_width = 0.75,
			petal_length = 0.46,
			petal_tip = 0.45,
			petal_cup = 0.5,
			center = 0.1,
			color_petal = {0.85, 0.08, 0.05},
			color_petal_base = {0.75, 0.05, 0.03},
			blotch = 1,
			color_center = {0.12, 0.14, 0.08},
		},
		merge(FLOWER, {TransmissionColor = Color(1.4, 0.6, 0.5, 1)})
	)
)
add(
	"flower_cornflower",
	cutout(
		"flower",
		{
			seed = 53,
			petals = 9,
			petal_width = 0.4,
			petal_length = 0.45,
			petal_tip = 0.2,
			petal_notch = 0.6,
			center = 0.16,
			color_petal = {0.25, 0.4, 0.9},
			color_petal_base = {0.35, 0.3, 0.7},
			color_center = {0.25, 0.15, 0.45},
		},
		merge(FLOWER, {TransmissionColor = Color(0.7, 0.85, 1.3, 1)})
	)
)
add(
	"flower_buttercup",
	cutout(
		"flower",
		{
			seed = 54,
			petals = 5,
			petal_width = 0.55,
			petal_length = 0.42,
			petal_tip = 0.5,
			petal_cup = 0.6,
			center = 0.12,
			color_petal = {1, 0.85, 0.08},
			color_petal_base = {0.95, 0.75, 0.05},
			color_center = {0.75, 0.65, 0.1},
			veins = 0.03,
		},
		merge(
			FLOWER,
			{
				RoughnessMultiplier = 0.4,
				SpecularMultiplier = 1,
				TransmissionColor = Color(1.2, 1.1, 0.4, 1),
			}
		)
	)
)
add(
	"flower_lupine",
	cutout(
		"flower",
		{
			seed = 55,
			style = 1,
			petals = 42,
			petal_length = 0.12,
			color_petal = {0.45, 0.32, 0.85},
			color_petal_base = {0.8, 0.78, 0.95},
			color_center = {0.3, 0.42, 0.18},
		},
		merge(FLOWER, {TransmissionColor = Color(0.95, 0.8, 1.3, 1)})
	)
)

local function rock(config)
	return {
		textures = {
			albedo = {"rock", config},
			normal = {"rock", config},
			roughness = {"rock", config},
		},
		material = STONE,
	}
end

add("rock_granite", rock{seed = 61, style = 0})
add(
	"rock_sandstone",
	rock{
		seed = 62,
		style = 1,
		color_base = {0.58, 0.5, 0.42},
		color_light = {0.74, 0.67, 0.58},
		color_dark = {0.33, 0.27, 0.21},
		color_warm = {0.6, 0.46, 0.34},
		speckle = 0.15,
		cracks = 0.3,
		lichen = 0.15,
	}
)
add(
	"rock_basalt",
	rock{
		seed = 63,
		style = 2,
		color_base = {0.22, 0.22, 0.23},
		color_dark = {0.08, 0.08, 0.09},
		color_light = {0.4, 0.4, 0.4},
		color_warm = {0.28, 0.22, 0.18},
		speckle = 0.15,
		grain = 25,
		cracks = 0.8,
		lichen = 0.2,
		roughness = 0.75,
	}
)
add(
	"rock_mossy",
	rock{seed = 64, style = 0, moss = 1, moss_level = 0.25, lichen = 0.15}
)
add(
	"rock_river",
	rock{
		seed = 65,
		style = 3,
		color_base = {0.5, 0.48, 0.45},
		color_dark = {0.3, 0.29, 0.28},
		color_light = {0.7, 0.68, 0.64},
		color_warm = {0.55, 0.47, 0.4},
		speckle = 0.2,
		cracks = 0,
		lichen = 0,
		roughness = 0.6,
	}
)
add(
	"mushroom_amanita",
	{
		textures = {
			albedo = {"mushroom", {seed = 71, style = 0}},
			normal = {"mushroom", {seed = 71, style = 0}},
			roughness = {"mushroom", {seed = 71, style = 0}},
		},
		material = STONE,
	}
)
add(
	"mushroom_bolete",
	{
		textures = {
			albedo = {
				"mushroom",
				{
					seed = 72,
					style = 1,
					color_cap = {0.42, 0.25, 0.12},
					color_rim = {0.55, 0.38, 0.2},
				},
			},
			normal = {"mushroom", {seed = 72, style = 1}},
			roughness = {"mushroom", {seed = 72, style = 1}},
		},
		material = merge(STONE, {RoughnessMultiplier = 0.8}),
	}
)
add(
	"mushroom_stem",
	{
		textures = {
			albedo = {
				"mushroom",
				{
					seed = 73,
					style = 2,
					color_cap = {0.85, 0.82, 0.74},
					color_rim = {0.7, 0.66, 0.58},
				},
			},
			normal = {"mushroom", {seed = 73, style = 2}},
			roughness = {"mushroom", {seed = 73, style = 2}},
		},
		material = STONE,
	}
)
add(
	"end_grain",
	{
		textures = {
			albedo = {"end_grain", {seed = 81}},
			normal = {"end_grain", {seed = 81}},
			roughness = {"end_grain", {seed = 81}},
		},
		material = STONE,
	}
)
add(
	"coconut",
	{
		textures = {
			albedo = {
				"bark",
				{
					seed = 82,
					style = 4,
					color_bark = {0.35, 0.3, 0.12},
					color_ridge = {0.45, 0.38, 0.15},
					color_crack = {0.2, 0.15, 0.08},
					lichen = 0,
				},
			},
			normal = {"bark", {seed = 82, style = 4, lichen = 0}},
			roughness = {"bark", {seed = 82, style = 4, lichen = 0}},
		},
		material = merge(STONE, {Bending = 1}),
	}
)
return foliage.materials
