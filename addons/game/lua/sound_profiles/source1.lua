local profile = {}

do
	local function range(path, first, last)
		local list = {last = 0}

		for i = first, last do
			list[#list + 1] = path .. i .. ".wav"
		end

		return list
	end

	local function list(...)
		return {last = 0, ...}
	end

	local function set(soft, hard, db)
		return {soft = soft, hard = hard, gain = 10 ^ ((db or 0) / 20)}
	end

	local SETS = {
		concrete = set(
			range("physics/concrete/concrete_impact_soft", 1, 3),
			range("physics/concrete/concrete_impact_hard", 1, 3)
		),
		concrete_block = set(
			range("physics/concrete/concrete_impact_soft", 1, 3),
			range("physics/concrete/concrete_block_impact_hard", 1, 3)
		),
		rock = set(
			range("physics/concrete/rock_impact_soft", 1, 3),
			range("physics/concrete/rock_impact_hard", 4, 6)
		),
		boulder = set(
			range("physics/concrete/rock_impact_hard", 1, 3),
			range("physics/concrete/boulder_impact_hard", 1, 4),
			2
		),
		dirt = set(
			range("physics/surfaces/sand_impact_bullet", 1, 4),
			range("physics/surfaces/sand_impact_bullet", 1, 4),
			-4
		),
		carpet = set(range("player/footsteps/sand", 1, 4), range("player/footsteps/sand", 1, 4), -6),
		metal = set(
			range("physics/metal/metal_solid_impact_soft", 1, 3),
			list(
				"physics/metal/metal_solid_impact_hard1.wav",
				"physics/metal/metal_solid_impact_hard4.wav",
				"physics/metal/metal_solid_impact_hard5.wav"
			),
			2
		),
		metal_box = set(
			range("physics/metal/metal_box_impact_soft", 1, 3),
			range("physics/metal/metal_box_impact_hard", 1, 3),
			2
		),
		metal_vent = set(
			range("physics/metal/metal_box_impact_soft", 1, 3),
			range("physics/metal/metal_sheet_impact_hard", 6, 8),
			2
		),
		metal_barrel = set(
			range("physics/metal/metal_barrel_impact_soft", 1, 4),
			range("physics/metal/metal_barrel_impact_hard", 1, 3),
			2
		),
		canister = set(
			range("physics/metal/metal_canister_impact_soft", 1, 3),
			range("physics/metal/metal_canister_impact_hard", 1, 3),
			2
		),
		computer = set(
			range("physics/metal/metal_computer_impact_soft", 1, 3),
			range("physics/metal/metal_computer_impact_hard", 1, 3)
		),
		metal_grate = set(
			range("physics/metal/metal_grate_impact_soft", 1, 3),
			range("physics/metal/metal_grate_impact_hard", 1, 3),
			2
		),
		chainlink = set(
			range("physics/metal/metal_chainlink_impact_soft", 1, 3),
			range("physics/metal/metal_chainlink_impact_hard", 1, 3),
			2
		),
		chain = set(
			range("physics/metal/chain_impact_soft", 1, 3),
			range("physics/metal/chain_impact_hard", 1, 2),
			2
		),
		grenade = set(
			range("physics/metal/metal_grenade_impact_soft", 1, 3),
			range("physics/metal/metal_grenade_impact_hard", 1, 3)
		),
		paintcan = set(
			range("physics/metal/paintcan_impact_soft", 1, 3),
			range("physics/metal/paintcan_impact_hard", 1, 3)
		),
		popcan = set(
			range("physics/metal/soda_can_impact_soft", 1, 3),
			range("physics/metal/soda_can_impact_hard", 1, 3)
		),
		weapon = set(
			range("physics/metal/weapon_impact_soft", 1, 3),
			range("physics/metal/weapon_impact_hard", 1, 3)
		),
		vehicle = set(
			range("vehicles/v8/vehicle_impact_medium", 1, 4),
			range("vehicles/v8/vehicle_impact_heavy", 1, 4),
			4
		),
		wood = set(
			list(
				"physics/wood/wood_plank_impact_soft1.wav",
				"physics/wood/wood_box_impact_soft1.wav",
				"physics/wood/wood_solid_impact_soft2.wav"
			),
			range("physics/wood/wood_box_impact_hard", 1, 3)
		),
		wood_solid = set(
			range("physics/wood/wood_solid_impact_soft", 1, 3),
			range("physics/wood/wood_solid_impact_hard", 1, 3)
		),
		wood_box = set(
			range("physics/wood/wood_box_impact_soft", 1, 3),
			range("physics/wood/wood_box_impact_hard", 4, 6)
		),
		wood_crate = set(
			range("physics/wood/wood_crate_impact_soft", 1, 3),
			list(
				"physics/wood/wood_crate_impact_hard4.wav",
				"physics/wood/wood_crate_impact_hard5.wav",
				"physics/wood/wood_panel_impact_hard1.wav"
			)
		),
		wood_furniture = set(
			range("physics/wood/wood_furniture_impact_soft", 1, 3),
			range("physics/wood/wood_box_impact_hard", 4, 6)
		),
		wood_panel = set(
			list(
				"physics/wood/wood_box_impact_soft1.wav",
				"physics/wood/wood_crate_impact_soft2.wav",
				"physics/wood/wood_box_impact_soft3.wav"
			),
			list(
				"physics/wood/wood_crate_impact_hard2.wav",
				"physics/wood/wood_crate_impact_hard3.wav",
				"physics/wood/wood_panel_impact_hard1.wav"
			)
		),
		wood_plank = set(
			range("physics/wood/wood_plank_impact_soft", 1, 3),
			range("physics/wood/wood_plank_impact_hard", 1, 5)
		),
		plastic = set(
			range("physics/plastic/plastic_box_impact_soft", 1, 4),
			range("physics/plastic/plastic_box_impact_hard", 1, 4),
			-2
		),
		plastic_barrel = set(
			range("physics/plastic/plastic_barrel_impact_soft", 1, 6),
			range("physics/plastic/plastic_barrel_impact_hard", 1, 4),
			-2
		),
		glass = set(
			range("physics/glass/glass_sheet_impact_soft", 1, 3),
			range("physics/glass/glass_sheet_impact_hard", 1, 3)
		),
		glass_bottle = set(
			range("physics/glass/glass_impact_soft", 1, 3),
			range("physics/glass/glass_bottle_impact_hard", 1, 3)
		),
		pottery = set(
			range("physics/glass/glass_impact_soft", 1, 3),
			range("physics/glass/glass_impact_hard", 1, 3)
		),
		cardboard = set(
			range("physics/cardboard/cardboard_box_impact_soft", 1, 7),
			range("physics/cardboard/cardboard_box_impact_hard", 1, 7),
			-4
		),
		paper_cup = set(
			range("physics/cardboard/cardboard_box_impact_soft", 1, 7),
			range("physics/cardboard/cardboard_cup_impact_hard", 1, 3),
			-4
		),
		drywall = set(
			range("physics/plaster/drywall_impact_soft", 1, 3),
			range("physics/plaster/drywall_impact_hard", 1, 3),
			-2
		),
		ceiling_tile = set(
			range("physics/plaster/ceiling_tile_impact_soft", 1, 3),
			range("physics/plaster/ceiling_tile_impact_hard", 1, 3),
			-2
		),
		rubber = set(
			range("physics/rubber/rubber_tire_impact_soft", 1, 3),
			range("physics/rubber/rubber_tire_impact_hard", 1, 3),
			-4
		),
		flesh = set(
			list(
				"physics/body/body_medium_impact_soft1.wav",
				"physics/body/body_medium_impact_soft2.wav",
				"physics/body/body_medium_impact_soft5.wav",
				"physics/body/body_medium_impact_soft6.wav",
				"physics/body/body_medium_impact_soft7.wav"
			),
			range("physics/body/body_medium_impact_hard", 1, 6),
			-2
		),
		bloody_flesh = set(
			list(
				"physics/body/body_medium_impact_soft1.wav",
				"physics/body/body_medium_impact_soft2.wav",
				"physics/body/body_medium_impact_soft5.wav",
				"physics/body/body_medium_impact_soft6.wav",
				"physics/body/body_medium_impact_soft7.wav"
			),
			range("physics/flesh/flesh_squishy_impact_hard", 1, 4),
			-2
		),
		squishy = set(
			range("physics/flesh/flesh_squishy_impact_hard", 1, 4),
			range("physics/flesh/flesh_squishy_impact_hard", 1, 4),
			-2
		),
		water = set(
			range("physics/surfaces/underwater_impact_bullet", 1, 3),
			range("ambient/water/water_splash", 1, 3)
		),
	}
	local SURFACES = {
		default = "concrete",
		concrete = "concrete",
		asphalt = "concrete",
		tile = "concrete",
		ice = "concrete",
		gmod_ice = "concrete",
		concrete_block = "concrete_block",
		rock = "rock",
		brick = "rock",
		stone = "rock",
		gravel = "rock",
		porcelain = "rock",
		boulder = "boulder",
		cavern_rock = "boulder",
		dirt = "dirt",
		grass = "dirt",
		sand = "dirt",
		antlionsand = "dirt",
		snow = "dirt",
		mud = "dirt",
		slime = "dirt",
		slipperyslime = "dirt",
		floatingstandable = "dirt",
		carpet = "carpet",
		metal = "metal",
		solidmetal = "metal",
		metalpanel = "metal",
		combine_metal = "metal",
		slipperymetal = "metal",
		metal_bouncy = "metal",
		ladder = "metal",
		gunship = "metal",
		strider = "metal",
		roller = "metal",
		metal_box = "metal_box",
		metalvent = "metal_vent",
		metal_barrel = "metal_barrel",
		floating_metal_barrel = "metal_barrel",
		canister = "canister",
		gm_torpedo = "canister",
		computer = "computer",
		metalgrate = "metal_grate",
		chainlink = "chainlink",
		chain = "chain",
		grenade = "grenade",
		paintcan = "paintcan",
		popcan = "popcan",
		weapon = "weapon",
		crowbar = "weapon",
		metalvehicle = "vehicle",
		jalopy = "vehicle",
		wood = "wood",
		wood_lowdensity = "wood",
		woodladder = "wood",
		hay = "wood",
		wood_solid = "wood_solid",
		foliage = "wood_solid",
		wood_box = "wood_box",
		wood_crate = "wood_crate",
		wood_furniture = "wood_furniture",
		wood_panel = "wood_panel",
		wood_plank = "wood_plank",
		plastic = "plastic",
		plastic_box = "plastic",
		item = "plastic",
		plastic_barrel = "plastic_barrel",
		glass = "glass",
		combine_glass = "glass",
		glassbottle = "glass_bottle",
		pottery = "pottery",
		cardboard = "cardboard",
		paper = "cardboard",
		papercup = "paper_cup",
		plaster = "drywall",
		ceiling_tile = "ceiling_tile",
		rubber = "rubber",
		rubbertire = "rubber",
		jeeptire = "rubber",
		jalopytire = "rubber",
		flesh = "flesh",
		alienflesh = "flesh",
		armorflesh = "flesh",
		antlion = "flesh",
		hunter = "flesh",
		player = "flesh",
		bloodyflesh = "bloody_flesh",
		zombieflesh = "bloody_flesh",
		watermelon = "squishy",
		water = "water",
		wade = "water",
	}
	local LOOPS = {
		concrete = {
			"physics/concrete/concrete_scrape_smooth_loop1.wav",
			"physics/concrete/rock_scrape_rough_loop1.wav",
		},
		concrete_block = {
			"physics/concrete/concrete_scrape_smooth_loop1.wav",
			"physics/concrete/concrete_block_scrape_rough_loop1.wav",
		},
		rock = {
			"physics/concrete/rock_scrape_rough_loop1.wav",
			"physics/concrete/rock_scrape_rough_loop1.wav",
		},
		boulder = {
			"physics/concrete/rock_scrape_rough_loop1.wav",
			"physics/concrete/concrete_block_scrape_rough_loop1.wav",
		},
		dirt = {
			"physics/cardboard/cardboard_box_scrape_rough_loop1.wav",
			"physics/cardboard/cardboard_box_scrape_rough_loop1.wav",
		},
		carpet = {
			"physics/flesh/flesh_scrape_rough_loop.wav",
			"physics/flesh/flesh_scrape_rough_loop.wav",
		},
		metal = {
			"physics/metal/metal_box_scrape_smooth_loop1.wav",
			"physics/metal/metal_box_scrape_rough_loop1.wav",
		},
		metal_box = {
			"physics/metal/metal_box_scrape_smooth_loop1.wav",
			"physics/metal/metal_box_scrape_rough_loop1.wav",
		},
		metal_vent = {
			"physics/metal/metal_box_scrape_smooth_loop1.wav",
			"physics/metal/metal_box_scrape_rough_loop2.wav",
		},
		metal_barrel = {
			"physics/metal/metal_box_scrape_smooth_loop1.wav",
			"physics/metal/metal_box_scrape_rough_loop1.wav",
			"physics/metal/canister_roll_loop1.wav",
		},
		canister = {
			"physics/metal/canister_scrape_smooth_loop1.wav",
			"physics/metal/canister_scrape_rough_loop1.wav",
			"physics/metal/canister_roll_loop1.wav",
		},
		computer = {
			"physics/metal/metal_box_scrape_smooth_loop1.wav",
			"physics/metal/metal_box_scrape_rough_loop1.wav",
		},
		metal_grate = {
			"physics/metal/metal_box_scrape_smooth_loop1.wav",
			"physics/metal/metal_box_scrape_rough_loop1.wav",
		},
		chainlink = {
			"physics/metal/metal_chainlink_scrape_rough_loop1.wav",
			"physics/metal/metal_chainlink_scrape_rough_loop1.wav",
		},
		chain = {
			"physics/metal/chain_scrape_rough_loop1.wav",
			"physics/metal/chain_scrape_rough_loop1.wav",
		},
		grenade = {
			"physics/metal/metal_grenade_scrape_smooth_loop1.wav",
			"physics/metal/metal_grenade_scrape_rough_loop1.wav",
			"physics/metal/metal_grenade_roll_loop1.wav",
		},
		paintcan = {
			"physics/plastic/plastic_box_scrape_smooth_loop2.wav",
			"physics/metal/soda_can_scrape_rough_loop1.wav",
			"physics/metal/paintcan_roll_loop1.wav",
		},
		popcan = {
			"physics/plastic/plastic_box_scrape_smooth_loop2.wav",
			"physics/metal/soda_can_scrape_rough_loop1.wav",
			"physics/metal/paintcan_roll_loop1.wav",
		},
		weapon = {
			"physics/plastic/plastic_box_scrape_smooth_loop2.wav",
			"physics/metal/soda_can_scrape_rough_loop1.wav",
		},
		vehicle = {
			"physics/metal/metal_box_scrape_smooth_loop1.wav",
			"physics/metal/metal_box_scrape_rough_loop1.wav",
		},
		wood = {
			"physics/wood/wood_plank_scrape_smooth_loop1.wav",
			"physics/wood/wood_solid_scrape_rough_loop1.wav",
		},
		wood_solid = {
			"physics/wood/wood_plank_scrape_smooth_loop1.wav",
			"physics/wood/wood_solid_scrape_rough_loop1.wav",
		},
		wood_box = {
			"physics/wood/wood_box_scrape_smooth_loop1.wav",
			"physics/wood/wood_box_scrape_rough_loop1.wav",
		},
		wood_crate = {
			"physics/wood/wood_box_scrape_smooth_loop1.wav",
			"physics/wood/wood_crate_scrape_rough_loop1.wav",
		},
		wood_furniture = {
			"physics/wood/wood_box_scrape_smooth_loop1.wav",
			"physics/wood/wood_box_scrape_rough_loop1.wav",
		},
		wood_panel = {
			"physics/wood/wood_box_scrape_smooth_loop1.wav",
			"physics/wood/wood_box_scrape_rough_loop1.wav",
		},
		wood_plank = {
			"physics/wood/wood_plank_scrape_smooth_loop1.wav",
			"physics/wood/wood_plank_scrape_rough_loop1.wav",
		},
		plastic = {
			"physics/plastic/plastic_box_scrape_smooth_loop2.wav",
			"physics/plastic/plastic_box_scrape_rough_loop1.wav",
		},
		plastic_barrel = {
			"physics/plastic/plastic_barrel_scrape_smooth_loop1.wav",
			"physics/plastic/plastic_barrel_scrape_rough_loop1.wav",
			"physics/plastic/plastic_barrel_roll_loop1.wav",
		},
		cardboard = {
			"physics/cardboard/cardboard_box_scrape_smooth_loop1.wav",
			"physics/cardboard/cardboard_box_scrape_rough_loop1.wav",
		},
		paper_cup = {
			"physics/cardboard/cardboard_box_scrape_smooth_loop1.wav",
			"physics/metal/soda_can_scrape_rough_loop1.wav",
		},
		drywall = {
			"physics/plaster/ceiling_tile_scrape_smooth_loop1.wav",
			"physics/plaster/ceiling_tile_scrape_smooth_loop1.wav",
		},
		ceiling_tile = {
			"physics/plaster/ceiling_tile_scrape_smooth_loop1.wav",
			"physics/plaster/ceiling_tile_scrape_smooth_loop1.wav",
		},
		rubber = {
			"physics/plastic/plastic_box_scrape_smooth_loop2.wav",
			"physics/cardboard/cardboard_box_scrape_rough_loop1.wav",
		},
		flesh = {
			"physics/body/body_medium_scrape_smooth_loop1.wav",
			"physics/body/body_medium_scrape_rough_loop1.wav",
		},
		bloody_flesh = {
			"physics/body/body_medium_scrape_smooth_loop1.wav",
			"physics/body/body_medium_scrape_rough_loop1.wav",
		},
		squishy = {
			"physics/body/body_medium_scrape_smooth_loop1.wav",
			"physics/body/body_medium_scrape_rough_loop1.wav",
		},
	}
	local HARDNESS = {
		concrete = 0.9,
		concrete_block = 0.9,
		rock = 0.9,
		boulder = 1,
		dirt = 0.05,
		carpet = 0.05,
		metal = 1,
		metal_box = 0.9,
		metal_vent = 0.8,
		metal_barrel = 0.8,
		canister = 0.8,
		computer = 0.8,
		metal_grate = 1,
		chainlink = 0.6,
		chain = 0.7,
		grenade = 1,
		paintcan = 0.8,
		popcan = 0.6,
		weapon = 1,
		vehicle = 0.9,
		wood = 0.5,
		wood_solid = 0.6,
		wood_box = 0.45,
		wood_crate = 0.45,
		wood_furniture = 0.5,
		wood_panel = 0.45,
		wood_plank = 0.5,
		plastic = 0.35,
		plastic_barrel = 0.35,
		glass = 0.9,
		glass_bottle = 0.9,
		pottery = 0.85,
		cardboard = 0.1,
		paper_cup = 0.1,
		drywall = 0.3,
		ceiling_tile = 0.2,
		rubber = 0.1,
		flesh = 0.1,
		bloody_flesh = 0.1,
		squishy = 0.05,
		water = 0,
	}

	for name, hardness in pairs(HARDNESS) do
		SETS[name].hardness = hardness
	end

	for name, loops in pairs(LOOPS) do
		local found = SETS[name]
		found.smooth, found.rough, found.roll = loops[1], loops[2], loops[3]
	end

	function profile.GetSurfaces()
		local list = {}

		for name in pairs(SETS) do
			local surface = name

			if SURFACES[name] ~= name then
				for key, set_name in pairs(SURFACES) do
					if set_name == name and (SURFACES[surface] ~= name or #key < #surface) then
						surface = key
					end
				end
			end

			list[#list + 1] = {Text = name, Value = surface}
		end

		table.sort(list, function(a, b)
			return a.Text < b.Text
		end)

		return list
	end

	local resolved = {}

	local function get_set(surface)
		local found = resolved[surface]

		if not found then
			found = SETS[SURFACES[surface] or SURFACES[surface:match("^[^_]+")] or SURFACES.default]
			resolved[surface] = found
		end

		return found
	end

	function profile.GetImpact(surface)
		return get_set(surface)
	end
end

do
	local LEVEL = -20
	profile.FOOTSTEP_GAIN = 10 ^ (LEVEL / 20)

	local function numbered(path, count, db)
		local set = {gain = 10 ^ ((LEVEL + (db or 0)) / 20), last = 0}

		for i = 1, count do
			set[i] = path .. i .. ".wav"
		end

		return set
	end

	local SETS = {
		concrete = numbered("player/footsteps/concrete", 4),
		dirt = numbered("player/footsteps/dirt", 4, -2),
		grass = numbered("player/footsteps/grass", 4, -3),
		gravel = numbered("player/footsteps/gravel", 4),
		sand = numbered("player/footsteps/sand", 4, -3),
		snow = numbered("player/footsteps/snow", 6, -4),
		ice = numbered("player/footsteps/ice", 4),
		mud = numbered("player/footsteps/mud", 4, -2),
		metal = numbered("player/footsteps/metal", 4, 3),
		metalgrate = numbered("player/footsteps/metalgrate", 4, 3),
		duct = numbered("player/footsteps/duct", 4, 3),
		chainlink = numbered("player/footsteps/chainlink", 4, 2),
		ladder = numbered("player/footsteps/ladder", 4, 3),
		tile = numbered("player/footsteps/tile", 4),
		wood = numbered("player/footsteps/wood", 4),
		woodpanel = numbered("player/footsteps/woodpanel", 4, 2),
		slosh = numbered("player/footsteps/slosh", 6),
		rubber = {"player/footsteps/rubber.wav", gain = 10 ^ ((LEVEL - 4) / 20), last = 0},
		wood_box = numbered("physics/wood/wood_box_footstep", 4, 2),
		metal_box = numbered("physics/metal/metal_box_footstep", 4, 3),
		drywall = numbered("physics/plaster/drywall_footstep", 4),
		ceiling_tile = numbered("physics/plaster/ceiling_tile_step", 4),
		glass = numbered("physics/glass/glass_sheet_step", 4),
		cardboard = numbered("physics/cardboard/cardboard_box_impact_soft", 4, -2),
		plastic = numbered("physics/plastic/plastic_box_impact_soft", 4, -2),
		plastic_barrel = numbered("physics/plastic/plastic_barrel_impact_soft", 4),
		weapon = numbered("physics/metal/weapon_footstep", 2),
		flesh = {
			"physics/flesh/flesh_impact_hard1.wav",
			"physics/flesh/flesh_impact_hard2.wav",
			"physics/body/body_medium_impact_soft3.wav",
			"physics/body/body_medium_impact_soft4.wav",
			gain = 10 ^ ((LEVEL - 4) / 20),
			last = 0,
		},
	}
	local SURFACES = {
		default = "concrete",
		concrete = "concrete",
		concrete_block = "concrete",
		brick = "concrete",
		rock = "concrete",
		boulder = "concrete",
		cavern_rock = "concrete",
		stone = "concrete",
		porcelain = "concrete",
		asphalt = "concrete",
		dirt = "dirt",
		carpet = "dirt",
		floatingstandable = "dirt",
		grass = "grass",
		hay = "grass",
		foliage = "grass",
		gravel = "gravel",
		sand = "sand",
		antlionsand = "sand",
		snow = "snow",
		ice = "ice",
		gmod_ice = "ice",
		mud = "mud",
		slime = "mud",
		slipperyslime = "mud",
		metal = "metal",
		solidmetal = "metal",
		metalpanel = "metal",
		metalvehicle = "metal",
		combine_metal = "metal",
		canister = "metal",
		slipperymetal = "metal",
		metal_box = "metal_box",
		metal_barrel = "metal_box",
		computer = "metal_box",
		popcan = "metal_box",
		paintcan = "metal_box",
		metalgrate = "metalgrate",
		metalvent = "duct",
		chainlink = "chainlink",
		chain = "chainlink",
		ladder = "ladder",
		tile = "tile",
		glass = "glass",
		combine_glass = "glass",
		plaster = "drywall",
		ceiling_tile = "ceiling_tile",
		wood = "wood",
		wood_solid = "wood",
		wood_lowdensity = "wood",
		woodladder = "wood",
		wood_panel = "woodpanel",
		wood_box = "wood_box",
		wood_crate = "wood_box",
		wood_furniture = "wood_box",
		wood_plank = "wood_box",
		rubber = "rubber",
		rubbertire = "rubber",
		cardboard = "cardboard",
		paper = "cardboard",
		plastic = "plastic",
		plastic_box = "plastic",
		item = "plastic",
		plastic_barrel = "plastic_barrel",
		water = "slosh",
		flesh = "flesh",
		alienflesh = "flesh",
		zombieflesh = "flesh",
		armorflesh = "flesh",
		bloodyflesh = "flesh",
		antlion = "flesh",
		weapon = "weapon",
	}
	local resolved = {}

	local function get_set(surface)
		local set = resolved[surface]

		if not set then
			set = SETS[SURFACES[surface] or SURFACES[surface:match("^[^_]+")] or SURFACES.default]
			resolved[surface] = set
		end

		return set
	end

	function profile.GetFootstep(surface, speed)
		return get_set(surface)
	end
end

return profile
