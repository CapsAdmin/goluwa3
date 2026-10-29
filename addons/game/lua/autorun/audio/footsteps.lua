local event = import("goluwa/event.lua")
local sounds = import("lua/sounds.lua")
local LEVEL = -20
local LOUD_SPEED = 3
local QUIET = 0.15

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

event.AddListener("Impact", "footsteps", function(info)
	if info.Kind ~= "footstep" then return end

	local set = get_set(info.Surface)
	local index = math.random(#set)

	if index == set.last then index = index % #set + 1 end

	set.last = index
	sounds.Play(
		set[index],
		info.Position,
		set.gain * math.clamp(info.Speed / LOUD_SPEED, QUIET, 1),
		math.randomf(0.95, 1.05)
	)
end)
