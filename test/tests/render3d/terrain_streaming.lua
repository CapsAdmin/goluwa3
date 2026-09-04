local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Terrain = import("goluwa/terrain/terrain.lua")
local TerrainSource = import("goluwa/terrain/source.lua")
local HeightmapShape = import("goluwa/physics/shapes/heightmap.lua")

local function create_source()
	local source = TerrainSource.New{MinHeight = 0, MaxHeight = 10}

	function source:RequestChunk(request, callback)
		local samples = request.samples
		callback{
			request = request,
			heights = HeightmapShape.SamplesFromFunction(samples, samples, function()
				return 1
			end),
		}
	end

	return source
end

local function fake_entity()
	local valid = true
	return {
		IsValid = function()
			return valid
		end,
		Remove = function()
			valid = false
		end,
	}
end

-- headless terrain: no render, tiles are plain tables with a fake entity
local function create_terrain()
	local terrain = Terrain.New{
		Name = "terrain_streaming_test",
		Source = create_source(),
		Levels = 2,
		BaseChunkSize = 16,
		Samples = 5,
		BuildsPerUpdate = 1,
	}
	terrain.Root = fake_entity()
	terrain.CreateTile = function(self, want, chunk)
		return {entity = fake_entity()}
	end
	return terrain
end

local function build_everything(terrain)
	for _ = 1, 200 do
		if #terrain.BuildQueue == 0 then break end

		terrain:ProcessBuildQueue()
	end

	terrain:RetireTiles()
end

local function count_tiles(terrain)
	local ready, retiring = 0, 0

	for _, tile in pairs(terrain.Tiles) do
		if tile.entity then ready = ready + 1 end

		if tile.retiring then retiring = retiring + 1 end
	end

	return ready, retiring
end

local function is_covered(terrain, x, z)
	for _, tile in pairs(terrain.Tiles) do
		if tile.entity and not tile.hidden then
			local size = terrain:GetLevelChunkSize(tile.level)
			local min_x = tile.chunk_x * size
			local min_z = tile.chunk_z * size

			if x >= min_x and x < min_x + size and z >= min_z and z < min_z + size then
				return true
			end
		end
	end

	return false
end

local function assert_area_covered(terrain, min_x, min_z, max_x, max_z)
	for z = min_z + 4, max_z - 4, 8 do
		for x = min_x + 4, max_x - 4, 8 do
			T(is_covered(terrain, x, z))["=="](true)
		end
	end
end

T.Test("Terrain keeps stale tiles until their replacements are built", function()
	local terrain = create_terrain()
	terrain:UpdateTiles(Vec3(0, 0, 0))
	build_everything(terrain)
	local ready, retiring = count_tiles(terrain)
	T(ready)["=="](28)
	T(retiring)["=="](0)
	-- move one level 0 snap step, so the inner ring shifts and level 1 re-tiles
	terrain:UpdateTiles(Vec3(40, 0, 0))
	ready, retiring = count_tiles(terrain)
	T(retiring > 0)["=="](true)
	T(ready > 0)["=="](true)
	-- tiles outside the new coverage go away at once, but the area both
	-- layouts cover (x 0..64) must stay covered while the new tiles build
	local steps = 0

	local saw_hidden = false

	while #terrain.BuildQueue > 0 do
		assert_area_covered(terrain, 0, -32, 64, 32)
		terrain:ProcessBuildQueue()
		terrain:RetireTiles()
		steps = steps + 1
		T(steps < 100)["=="](true)

		-- a visible new tile must never overlap a visible old one
		for _, tile in pairs(terrain.Tiles) do
			if tile.hidden then saw_hidden = true end

			if tile.entity and not tile.hidden and not tile.retiring then
				for _, other in pairs(terrain.Tiles) do
					if other.retiring and other.entity then
						local size = terrain:GetLevelChunkSize(tile.level)
						local other_size = terrain:GetLevelChunkSize(other.level)
						local overlap = tile.chunk_x * size < (other.chunk_x + 1) * other_size and
							other.chunk_x * other_size < (tile.chunk_x + 1) * size and
							tile.chunk_z * size < (other.chunk_z + 1) * other_size and
							other.chunk_z * other_size < (tile.chunk_z + 1) * size
						T(overlap)["=="](false)
					end
				end
			end
		end
	end

	T(saw_hidden)["=="](true)

	terrain:RetireTiles()
	ready, retiring = count_tiles(terrain)
	T(ready)["=="](28)
	T(retiring)["=="](0)

	for _, tile in pairs(terrain.Tiles) do
		T(tile.hidden)["~="](true)
	end

	assert_area_covered(terrain, 0, -32, 128, 64)
	T(next(terrain.BuildQueue))["=="](nil)
end)

T.Test("Terrain drops stale tiles that were never built", function()
	local terrain = create_terrain()
	terrain:UpdateTiles(Vec3(0, 0, 0))
	terrain:UpdateTiles(Vec3(4000, 0, 0))
	local ready, retiring = count_tiles(terrain)
	T(ready)["=="](0)
	T(retiring)["=="](0)
	build_everything(terrain)
	ready, retiring = count_tiles(terrain)
	T(ready)["=="](28)
	T(retiring)["=="](0)
end)
