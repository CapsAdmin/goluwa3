if not RENDER_2D then return end

local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local commands = import("goluwa/cli/commands.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Terrain = import("goluwa/terrain/terrain.lua")
local perf = import("lua/perf.lua")
local MAP_SIZE = 200
local TEXT_DIM = Color(0.5, 0.55, 0.65, 1)
local STATES = {
	{name = "drawn", color = Color(0.25, 0.8, 0.35, 0.55)},
	{name = "built, not drawn yet", color = Color(0.95, 0.85, 0.2, 0.7)},
	{name = "hidden (blocked)", color = Color(0.9, 0.5, 0.15, 0.7)},
	{name = "loading (gpu job)", color = Color(0.2, 0.8, 0.95, 0.75)},
	{name = "queued, nothing under it", color = Color(0.95, 0.25, 0.3, 0.75)},
	{name = "queued, refines a drawn tile", color = Color(0.35, 0.4, 0.95, 0.6)},
}
local map_level = 3
local rate_time = 0
local rate_built = 0
local rate = 0

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
	render2d.SetColor(0.03, 0.04, 0.07, 0.92)
	render2d.DrawRect(x - 4, y - 4, MAP_SIZE + 8, MAP_SIZE + 8)
	render2d.PushClipRect(x, y, MAP_SIZE, MAP_SIZE)

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
	render2d.PopClip()
end

local function build_rows()
	local rows = {}

	for terrain in pairs(Terrain.Active) do
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
		local batch_count, chunk_count = terrain.Source:GetPendingCount()
		rows[#rows + 1] = {
			label = string.format(
				"%s  grid %d  levels %d  %d builds/frame",
				terrain.Name,
				terrain.GridSize,
				terrain.Levels,
				terrain.BuildsPerFrame
			),
			color = "head",
		}
		rows[#rows + 1] = {
			label = string.format("camera %.0f %.0f %.0f", position.x, position.y, position.z),
			color = "dim",
		}
		rows[#rows + 1] = {label = "build jobs", color = "head"}
		rows[#rows + 1] = {
			label = string.format("queue %d  (needed %d, refinement %d)", s.queue, t.needed, s.queue - t.needed),
			color = s.queue == 0 and "dim" or nil,
		}
		rows[#rows + 1] = {
			label = string.format("gpu jobs %d chunks in %d batches", chunk_count, batch_count),
		}
		rows[#rows + 1] = {
			label = string.format(
				"built %d (%.1f/s)  wasted %d  requested %d",
				build.built,
				rate,
				build.wasted,
				build.requested
			),
		}
		rows[#rows + 1] = {
			label = string.format(
				"latency avg %.0f ms  max %.0f ms",
				build.latency * 1000,
				build.max_latency * 1000
			),
			color = build.latency > 0.25 and "warn" or nil,
		}
		rows[#rows + 1] = {
			label = string.format(
				"chunks %d  textures waiting to be released %d  colliders %d",
				s.chunks,
				s.pending_releases,
				s.colliders
			),
		}
		rows[#rows + 1] = {label = "tiles", color = "head"}
		rows[#rows + 1] = {
			label = string.format(
				"%d tiles  %d built  %d hidden  %d retiring",
				t.tiles,
				t.built,
				t.hidden,
				t.retiring
			),
		}
		rows[#rows + 1] = {
			label = string.format("%d built but not drawn yet", t.waiting),
			color = t.waiting > 0 and "warn" or "dim",
		}
		rows[#rows + 1] = {
			label = string.format(
				"%d retiring tiles wait for the vegetation of their replacements",
				t.scatter_waiting
			),
			color = t.scatter_waiting > 0 and "warn" or "dim",
		}
		rows[#rows + 1] = {
			label = "levels: want / built / drawn / wait / hidden / queued / loading / retiring",
			color = "dim",
		}

		for level = 0, terrain.Levels - 1 do
			local row = s.levels[level]
			rows[#rows + 1] = {
				label = string.format(
					"%d  size %d   %d  %d  %d  %d  %d  %d  %d  %d",
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
				color = row.desired > row.built and "warn" or nil,
			}
		end
	end

	if not rows[1] then rows[1] = {label = "no terrain running", color = "dim"} end

	return rows
end

local META = Panel:CreateTemplate("terrain_map")
META.CMP.transform = {}
META.CMP.layout = {GrowWidth = 0, FitWidth = false, FitHeight = false}
META.CMP.visual = {}

function META.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

function META:OnDraw()
	local size = self.transform:GetSize()
	render2d.SetTexture(nil)
	render2d.SetColor(0.03, 0.04, 0.07, 0.92)
	render2d.DrawRoundedRect(0, 0, size.x, size.y, 10)
	local terrain = next(Terrain.Active)

	if not terrain then return end

	draw_map(terrain, 6, 6)
	local y = MAP_SIZE + 22

	for _, state in ipairs(STATES) do
		render2d.SetTexture(nil)
		render2d.SetColor(state.color.r, state.color.g, state.color.b, 1)
		render2d.DrawRect(10, y + 3, 9, 9)
		render2d.DrawText{
			text = state.name,
			x = 26,
			y = y + 7,
			align_y = "cap_center",
			size = 11,
			foreground_color = TEXT_DIM,
		}
		y = y + 14
	end

	render2d.DrawText{
		text = "white dot: camera, line: view",
		x = 10,
		y = y + 8,
		align_y = "cap_center",
		size = 11,
		foreground_color = TEXT_DIM,
	}
end

META:Register()
local TerrainMap = react.Element(META)
perf.RegisterTab(
	"TERRAIN",
	7,
	react.Component(
		||->ui.Row{layout = {ChildGap = 8}}{
			ui.StatTable{Size = Vec2(440, 470), Rows = react.UsePoll(build_rows, perf.POLL_INTERVAL)},
			TerrainMap{Size = Vec2(212, 470)},
		}
	)
)

commands.Add("terrain_stats", function()
	perf.PrintRows(build_rows())
end)

commands.Add("terrain_stats_map=number[3]", function(level)
	map_level = level
end)
