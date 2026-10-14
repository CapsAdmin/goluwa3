if not RENDER_2D then return end

-- `terrain_stats` toggles an overlay of every running terrain: the build queue and jobs, tiles per level, timings,
-- and a map of the tiles around the camera colored by what they are doing. `terrain_stats_map=<level>` sets how far
-- the map reaches (the extent of that level's grid, 0 is the finest)
local Color = import("goluwa/structs/color.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Terrain = import("goluwa/terrain/terrain.lua")
local LINE_HEIGHT = 15
local PANEL_WIDTH = 440
local MAP_SIZE = 340
local WHITE = Color(0.88, 0.9, 0.94, 1)
local DIM = Color(0.6, 0.64, 0.7, 1)
local HEAD = Color(1, 0.85, 0.4, 1)
local WARN = Color(1, 0.5, 0.4, 1)
-- what a tile is doing, in the map and in its legend
local STATES = {
	{name = "drawn", color = Color(0.25, 0.8, 0.35, 0.55)},
	{name = "built, not drawn yet", color = Color(0.95, 0.85, 0.2, 0.7)},
	{name = "hidden (blocked)", color = Color(0.9, 0.5, 0.15, 0.7)},
	{name = "loading (gpu job)", color = Color(0.2, 0.8, 0.95, 0.75)},
	{name = "queued, nothing under it", color = Color(0.95, 0.25, 0.3, 0.75)},
	{name = "queued, refines a drawn tile", color = Color(0.35, 0.4, 0.95, 0.6)},
}
local visible = false
local map_level = 3
local row_y = 0
local panel_x = 0
local rate_time = 0
local rate_built = 0
local rate = 0

local function text(x, label, color)
	render2d.DrawText{text = label, x = panel_x + x, y = row_y, foreground_color = color or WHITE}
end

local function newline()
	row_y = row_y + LINE_HEIGHT
end

local function get_tile_state(terrain, tile)
	local entry = tile.chunk_key and terrain.Chunks[tile.chunk_key]

	if tile.entity then
		if tile.hidden then return 3 end

		return terrain:IsTileDrawn(tile) and 1 or 2
	end

	if entry and entry.loading then return 4 end

	if entry and entry.priority and entry.priority >= 1e7 then return 6 end

	return 5
end

local function draw_map(terrain, x, y)
	local camera = render3d.GetCamera()
	local position = camera:GetPosition()
	local half = terrain:GetLevelChunkSize(math.min(map_level, terrain.Levels - 1)) * terrain.GridSize / 2
	local scale = MAP_SIZE / (half * 2)
	local forward = camera:GetRotation():GetForward()
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.72)
	render2d.DrawRect(x - 4, y - 4, MAP_SIZE + 8, MAP_SIZE + 8)
	render2d.PushScissor(x, y, MAP_SIZE, MAP_SIZE)

	for level = terrain.Levels - 1, 0, -1 do
		for key, tile in pairs(terrain.Tiles) do
			if tile.level == level then
				local size = terrain:GetLevelChunkSize(level)
				local tile_x = x + MAP_SIZE / 2 + (tile.chunk_x * size - position.x) * scale
				local tile_y = y + MAP_SIZE / 2 + (tile.chunk_z * size - position.z) * scale
				local state = STATES[get_tile_state(terrain, tile)].color
				render2d.SetColor(state.r, state.g, state.b, tile.retiring and state.a * 0.35 or state.a)
				render2d.DrawRect(tile_x + 1, tile_y + 1, size * scale - 2, size * scale - 2)

				if tile.retiring then
					render2d.SetColor(1, 0.2, 0.2, 0.9)
					render2d.DrawLine(tile_x + 1, tile_y + 1, tile_x + size * scale - 1, tile_y + size * scale - 1, 1)
				end
			end
		end
	end

	local center_x = x + MAP_SIZE / 2
	local center_y = y + MAP_SIZE / 2
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(center_x - 2, center_y - 2, 5, 5)
	render2d.DrawLine(center_x, center_y, center_x + forward.x * 30, center_y + forward.z * 30, 2)
	render2d.PopScissor()
end

local function get_panel_height(terrain)
	return (terrain.Levels + #STATES + 20) * LINE_HEIGHT + 12
end

local function draw_terrain(terrain, x, y)
	local s = terrain:GetStats()
	local t = s.totals
	local build = s.build
	local now = system.GetElapsedTime()

	if now - rate_time >= 1 then
		rate = (build.built - rate_built) / (now - rate_time)
		rate_built = build.built
		rate_time = now
	end

	local position = render3d.GetCamera():GetPosition()
	panel_x = x
	row_y = y
	local top = y
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.72)
	render2d.DrawRect(x, y, PANEL_WIDTH, get_panel_height(terrain))
	row_y = y + 6
	text(10, string.format("%s  grid %d  levels %d  %d builds/frame", terrain.Name, terrain.GridSize, terrain.Levels, terrain.BuildsPerFrame), HEAD)
	newline()
	text(10, string.format("camera %.0f %.0f %.0f", position.x, position.y, position.z), DIM)
	newline()
	newline()
	text(10, "build jobs", HEAD)
	newline()
	text(10, string.format("queue %d  (needed %d, refinement %d)", s.queue, t.needed, s.queue - t.needed), s.queue > 0 and WHITE or DIM)
	newline()
	local batch_count, chunk_count = terrain.Source:GetPendingCount()
	text(10, string.format("gpu jobs %d chunks in %d batches", chunk_count, batch_count))
	newline()
	text(10, string.format("built %d (%.1f/s)  wasted %d  requested %d", build.built, rate, build.wasted, build.requested))
	newline()
	text(10, string.format("latency avg %.0f ms  max %.0f ms", build.latency * 1000, build.max_latency * 1000), build.latency > 0.25 and WARN or WHITE)
	newline()
	text(10, string.format("chunks %d  textures waiting to be released %d  colliders %d", s.chunks, s.pending_releases, s.colliders))
	newline()
	newline()
	text(10, "tiles", HEAD)
	newline()
	text(10, string.format("%d tiles  %d built  %d hidden  %d retiring", t.tiles, t.built, t.hidden, t.retiring))
	newline()
	text(10, string.format("%d built but not drawn yet", t.waiting), t.waiting > 0 and WARN or DIM)
	newline()
	text(10, string.format("%d retiring tiles wait for the vegetation of their replacements", t.scatter_waiting), t.scatter_waiting > 0 and WARN or DIM)
	newline()
	newline()
	text(10, "lvl   size  want built drawn wait hid  que load retire", DIM)
	newline()

	for level = 0, terrain.Levels - 1 do
		local row = s.levels[level]
		text(
			10,
			string.format(
				"%3d %6d %5d %5d %5d %4d %3d %4d %4d %5d",
				level,
				terrain:GetLevelChunkSize(level),
				row.desired,
				row.built,
				row.drawn,
				row.waiting,
				row.hidden,
				row.queued,
				row.loading,
				row.retiring
			),
			row.desired > row.built and WARN or WHITE
		)
		newline()
	end

	newline()
	text(10, "map (white dot: camera, line: view direction)", DIM)
	newline()

	for i, state in ipairs(STATES) do
		render2d.SetColor(state.color.r, state.color.g, state.color.b, 1)
		render2d.DrawRect(panel_x + 10, row_y + 3, 9, 9)
		text(26, state.name, DIM)
		newline()
	end

	draw_map(terrain, x + PANEL_WIDTH + 14, top + 4)
end

event.AddListener("Draw2D", "terrain_stats", function()
	if not visible then return end

	local y = 10

	for terrain in pairs(Terrain.Active) do
		draw_terrain(terrain, 10, y)
		y = y + get_panel_height(terrain) + 10
	end
end)

commands.Add("terrain_stats", function()
	visible = not visible
end)

commands.Add("terrain_stats_map=number[3]", function(level)
	map_level = level
end)
