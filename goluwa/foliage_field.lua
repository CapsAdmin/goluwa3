local HeightmapSource = import("goluwa/terrain/heightmap_source.lua")
local foliage_field = {}
local CELL = 2
local HEIGHT = 2.5
local INSTANCE_COVER = 0.5
local GRASS_COVER = 0.5
local GRASS = {grass = true, foliage = true}
local DENSITY_BUSH = 0.7
local DENSITY_GRASS = 0.3
local DENSITY_POINTS = {{0, 0}}

for ring, count in ipairs{8, 16} do
	for i = 0, count - 1 do
		local angle = i / count * math.pi * 2
		DENSITY_POINTS[#DENSITY_POINTS + 1] = {math.cos(angle) * ring * 0.5, math.sin(angle) * ring * 0.5}
	end
end

local cover = {}
local canopy = {}
local base = {}
local terrain_data

function foliage_field.Clear()
	cover = {}
	canopy = {}
	base = {}
	terrain_data = nil
end

function foliage_field.SetTerrain(data)
	terrain_data = data
end

function foliage_field.AddInstance(x, y, z, radius)
	for cx = math.floor((x - radius) / CELL), math.floor((x + radius) / CELL) do
		for cz = math.floor((z - radius) / CELL), math.floor((z + radius) / CELL) do
			local key = cx * 65536 + cz
			cover[key] = math.min((cover[key] or 0) + INSTANCE_COVER, 1)
			base[key] = y
		end
	end
end

function foliage_field.AddCanopy(x, z, radius)
	for cx = math.floor((x - radius) / CELL), math.floor((x + radius) / CELL) do
		for cz = math.floor((z - radius) / CELL), math.floor((z + radius) / CELL) do
			canopy[cx * 65536 + cz] = true
		end
	end
end

function foliage_field.GetDensity(x, z, radius)
	local total = 0

	for i = 1, #DENSITY_POINTS do
		local point = DENSITY_POINTS[i]
		local px, pz = x + point[1] * radius, z + point[2] * radius
		local key = math.floor(px / CELL) * 65536 + math.floor(pz / CELL)

		if canopy[key] then
			total = total + 1
		elseif cover[key] then
			total = total + DENSITY_BUSH
		elseif terrain_data and GRASS[HeightmapSource.SampleSurface(terrain_data, px, pz)] then
			total = total + DENSITY_GRASS
		end
	end

	return total / #DENSITY_POINTS
end

function foliage_field.Sample(x, y, z)
	local key = math.floor(x / CELL) * 65536 + math.floor(z / CELL)
	local found = cover[key]

	if found and math.abs(y - base[key]) < HEIGHT then return found end

	if
		terrain_data and
		GRASS[HeightmapSource.SampleSurface(terrain_data, x, z)] and
		y - HeightmapSource.SampleHeight(terrain_data, x, z) < HEIGHT
	then
		return GRASS_COVER
	end

	return 0
end

return foliage_field
