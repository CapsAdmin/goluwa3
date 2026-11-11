local HeightmapSource = import("goluwa/terrain/heightmap_source.lua")
local foliage_field = {}
local CELL = 2
local HEIGHT = 2.5
local INSTANCE_COVER = 0.5
local GRASS_COVER = 0.5
local GRASS = {grass = true, foliage = true}
local cover = {}
local base = {}
local terrain_data

function foliage_field.Clear()
	cover = {}
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
