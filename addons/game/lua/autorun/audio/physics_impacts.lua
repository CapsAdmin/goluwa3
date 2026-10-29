local event = import("goluwa/event.lua")
local audio = import("goluwa/audio.lua")
local system = import("goluwa/system.lua")
local sounds = import("lua/sounds.lua")
local RANGE = 40
local MIN_SPEED = 1
local HARD_SPEED = 3
local LOUD_SPEED = 7
local INTERVAL = 0.05

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

local function set(soft, hard, volume)
	return {soft = soft, hard = hard, volume = volume}
end

local SETS = {
	concrete = set(
		range("physics/concrete/concrete_impact_soft", 1, 3),
		range("physics/concrete/concrete_impact_hard", 1, 3),
		0.6
	),
	concrete_block = set(
		range("physics/concrete/concrete_impact_soft", 1, 3),
		range("physics/concrete/concrete_block_impact_hard", 1, 3),
		0.6
	),
	rock = set(
		range("physics/concrete/rock_impact_soft", 1, 3),
		range("physics/concrete/rock_impact_hard", 4, 6),
		0.6
	),
	boulder = set(
		range("physics/concrete/rock_impact_hard", 1, 3),
		range("physics/concrete/boulder_impact_hard", 1, 4),
		0.85
	),
	dirt = set(
		range("physics/surfaces/sand_impact_bullet", 1, 4),
		range("physics/surfaces/sand_impact_bullet", 1, 4),
		0.6
	),
	carpet = set(range("player/footsteps/sand", 1, 4), range("player/footsteps/sand", 1, 4), 0.6),
	metal = set(
		range("physics/metal/metal_solid_impact_soft", 1, 3),
		list(
			"physics/metal/metal_solid_impact_hard1.wav",
			"physics/metal/metal_solid_impact_hard4.wav",
			"physics/metal/metal_solid_impact_hard5.wav"
		),
		0.6
	),
	metal_box = set(
		range("physics/metal/metal_box_impact_soft", 1, 3),
		range("physics/metal/metal_box_impact_hard", 1, 3),
		0.6
	),
	metal_vent = set(
		range("physics/metal/metal_box_impact_soft", 1, 3),
		range("physics/metal/metal_sheet_impact_hard", 6, 8),
		0.6
	),
	metal_barrel = set(
		range("physics/metal/metal_barrel_impact_soft", 1, 4),
		range("physics/metal/metal_barrel_impact_hard", 1, 3),
		0.6
	),
	canister = set(
		range("physics/metal/metal_canister_impact_soft", 1, 3),
		range("physics/metal/metal_canister_impact_hard", 1, 3),
		0.6
	),
	computer = set(
		range("physics/metal/metal_computer_impact_soft", 1, 3),
		range("physics/metal/metal_computer_impact_hard", 1, 3),
		0.5
	),
	metal_grate = set(
		range("physics/metal/metal_grate_impact_soft", 1, 3),
		range("physics/metal/metal_grate_impact_hard", 1, 3),
		0.6
	),
	chainlink = set(
		range("physics/metal/metal_chainlink_impact_soft", 1, 3),
		range("physics/metal/metal_chainlink_impact_hard", 1, 3),
		0.6
	),
	chain = set(
		range("physics/metal/chain_impact_soft", 1, 3),
		range("physics/metal/chain_impact_hard", 1, 2),
		0.6
	),
	grenade = set(
		range("physics/metal/metal_grenade_impact_soft", 1, 3),
		range("physics/metal/metal_grenade_impact_hard", 1, 3),
		0.6
	),
	paintcan = set(
		range("physics/metal/paintcan_impact_soft", 1, 3),
		range("physics/metal/paintcan_impact_hard", 1, 3),
		0.6
	),
	popcan = set(
		range("physics/metal/soda_can_impact_soft", 1, 3),
		range("physics/metal/soda_can_impact_hard", 1, 3),
		0.6
	),
	weapon = set(
		range("physics/metal/weapon_impact_soft", 1, 3),
		range("physics/metal/weapon_impact_hard", 1, 3),
		0.6
	),
	vehicle = set(
		range("vehicles/v8/vehicle_impact_medium", 1, 4),
		range("vehicles/v8/vehicle_impact_heavy", 1, 4),
		0.9
	),
	wood = set(
		list(
			"physics/wood/wood_plank_impact_soft1.wav",
			"physics/wood/wood_box_impact_soft1.wav",
			"physics/wood/wood_solid_impact_soft2.wav"
		),
		range("physics/wood/wood_box_impact_hard", 1, 3),
		0.6
	),
	wood_solid = set(
		range("physics/wood/wood_solid_impact_soft", 1, 3),
		range("physics/wood/wood_solid_impact_hard", 1, 3),
		0.6
	),
	wood_box = set(
		range("physics/wood/wood_box_impact_soft", 1, 3),
		range("physics/wood/wood_box_impact_hard", 4, 6),
		0.6
	),
	wood_crate = set(
		range("physics/wood/wood_crate_impact_soft", 1, 3),
		list(
			"physics/wood/wood_crate_impact_hard4.wav",
			"physics/wood/wood_crate_impact_hard5.wav",
			"physics/wood/wood_panel_impact_hard1.wav"
		),
		0.6
	),
	wood_furniture = set(
		range("physics/wood/wood_furniture_impact_soft", 1, 3),
		range("physics/wood/wood_box_impact_hard", 4, 6),
		0.6
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
		),
		0.6
	),
	wood_plank = set(
		range("physics/wood/wood_plank_impact_soft", 1, 3),
		range("physics/wood/wood_plank_impact_hard", 1, 5),
		0.6
	),
	plastic = set(
		range("physics/plastic/plastic_box_impact_soft", 1, 4),
		range("physics/plastic/plastic_box_impact_hard", 1, 4),
		0.7
	),
	plastic_barrel = set(
		range("physics/plastic/plastic_barrel_impact_soft", 1, 6),
		range("physics/plastic/plastic_barrel_impact_hard", 1, 4),
		0.7
	),
	glass = set(
		range("physics/glass/glass_sheet_impact_soft", 1, 3),
		range("physics/glass/glass_sheet_impact_hard", 1, 3),
		0.5
	),
	glass_bottle = set(
		range("physics/glass/glass_impact_soft", 1, 3),
		range("physics/glass/glass_bottle_impact_hard", 1, 3),
		0.6
	),
	pottery = set(
		range("physics/glass/glass_impact_soft", 1, 3),
		range("physics/glass/glass_impact_hard", 1, 3),
		0.5
	),
	cardboard = set(
		range("physics/cardboard/cardboard_box_impact_soft", 1, 7),
		range("physics/cardboard/cardboard_box_impact_hard", 1, 7),
		0.7
	),
	paper_cup = set(
		range("physics/cardboard/cardboard_box_impact_soft", 1, 7),
		range("physics/cardboard/cardboard_cup_impact_hard", 1, 3),
		0.6
	),
	drywall = set(
		range("physics/plaster/drywall_impact_soft", 1, 3),
		range("physics/plaster/drywall_impact_hard", 1, 3),
		0.7
	),
	ceiling_tile = set(
		range("physics/plaster/ceiling_tile_impact_soft", 1, 3),
		range("physics/plaster/ceiling_tile_impact_hard", 1, 3),
		0.7
	),
	rubber = set(
		range("physics/rubber/rubber_tire_impact_soft", 1, 3),
		range("physics/rubber/rubber_tire_impact_hard", 1, 3),
		0.7
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
		0.7
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
		0.6
	),
	squishy = set(
		range("physics/flesh/flesh_squishy_impact_hard", 1, 4),
		range("physics/flesh/flesh_squishy_impact_hard", 1, 4),
		0.6
	),
	water = set(
		range("physics/surfaces/underwater_impact_bullet", 1, 3),
		range("ambient/water/water_splash", 1, 3),
		0.6
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
local resolved = {}

local function get_set(surface)
	local found = resolved[surface]

	if not found then
		found = SETS[SURFACES[surface] or SURFACES[surface:match("^[^_]+")] or SURFACES.default]
		resolved[surface] = found
	end

	return found
end

local last_played = table.weak("k")

event.AddListener("Impact", "physics_impacts", function(info)
	if info.Kind ~= "physics" or info.Speed < MIN_SPEED then return end

	if info.Position:Distance(audio.GetListenerPosition()) > RANGE then return end

	local now = system.GetElapsedTime()
	local row = last_played[info.Entity]

	if not row then
		row = table.weak("k")
		last_played[info.Entity] = row
	end

	if now - (row[info.Other] or -math.huge) < INTERVAL then return end

	row[info.Other] = now
	local found = get_set(info.Surface)
	local paths = info.Speed >= HARD_SPEED and found.hard or found.soft
	local index = math.random(#paths)

	if index == paths.last then index = index % #paths + 1 end

	paths.last = index
	sounds.Play(
		paths[index],
		info.Position,
		found.volume * math.min(info.Speed / LOUD_SPEED, 1),
		math.randomf(0.95, 1.05)
	)
end)
