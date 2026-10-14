-- how fast the vegetation that the camera sees fills in after a jump on the island: teleports to places over the jungle and the
-- beach with a fixed view, and prints the time until every shown tile in the view within 500 m has all its vegetation baked
-- (and the tiles that are wanted there are shown), and the time until nothing is left to bake at all
-- OLD=1 bakes by the distance alone, like before the view was used
-- luajit glw --3d --background lua "./test/harnesses/scatter/island_fill.lua"
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local scatter = import("goluwa/render3d/scatter.lua")
local View = import("goluwa/render3d/view.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local island = import("addons/examples/lua/examples/render3d/island_terrain.lua")
local terrain = _G.island_terrain
local NEAR = 500

if os.getenv("BUILDS") then terrain.BuildsPerFrame = tonumber(os.getenv("BUILDS")) end

if os.getenv("BAKE_BUDGET") then scatter.BAKE_BUDGET = tonumber(os.getenv("BAKE_BUDGET")) end

if os.getenv("OLD") then
	scatter.view_priority.OutsidePenalty = 0
	scatter.view_priority.PredictSeconds = 0
end

local v0 = island.GetView(5)
local view = View.New{Priority = 100, Position = v0.Position, Rotation = v0.Rotation, FOV = v0.FOV}:Activate()
local spots = {
	{Vec3(1500, 120, -200), 100},
	{Vec3(2250, 150, 100), 200},
	{Vec3(1100, 150, 300), 20},
	{Vec3(1700, 120, -500), 280},
	{Vec3(2000, 150, 500), 90},
	{Vec3(900, 150, -100), 330},
}
local fill_frames, fill_time = 0, 0
local index, phase, phase_start = 0, "settle", system.GetElapsedTime()
local results = {}
local marks

local function in_view_gap(camera)
	local position = camera:GetPosition()
	local forward = camera:GetRotation():GetForward()
	local length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
	local missing, total, tiles_missing = 0, 0, 0

	for key, want in pairs(terrain.Desired) do
		local dx = math.max(want.min_x - position.x, 0, position.x - want.max_x)
		local dz = math.max(want.min_z - position.z, 0, position.z - want.max_z)

		if want.level <= 3 and math.sqrt(dx * dx + dz * dz) < NEAR then
			local center_x, center_z = (want.min_x + want.max_x) / 2 - position.x, (want.min_z + want.max_z) / 2 - position.z
			local center_length = math.sqrt(center_x * center_x + center_z * center_z)
			local in_front = center_length < (want.max_x - want.min_x) or (center_x * forward.x + center_z * forward.z) / (center_length * length) > 0.5

			if in_front then
				total = total + 1
				local tile = terrain.Tiles[key]

				if not tile or not tile.entity or tile.hidden then
					missing = missing + 1
					tiles_missing = tiles_missing + 1
				elseif tile.scatter_entry then
					local wanted, baked = scatter.GetSurfaceStatus(tile.scatter_entry)

					if not wanted or baked < wanted then missing = missing + 1 end
				end
			end
		end
	end

	return missing, total, tiles_missing
end

event.AddListener("Update", "island_fill", function(dt)
	local now = system.GetElapsedTime()

	if phase == "filling" then
		fill_time = fill_time + dt
		if marks then marks.frame_dt = dt end
	end
	local camera = render3d.GetCamera()

	if phase == "settle" then
		if now - phase_start > 12 and (scatter.pending_bakes or 1) == 0 then phase = "jump" end
	elseif phase == "jump" then
		index = index + 1

		if index > #spots then
			local sums = {0, 0, 0}

			for _, r in ipairs(results) do
				sums[1] = sums[1] + r.view
				sums[2] = sums[2] + r.all
				sums[3] = sums[3] + r.tiles
			end

			table.sort(results, function(a, b) return a.view < b.view end)
			print(string.format("ISLANDFILL %s budget %d, %d tiles a frame over %d jumps: the tiles of the view are shown after mean %.2fs, the vegetation of them is baked after mean %.2fs (worst %.2fs), everything is baked after mean %.2fs, %.0f ms a frame while filling", os.getenv("OLD") and "old" or "new", scatter.BAKE_BUDGET, terrain.BuildsPerFrame, #results, sums[3] / #results, sums[1] / #results, results[#results].view, sums[2] / #results, fill_time / fill_frames * 1000))
			system.ShutDown(0)

			return
		end

		view:SetPosition(spots[index][1])
		view:SetRotation(QuatDeg3(-6, spots[index][2], 0))
		marks = {start = now}
		phase = "filling"
	elseif phase == "filling" then
		local missing, total, tiles_missing = in_view_gap(camera)

		if os.getenv("TIMELINE") and index == 2 and now - (marks.last_print or 0) >= 0.25 then
			marks.last_print = now
			local stats = terrain:GetStats()
			local t = stats.totals
			print(string.format("TL t=%.2f near tiles wanted %d (not shown %d) | terrain queue %d (needed %d) loading %d built %d hidden %d waiting %d | pending scatter bakes %d, frame %.0f ms", now - marks.start, total, tiles_missing, stats.queue, t.needed, t.loading, t.built, t.hidden, t.waiting, scatter.pending_bakes, (marks.frame_dt or 0) * 1000))
		end
		fill_frames = fill_frames + 1

		if not marks.tiles and now - marks.start > 0.2 and total > 0 and tiles_missing == 0 then marks.tiles = now - marks.start end

		if not marks.view and now - marks.start > 0.2 and total > 0 and missing == 0 then marks.view = now - marks.start end

		if not marks.all and now - marks.start > 0.5 and (scatter.pending_bakes or 1) == 0 then marks.all = now - marks.start end

		if (marks.view and marks.all) or now - marks.start > 40 then
			results[#results + 1] = {view = marks.view or 40, all = marks.all or 40, tiles = marks.tiles or 40}
			print(string.format("jump %d: tiles shown %s, view full %s, all baked %s", index, marks.tiles and string.format("%.2fs", marks.tiles) or "-", marks.view and string.format("%.2fs", marks.view) or "not within 40 s", marks.all and string.format("%.2fs", marks.all) or "not within 40 s"))
			phase = "jump"
		end
	end
end)
