local SURFACES = {
	mat_default = "default",
	mat_nodraw = "default",
	mat_obstruct = "default",
	mat_metal = "metal",
	mat_metal_ = "metal",
	mat_metal_smooth = "metal",
	mat_metal_rough = "metal",
	mat_metal_thick = "metal",
	mat_metal_thick_weapons = "metal",
	mat_metal_nd_p = "metal",
	mat_metal_pierceable = "metal",
	mat_metal_sheet = "metal_vent",
	mat_metal_pipe = "canister",
	mat_metal_grate = "metal_grate",
	mat_metal_chainlink = "chainlink",
	mat_metal_barbwire = "chain",
	mat_ladder = "ladder",
	mat_concrete = "concrete",
	mat_asphalt = "asphalt",
	mat_tile = "tile",
	mat_rock = "rock",
	mat_rock_dusty = "rock",
	mat_rubble_stone = "rock",
	mat_pebble = "gravel",
	mat_gravel = "gravel",
	mat_soil = "dirt",
	mat_dirt = "dirt",
	mat_mud = "mud",
	mat_sand_dry = "sand",
	mat_sand_wet = "sand",
	mat_snow = "snow",
	mat_ice = "ice",
	mat_ice_breakable = "ice",
	mat_grass = "grass",
	mat_leaves = "foliage",
	mat_leaves_terrain = "foliage",
	mat_canopy = "foliage",
	mat_canopy_banana = "foliage",
	mat_feathers = "carpet",
	mat_fabric = "carpet",
	mat_canvas = "carpet",
	mat_kevlar = "carpet",
	mat_wood = "wood",
	mat_wood_ = "wood",
	mat_wood_dusty = "wood",
	mat_wood_breakable_thick = "wood",
	mat_wood_hollow = "wood_box",
	mat_wood_solid = "wood_solid",
	mat_plastic = "plastic",
	mat_plastic_nopierce = "plastic",
	mat_plastic_soft = "rubber",
	mat_rubber = "rubber",
	mat_cardboard = "cardboard",
	mat_glass = "glass",
	mat_glass_thin = "glass",
	mat_glass_thick = "glass",
	mat_glass_unbreakable = "glass",
	mat_glass_bulletproof = "glass",
	mat_glass_vehicle = "glass",
	mat_water = "water",
	mat_flesh = "flesh",
	mat_head = "flesh",
	mat_torso = "flesh",
	mat_arm_left = "flesh",
	mat_arm_right = "flesh",
	mat_hand_left = "flesh",
	mat_hand_right = "flesh",
	mat_leg_left = "flesh",
	mat_leg_right = "flesh",
	mat_foot_left = "flesh",
	mat_foot_right = "flesh",
	mat_alien_basic_wall = "metal",
	mat_alien_machine = "metal",
	mat_alien_floor = "metal",
	mat_alien_shell = "metal",
	mat_alien_forcefield = "metal",
	mat_alien_breakable_spike = "rock",
	mat_alien_glass = "glass",
	mat_alien_flesh = "flesh",
	mat_alien_hunter_torso = "flesh",
}
local surface_types = {}
local cache = {}

function surface_types.Translate(name)
	local found = cache[name]

	if found then return found end

	local key = name:lower()

	while key and not SURFACES[key] do
		key = key:match("^(.*)_[^_]*$")
	end

	found = key and SURFACES[key] or "default"
	cache[name] = found
	return found
end

return surface_types
