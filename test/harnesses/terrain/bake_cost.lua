-- what baking a tile costs on the island's terrain source: N tiles of a level through the same path as the terrain
-- (ShaderSource:RequestChunk, one submit, wait for the fence), with every texture and with each alone. the waiting is the gpu
-- time of the bakes, the time before it is recording them. no --validate
-- N=32 luajit glw --3d --background lua "./test/harnesses/terrain/bake_cost.lua"
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local island = import("addons/examples/lua/examples/render3d/island_terrain.lua")
local terrain = _G.island_terrain
local source = terrain.Source
local N = tonumber(os.getenv("N") or 32)
terrain:Stop()
local GetTime = system.GetTime
local configs = {
	{"full", {}},
	{"heights only", {detail_size = false, splat_size = false, color_size = false}},
	{"+ normal", {splat_size = false, color_size = false}},
	{"+ splat", {detail_size = false, color_size = false}},
	{"+ color", {detail_size = false, splat_size = false}},
}
local frame_count = 0
local started = false

local function run_level(level)
	local lines = {}

	for _, config in ipairs(configs) do
		local record, wait = 0, 0

		for round = 1, 3 do
			local done = 0
			local t0 = GetTime()

			for i = 1, N do
				local request = terrain:BuildTileRequest(level, 200 + round * 20 + i % 8, 30 + math.floor(i / 8) + round * 7)

				for key, value in pairs(config[2]) do
					request[key] = value or nil
				end

				source:RequestChunk(request, function()
					done = done + 1
				end)
			end

			source:Submit()
			local t1 = GetTime()
			source:Finish()
			local t2 = GetTime()

			if round > 1 then
				record = record + (t1 - t0)
				wait = wait + (t2 - t1)
			end
		end

		lines[#lines + 1] = string.format("  %-14s record %.2f ms, gpu %.2f ms per tile", config[1], record / 2 / N * 1000, wait / 2 / N * 1000)
	end

	print(string.format("BAKE level %d (%d m tiles, %d heights, detail %d, splat %d, color %s):", level, terrain:GetLevelChunkSize(level), terrain.Samples, terrain.DetailSize, terrain.SplatSize, tostring(terrain.ColorSize)))

	for _, line in ipairs(lines) do
		print("BAKE" .. line)
	end
end

-- what the terrain does with a baked chunk on the cpu, each piece alone
local function run_cpu(level)
	local Entity = import("goluwa/entities/entity.lua")
	local tiles = import("goluwa/terrain/tiles.lua")
	local chunks = {}

	for i = 1, N do
		source:RequestChunk(terrain:BuildTileRequest(level, 300 + i % 8, 60 + math.floor(i / 8)), function(chunk)
			chunks[#chunks + 1] = chunk
		end)
	end

	source:Submit()
	source:Finish()
	terrain.Root = Entity.New{Name = "bake_cost_root"}
	terrain.Root:AddComponent("transform")
	local skirt = terrain:GetLevelSkirtDepth(level)
	local function time(label, f)
		local t0 = GetTime()

		for i = 1, #chunks do
			f(chunks[i], i)
		end

		print(string.format("BAKE  cpu %-34s %.3f ms per tile", label, (GetTime() - t0) / #chunks * 1000))
	end

	print("BAKE level " .. level .. " cpu, " .. #chunks .. " tiles:")
	time("min/max of the heights (lua loop)", function(chunk)
		local min_height, max_height = math.huge, -math.huge

		for j = 0, terrain.Samples * terrain.Samples - 1 do
			local h = chunk.heights[j]

			if h < min_height then min_height = h end

			if h > max_height then max_height = h end
		end
	end)
	time("tiles.BuildPolygon", function(chunk)
		tiles.BuildPolygon(chunk, skirt)
	end)
	time("tiles.CreateMaterial", function(chunk)
		tiles.CreateMaterial(chunk, chunk.layers or source:GetLayers(), terrain.ScatterSet)
	end)
	local created = {}
	time("Terrain:CreateTile (all of it)", function(chunk, i)
		local want = {level = level, chunk_x = 300 + i % 8, chunk_z = 60 + math.floor(i / 8)}
		created[#created + 1] = terrain:CreateTile(want, chunk)
	end)
	time("Entity:Remove of the tile", function(chunk, i)
		created[i].entity:Remove()
	end)
	time("Source:ReleaseChunk (recycle)", function(chunk)
		source:ReleaseChunk(chunk)
	end)
end

event.AddListener("Update", "bake_cost", function()
	frame_count = frame_count + 1

	if frame_count < 30 or started then return end

	started = true
	-- the first run compiles the shaders
	source:RequestChunk(terrain:BuildTileRequest(0, 1, 1), function() end)
	source:Submit()
	source:Finish()
	run_level(0)
	run_level(3)
	run_cpu(0)
	system.ShutDown(0)
end)
