local vfs = import("goluwa/vfs.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local source1 = import("lua/sound_profiles/source1.lua")
local profile = {}
local EVENT_FILES = {
	"soundevents_physics_surfaces",
	"soundevents_physics_props",
	"soundevents_physics_npc",
	"soundevents_footsteps_player",
}
local BINS = {"a", "b", "c", "d"}
local LIGHT_STEP_SPEED = 1
local RUN_STEP_SPEED = 3
local FOOTSTEP_KEYWORDS = {
	{"chainlink", "Metal_Chainlink"},
	{"grate", "Metal_Walkway"},
	{"walkway", "Metal_Walkway"},
	{"thin", "Metal_Thin"},
	{"vent", "Metal_Thin"},
	{"panel", "Metal_Panel"},
	{"metal", "Metal_Solid"},
	{"crate", "Wood_Crate"},
	{"box", "Wood_Crate"},
	{"parquet", "Wood_Floor_Parquet"},
	{"wood", "Wood_Floor_Old"},
	{"cardboard", "Cardboard"},
	{"paper", "Cardboard"},
	{"plastic", "Plastic_Hollow"},
	{"carpet", "Carpet"},
	{"grass", "Grass"},
	{"foliage", "Grass"},
	{"gravel", "Gravel"},
	{"mud", "Mud"},
	{"slime", "Mud"},
	{"water", "Mud_Puddles"},
	{"dirt", "Dirt"},
	{"sand", "Dirt"},
	{"snow", "Dirt"},
	{"debris", "Debris"},
	{"concrete", "Concrete_Rough"},
	{"stone", "Concrete_Rough"},
	{"rock", "Concrete_Rough"},
	{"brick", "Concrete_Rough"},
	{"tile", "Concrete_Rough"},
	{"porcelain", "Concrete_Rough"},
	{"asphalt", "Concrete_Rough"},
}
local surfaces
local events

local function load()
	surfaces = {}
	events = {}

	for _, entry in ipairs(resource.ReadKV3(resource.Load(vfs, "surfaceproperties/surfaceproperties.vsurf_c")).SurfacePropertiesList) do
		surfaces[entry.surfacePropertyName] = entry
	end

	for _, name in ipairs(EVENT_FILES) do
		for event_name, event in pairs(resource.ReadKV3(resource.Load(vfs, "soundevents/" .. name .. ".vsndevts_c"))) do
			events[event_name] = event
		end
	end
end

local SURFACES = {
	default = "default",
	concrete = "world.concrete",
	concrete_block = "prop.concrete_block",
	brick = "world.brick",
	rock = "world.rock",
	boulder = "world.boulder",
	gravel = "world.gravel",
	asphalt = "world.asphalt",
	tile = "tile",
	porcelain = "prop.porcelain",
	pottery = "prop.pottery",
	dirt = "world.dirt",
	grass = "world.grass",
	sand = "world.sand",
	snow = "world.snow",
	mud = "world.mud",
	ice = "world.ice",
	carpet = "world.carpet",
	foliage = "world.foliage",
	metal = "world.metal",
	metal_vent = "world.metal_vent",
	metal_box = "prop.metal_box",
	metal_barrel = "prop.metal_barrel",
	canister = "prop.metal_gas_canister",
	computer = "prop.computer",
	metal_grate = "world.metal_grate",
	chainlink = "world.chainlink",
	chain = "prop.chain",
	ladder = "world.ladder",
	grenade = "prop.metal_grenade",
	paintcan = "prop.metal_paintcan",
	popcan = "prop.metal_popcan",
	weapon = "base.weapon",
	vehicle = "world.metal_vehicle_ext",
	wood = "base.wood",
	wood_solid = "world.wood_solid",
	wood_box = "prop.wood_box",
	wood_crate = "prop.wood_crate",
	wood_furniture = "prop.wood_furniture",
	wood_panel = "world.wood_panel",
	wood_plank = "prop.wood_plank",
	plastic = "world.plastic",
	plastic_barrel = "prop.plastic_barrel",
	glass = "world.glass",
	glass_bottle = "prop.glass_bottle_small",
	cardboard = "world.cardboard",
	paper_cup = "prop.paper_cup",
	drywall = "world.drywall",
	ceiling_tile = "world.ceiling_tile",
	rubber = "base.rubber",
	flesh = "prop.flesh",
	bloody_flesh = "prop.flesh_bloody",
	squishy = "prop.watermelon",
	water = "world.water",
}

local function find_surface(name)
	return surfaces[assert(SURFACES[name], "unknown surface type " .. tostring(name))]
end

local function resolve_event(name)
	local merged = {}
	local event = events[name]

	while event do
		for key, value in pairs(event) do
			if merged[key] == nil then merged[key] = value end
		end

		event = events[event.base]
	end

	return merged
end

local function to_paths(files)
	local paths = {}

	for i, file in ipairs(files) do
		paths[i] = file .. "_c"
	end

	return paths
end

local function to_legacy_path(path)
	return path and
		(
			path:gsub("^physics/", "sounds/physics/legacy/"):gsub("%.wav$", ".vsnd_c")
		)
end

local impacts = {}

function profile.GetImpact(surface)
	local set = impacts[surface]

	if set then return set end

	if not surfaces then load() end

	local entry = find_surface(surface)
	local event
	local audio_entry = entry

	while audio_entry do
		local name = audio_entry.audiosounds and audio_entry.audiosounds.impacthard
		event = name and resolve_event(name)

		if event and event.vsnd_files_a then break end

		event = nil
		audio_entry = surfaces[audio_entry.base]
	end

	if not event then return profile.GetImpact("default") end

	local bins = {}

	for _, bin in ipairs(BINS) do
		bins[#bins + 1] = event["vsnd_files_" .. bin] and to_paths(event["vsnd_files_" .. bin]) or nil
	end

	local soft, hard = {}, {}

	for i, paths in ipairs(bins) do
		local target = i <= math.ceil(#bins / 2) and soft or hard

		for _, path in ipairs(paths) do
			target[#target + 1] = path
		end
	end

	if #hard == 0 then hard = soft end

	local hardness_entry = entry

	while
		hardness_entry and
		not (
			hardness_entry.audioparams and
			hardness_entry.audioparams.audiohardnessfactor
		)
	do
		hardness_entry = surfaces[hardness_entry.base]
	end

	local legacy = source1.GetImpact(surface)
	set = {
		gain = 1,
		hardness = hardness_entry and hardness_entry.audioparams.audiohardnessfactor or 0.5,
		soft = soft,
		hard = hard,
		smooth = to_legacy_path(legacy.smooth),
		rough = to_legacy_path(legacy.rough),
		roll = to_legacy_path(legacy.roll),
	}
	impacts[surface] = set
	return set
end

local footsteps = {}

function profile.GetFootstep(surface, speed)
	local gaits = footsteps[surface]

	if not gaits then
		if not surfaces then load() end

		local event_name = "Step_Player.Default"
		local entry = find_surface(surface)

		while entry do
			local name = entry.surfacePropertyName:lower()

			for _, keyword in ipairs(FOOTSTEP_KEYWORDS) do
				if name:find(keyword[1], 1, true) then
					event_name = "Step_Player." .. keyword[2]

					goto found
				end
			end

			entry = surfaces[entry.base]
		end

		::found::

		local event = resolve_event(event_name)
		gaits = {}

		for gait, key in pairs{
			light = "vsnd_files_step_light",
			step = "vsnd_files_step",
			run = "vsnd_files_step_run",
		} do
			local paths = to_paths(event[key] or event.vsnd_files_step)
			paths.gain = source1.FOOTSTEP_GAIN
			paths.last = 0
			gaits[gait] = paths
		end

		footsteps[surface] = gaits
	end

	return speed < LIGHT_STEP_SPEED and
		gaits.light or
		speed >= RUN_STEP_SPEED and
		gaits.run or
		gaits.step
end

return profile
