local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local sounds = import("lua/sounds.lua")
local MIN_SPEED = 1
local HARD_SPEED = 3
local LOUD_SPEED = 7
local INTERVAL = 0.05
local REFERENCE_MASS = 20
local MASS_DB = 6
local MIN_MASS_DB = -18
local MAX_MASS_DB = 4
local SCRAPE_MIN = 0.3
local SCRAPE_ROUGH = 2.5
local LOUD_SLIP = 4
local SCRAPE_GAIN = 10 ^ (-8 / 20)
local ROLL_MIN = 0.3
local LOUD_ROLL = 5
local ROLL_GAIN = 10 ^ (-8 / 20)
local GROUND_GAIN = 10 ^ (-12 / 20)
local GRAIN_GAIN = 10 ^ (-6 / 20)
local GRAIN_SPACING = 0.3
local MAX_LOOPS = 8
local ATTACK = 0.08
local RELEASE = 0.15
local STALE = 0.1

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

for name, loops in pairs(LOOPS) do
	local found = SETS[name]
	found.smooth, found.rough, found.roll = loops[1], loops[2], loops[3]
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

local function get_mass_gain(mass)
	return 10 ^ (
			math.clamp(MASS_DB * math.log10(mass / REFERENCE_MASS), MIN_MASS_DB, MAX_MASS_DB) / 20
		)
end

local last_played = table.weak("k")

event.AddListener("Impact", "physics_impacts", function(info)
	if info.Kind ~= "physics" or info.Speed < MIN_SPEED then return end

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
		found.gain * get_mass_gain(info.Mass) * math.min(info.Speed / LOUD_SPEED, 1),
		math.randomf(0.95, 1.05)
	)
end)

local voices = table.weak("k")
local active = {}
local idle = {}

local function stop_voice(voice)
	voice.source:Stop()
	voice.owner[voice.path] = nil
	local pool = idle[voice.path]

	if not pool then
		pool = {}
		idle[voice.path] = pool
	end

	pool[#pool + 1] = voice.source

	for i = 1, #active do
		if active[i] == voice then
			table.remove(active, i)

			break
		end
	end
end

local function get_source(path)
	local pool = idle[path]

	if pool and pool[1] then return table.remove(pool) end

	local source = sounds.CreateSource(path)

	if source then source:SetLooping(true) end

	return source
end

local function get_priority(voice)
	return sounds.GetLevel(voice.position, voice.target)
end

local function drive(owner, path, volume, pitch, low, mid, high, position, now)
	local voice = owner[path]

	if not voice then
		local quietest

		if #active >= MAX_LOOPS then
			for _, other in ipairs(active) do
				if not quietest or get_priority(other) < get_priority(quietest) then
					quietest = other
				end
			end

			if sounds.GetLevel(position, volume) <= get_priority(quietest) then
				return
			end

			stop_voice(quietest)
		end

		local source = get_source(path)

		if not source then return end

		voice = {source = source, owner = owner, path = path, volume = 0, tone = Vec3(1, 1, 1)}
		owner[path] = voice
		active[#active + 1] = voice
		source:SetVolume(0)
		source:SetBandGains(voice.tone)
		source:SetPosition(position)
		source:Play()
	end

	voice.target = volume
	voice.pitch = pitch
	voice.tone:Set(low, mid, high)
	voice.position = position
	voice.updated = now
end

local function get_layers(entity, other)
	local row = voices[entity]

	if not row then
		row = table.weak("k")
		voices[entity] = row
	end

	local layers = row[other]

	if not layers then
		layers = {scrape = {}, ground = {}, object = {}, grain_distance = 0, grain_time = 0}
		row[other] = layers
	end

	return layers
end

event.AddListener("Contact", "physics_sounds", function(info)
	local found = get_set(info.Surface)
	local gain = found.gain * get_mass_gain(info.Mass)

	if not sounds.IsAudible(info.Position, gain) then return end

	local now = system.GetElapsedTime()
	local layers = get_layers(info.Entity, info.Other)
	local slip, roll = info.Slip, info.Roll

	if slip >= SCRAPE_MIN then
		local path = slip >= SCRAPE_ROUGH and found.rough or found.smooth
		local speed = math.min(slip / LOUD_SLIP, 1)

		if path then
			drive(
				layers.scrape,
				path,
				gain * SCRAPE_GAIN * speed,
				0.9 + 0.2 * speed,
				1,
				1,
				1,
				info.Position,
				now
			)
		end
	end

	if roll < ROLL_MIN then return end

	local speed = math.min(roll / LOUD_ROLL, 1)

	if info.Rolling then
		if found.smooth then
			drive(
				layers.ground,
				found.smooth,
				gain * GROUND_GAIN * speed,
				0.6 + 0.6 * speed,
				1,
				0.4 + 0.6 * speed,
				0.1 + 0.9 * speed,
				info.Position,
				now
			)
		end
	elseif found.roll then
		drive(
			layers.object,
			found.roll,
			gain * ROLL_GAIN * speed,
			0.7 + 0.5 * speed,
			1,
			1,
			1,
			info.Position,
			now
		)
	else
		local dt = now - layers.grain_time
		layers.grain_time = now
		layers.grain_distance = layers.grain_distance + roll * (dt < STALE and dt or 0)

		if layers.grain_distance >= GRAIN_SPACING then
			layers.grain_distance = 0
			local paths = found.soft
			local index = math.random(#paths)

			if index == paths.last then index = index % #paths + 1 end

			paths.last = index
			sounds.Play(paths[index], info.Position, gain * GRAIN_GAIN * speed, math.randomf(0.9, 1.1))
		end
	end
end)

event.AddListener("Update", "physics_sounds", function(dt)
	local now = system.GetElapsedTime()

	for i = #active, 1, -1 do
		local voice = active[i]
		local target = now - voice.updated > STALE and 0 or voice.target
		voice.volume = voice.volume + (
				target - voice.volume
			) * math.min(dt / (target > voice.volume and ATTACK or RELEASE), 1)

		if target == 0 and voice.volume < 0.002 then
			stop_voice(voice)
		else
			voice.source:SetVolume(voice.volume)
			voice.source:SetPitch(voice.pitch)
			voice.source:SetPosition(voice.position)
		end
	end
end)
