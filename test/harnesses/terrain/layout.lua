-- one terrain layout on the alpine terrain (no scatter, no physics): how many tiles and triangles it needs, how long it
-- takes to load, what a frame costs, and four fixed views as pngs for comparing layouts
-- LEVELS=7 GRID=6 TAG=l7g6 luajit glw --3d --background lua "./test/harnesses/terrain/layout.lua"
-- test/harnesses/terrain/layout.sh runs a list of layouts and prints one summary line each
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Shot = import("goluwa/render3d/shot.lua")
local View = import("goluwa/render3d/view.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local LEVELS = tonumber(os.getenv("LEVELS") or 7)
local GRID = tonumber(os.getenv("GRID") or 8)
local SAMPLES = tonumber(os.getenv("SAMPLES") or 65)
local TAG = os.getenv("TAG") or string.format("l%dg%d", LEVELS, GRID)
local start = system.GetElapsedTime()
_G.TERRAIN_OVERRIDES = {Levels = LEVELS, GridSize = GRID, Samples = SAMPLES, ScatterSet = false, Physics = false}
import("addons/examples/lua/examples/render3d/alpine_terrain.lua")
local terrain = _G.alpine_terrain
local views = {
	{Position = Vec3(0, 2600, 0), Rotation = QuatDeg3(-25, 0, 0), FOV = math.rad(70), ExposureLock = 14},
	{Position = Vec3(0, 2600, 0), Rotation = QuatDeg3(-25, 270, 0), FOV = math.rad(70), ExposureLock = 14},
	{Position = Vec3(0, 900, 0), Rotation = QuatDeg3(-8, 0, 0), FOV = math.rad(70), ExposureLock = 14},
	{Position = Vec3(0, 900, 0), Rotation = QuatDeg3(-8, 270, 0), FOV = math.rad(70), ExposureLock = 14},
}
local settled_at
local phase = "loading"
local summary
local frames, gpu_sum, cpu_sum, measure_start = 0, 0, 0, nil
local measure_view

local function capture_views()
	Shot.Sequence(views, function(texture, info, i)
		print(texture:SaveWithoutAlpha("storage/logs/layout_" .. TAG .. "_" .. i .. ".png"))
	end, {settle = 5}, function()
		print(
			string.format(
				"LAYOUT %s levels %d grid %d samples %d tiles %d triangles %.2fM load %.1fs gpu_frame_ms %.2f frame_ms %.2f",
				TAG,
				LEVELS,
				GRID,
				SAMPLES,
				summary.tiles,
				summary.triangles,
				summary.load,
				gpu_sum / frames,
				cpu_sum / frames
			)
		)
		system.ShutDown(0)
	end)
end

event.AddListener("Update", "layout_run", function(dt)
	local now = system.GetElapsedTime()

	if phase == "loading" then
		local stats = terrain:GetStats()
		local t = stats.totals

		if t.tiles > 0 and t.loading == 0 and t.queued == 0 and t.waiting == 0 and t.hidden == 0 and stats.queue == 0 then
			settled_at = settled_at or now

			if now - settled_at > 1 then
				local cells = SAMPLES - 1
				summary = {
					tiles = t.tiles,
					triangles = t.tiles * (2 * cells * cells + 8 * cells) / 1e6,
					load = settled_at - start,
				}
				measure_view = View.New(table.merge({Priority = 100}, views[1])):Activate()
				measure_start = now
				phase = "measuring"
			end
		end
	elseif phase == "measuring" then
		if now - measure_start < 3 then return end

		frames = frames + 1
		gpu_sum = gpu_sum + (gpu_timing.GetRawMilliseconds("gpu_frame") or 0)
		cpu_sum = cpu_sum + dt * 1000

		if frames >= 200 then
			measure_view:Remove()
			phase = "views"
			capture_views()
		end
	end
end)
