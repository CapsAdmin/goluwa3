local pvars = import("goluwa/cli/pvars.lua")
local event = import("goluwa/event.lua")
local lod = library()
lod.NEVER = 1e30
lod.SOURCE_SWITCH_TO_RADII = 0.5
lod.CRY_RADII_PER_LEVEL = 6
lod.BILLBOARD_MIN_RADII = 14

local function changed()
	event.Call("LODSettingsChanged")
end

pvars.StartGroup("lod", {store = false})
local level = pvars.Setup2{
	key = "lod_level",
	default = -1,
	integer = true,
	min = -1,
	max = 15,
	friendly = "level",
	callback = changed,
	help = "draw every model at this level of detail, 0 is the most detailed and a level past the last one is the last one, -1 picks by distance",
}
local scale = pvars.Setup2{
	key = "lod_scale",
	default = 1,
	min = 0.05,
	max = 100,
	friendly = "scale",
	callback = changed,
	help = "scales the distances levels of detail switch at, above 1 keeps detail further out",
}
local fade = pvars.Setup2{
	key = "lod_fade",
	default = 0.15,
	min = 0,
	max = 0.9,
	friendly = "fade",
	callback = changed,
	help = "how far around a switch distance two levels cross fade, as a fraction of that distance, 0 switches instantly",
}
local billboards = pvars.Setup2{
	key = "lod_billboards",
	default = false,
	friendly = "billboards",
	callback = changed,
	help = "give every model a billboard as its last level of detail, not only the ones that ask for it. turning it on bakes them all, skinned models are left out",
}
local bvh_level = pvars.Setup2{
	key = "lod_bvh_level",
	default = 0,
	integer = true,
	min = 0,
	max = 15,
	friendly = "bvh level",
	callback = changed,
	help = "the level of detail the scene bvh is built from, one fixed level for everything and never a billboard, a level past the last mesh level of a model is its last mesh level",
}
pvars.EndGroup()

function lod.GetForcedLevel()
	return level:Get()
end

function lod.GetScale()
	return scale:Get()
end

function lod.AreBillboardsForced()
	return billboards:Get()
end

function lod.GetBVHLevel()
	return bvh_level:Get()
end

function lod.GetFadeWidth()
	return fade:Get()
end

return lod
