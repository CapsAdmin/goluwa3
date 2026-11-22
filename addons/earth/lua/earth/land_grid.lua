local ffi = require("ffi")
local mvt = import("goluwa/codecs/mvt.lua")
-- what the ground of one map tile is, from Overture's land cover (ESA WorldCover, everywhere), land use and land
-- (OpenStreetMap, where mapped, drawn over it): a grid of land classes over the tile, 0 where nothing says
local land_grid = {}
land_grid.ATTRIBUTION = "Land cover: ESA WorldCover 2021 (CC BY 4.0), Overture Maps Foundation (OpenStreetMap contributors ODbL)"
land_grid.SIZE = 512
land_grid.CLASSES = {
	"forest",
	"shrub",
	"grass",
	"crop",
	"urban",
	"bare",
	"sand",
	"rock",
	"wetland",
	"snow",
}
local CLASS = {}

for id, name in ipairs(land_grid.CLASSES) do
	CLASS[name] = id
end

local LAND_COVER = {
	forest = "forest",
	mangrove = "wetland",
	shrub = "shrub",
	grass = "grass",
	moss = "grass",
	crop = "crop",
	urban = "urban",
	barren = "bare",
	wetland = "wetland",
	snow = "snow",
}
-- land use that says what the ground is; residential, protected areas and the like do not
local LAND_USE_SUBTYPES = {
	agriculture = "crop",
	horticulture = "crop",
	aquaculture = "wetland",
	cemetery = "grass",
	park = "grass",
	grass = "grass",
	golf = "grass",
	managed = "grass",
	construction = "bare",
	landfill = "bare",
	resource_extraction = "bare",
	pedestrian = "urban",
}
local LAND_USE_CLASSES = {
	industrial = "urban",
	commercial = "urban",
	retail = "urban",
	works = "urban",
	railway = "urban",
	pitch = "grass",
	playground = "grass",
	recreation_ground = "grass",
	stadium = "urban",
	orchard = "forest",
	plantation = "forest",
	vineyard = "shrub",
	greenhouse_horticulture = "urban",
	farmyard = "bare",
	quarry = "bare",
}
local LAND_SUBTYPES = {
	forest = "forest",
	shrub = "shrub",
	grass = "grass",
	wetland = "wetland",
	sand = "sand",
	rock = "rock",
	glacier = "snow",
	desert = "sand",
}
local LAND_CLASSES = {
	beach = "sand",
	dune = "sand",
	shingle = "rock",
	scree = "rock",
	bare_rock = "rock",
	cliff = "rock",
	mud = "wetland",
	heath = "shrub",
	fell = "grass",
	tundra = "grass",
}

local function classify(layer_name, p)
	if layer_name == "land_cover" then return LAND_COVER[p.subtype] end

	if layer_name == "land_use" then
		return LAND_USE_CLASSES[p.class] or LAND_USE_SUBTYPES[p.subtype]
	end

	if layer_name == "land" then
		return LAND_CLASSES[p.class] or LAND_SUBTYPES[p.subtype]
	end
end

local LAYER_ORDER = {"land_cover", "land_use", "land"}

local function drawn_first(a, b)
	if a.rank ~= b.rank then return a.rank < b.rank end

	return a.area > b.area
end

-- layers: a decoded tile (mvt.Decode); returns meta {any (whether any texel has a class)} and a blob of SIZE^2 bytes,
-- rows from the tile's north; land cover first, then land use and land, larger polygons before the smaller ones inside
-- them
function land_grid.Build(layers)
	local size = land_grid.SIZE
	local features = {}

	for rank, layer_name in ipairs(LAYER_ORDER) do
		local layer = layers[layer_name]

		if layer then
			local scale = size / layer.extent

			for _, feature in ipairs(layer.features) do
				local class = feature.type == mvt.POLYGON and classify(layer_name, feature.properties)

				if class then
					local rings = {}
					local area = 0

					for r, ring in ipairs(feature.rings) do
						area = area + mvt.GetRingArea(ring)
						local scaled = {}

						for i = 1, #ring do
							scaled[i] = ring[i] * scale
						end

						rings[r] = scaled
					end

					features[#features + 1] = {rank = rank, area = area, class = CLASS[class], rings = rings}
				end
			end
		end
	end

	table.sort(features, drawn_first)
	local grid = ffi.new("uint8_t[?]", size * size)

	for _, feature in ipairs(features) do
		mvt.FillRings(grid, size, size, feature.rings, feature.class)
	end

	return {any = features[1] ~= nil}, grid
end

land_grid.JOB = [[
	local input = ...
	return import("lua/earth/land_grid.lua").Build(import("goluwa/codecs/mvt.lua").Decode(input.data))
]]
return land_grid
