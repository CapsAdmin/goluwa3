-- flies over the island's jungle and counts where the vegetation is missing under the tiles that are shown near the camera:
-- a shown tile whose surface scatter has not looked at (hidden until a moment ago) or has units that are not baked yet. also
-- looks at every near tile that the terrain removes: were the tiles that replace it baked when it went
-- SPEED=60 SECONDS=30 luajit glw --3d --background lua "./test/harnesses/scatter/island_gaps.lua"
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local scatter = import("goluwa/render3d/scatter.lua")
local View = import("goluwa/render3d/view.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local island = import("addons/examples/lua/examples/render3d/island_terrain.lua")
local terrain = _G.island_terrain
local SPEED = tonumber(os.getenv("SPEED") or 60)
local SECONDS = tonumber(os.getenv("SECONDS") or 30)
local NEAR = 350
local v0 = island.GetView(5)
local view = View.New{Priority = 100, Position = v0.Position, Rotation = v0.Rotation, FOV = v0.FOV}:Activate()
local phase, phase_start, flight_start = "settle", system.GetElapsedTime(), nil
local pos = v0.Position:Copy()
local yaw_offset = 0
local totals = {frames = 0, gap_frames = 0, near_sum = 0, unvisited_sum = 0, unbaked_sum = 0}
local ages = {}
local removals = {count = 0, fully_baked = 0, none_baked = 0, partial = 0}
local last_print = 0
local created_start, baked_start
local waits = {}
local gap_watch, gap_frames_list, gap_seconds_list = {}, {}, {}
local pending_sum = {new = 0, nearer = 0, farther = 0, samples = 0}

local function status(tile)
	local entry = tile.entity.visual:GetRenderEntries()[1]

	if not entry then return nil end

	return scatter.GetSurfaceStatus(entry)
end

local original_remove = terrain.RemoveTile

terrain.RemoveTile = function(self, tile)
	if phase == "flight" and tile.entity and tile.level <= 3 and tile.replacement_keys and #tile.replacement_keys > 0 then
		local camera = render3d.GetCamera():GetPosition()
		local dx = math.max(tile.min_x - camera.x, 0, camera.x - tile.max_x)
		local dz = math.max(tile.min_z - camera.z, 0, camera.z - tile.max_z)

		if math.sqrt(dx * dx + dz * dz) < NEAR then
			removals.count = removals.count + 1

			if tile.scatter_wait then
				waits[#waits + 1] = system.GetFrameNumber() - tile.scatter_wait
			end
			local wanted_sum, baked_sum, unvisited = 0, 0, 0

			for _, key in ipairs(tile.replacement_keys) do
				local replacement = self.Tiles[key]
				local wanted, baked = status(replacement)

				if not wanted then
					unvisited = unvisited + 1
				else
					wanted_sum = wanted_sum + wanted
					baked_sum = baked_sum + baked
				end
			end

			local keys = {}

			for i, key in ipairs(tile.replacement_keys) do
				keys[i] = key
			end

			gap_watch[#gap_watch + 1] = {frame = system.GetFrameNumber(), time = system.GetElapsedTime(), keys = keys}

			if unvisited == 0 and baked_sum == wanted_sum then
				removals.fully_baked = removals.fully_baked + 1
			elseif baked_sum == 0 then
				removals.none_baked = removals.none_baked + 1
			else
				removals.partial = removals.partial + 1
			end
		end
	end

	return original_remove(self, tile)
end

event.AddListener("Update", "island_gaps", function(dt)
	local now = system.GetElapsedTime()

	if phase == "settle" then
		if now - phase_start > 12 and (scatter.pending_bakes or 1) == 0 then
			phase = "flight"
			flight_start = now
			created_start, baked_start = scatter.units_created or 0, scatter.bakes_done or 0
		end

		return
	end

	local camera = render3d.GetCamera()
	local forward = camera:GetRotation():GetForward()
	local length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
	pos = pos + Vec3(forward.x / length, 0, forward.z / length) * SPEED * dt
	view:SetPosition(pos)
	view:SetRotation(QuatDeg3(-6, 100 + math.sin((now - flight_start) * 0.3) * 40, 0))
	local position = camera:GetPosition()
	local near, unvisited, unbaked = 0, 0, 0
	pending_sum.new = pending_sum.new + scatter.pending_new
	pending_sum.nearer = pending_sum.nearer + scatter.pending_nearer
	pending_sum.farther = pending_sum.farther + scatter.pending_farther
	pending_sum.samples = pending_sum.samples + 1

	-- a removed tile's gap ends when the tiles that replaced it have all their vegetation
	for i = #gap_watch, 1, -1 do
		local watch = gap_watch[i]
		local done = true

		for _, key in ipairs(watch.keys) do
			local replacement = terrain.Tiles[key]

			if replacement and replacement.entity then
				local wanted, baked = status(replacement)

				if not wanted or baked < wanted then
					done = false

					break
				end
			end
		end

		if done then
			gap_frames_list[#gap_frames_list + 1] = system.GetFrameNumber() - watch.frame
			gap_seconds_list[#gap_seconds_list + 1] = system.GetElapsedTime() - watch.time
			table.remove(gap_watch, i)
		end
	end

	for _, tile in pairs(terrain.Tiles) do
		if tile.entity and not tile.hidden and not tile.retiring and tile.level <= 3 then
			local dx = math.max(tile.min_x - position.x, 0, position.x - tile.max_x)
			local dz = math.max(tile.min_z - position.z, 0, position.z - tile.max_z)
			local center_x, center_z = (tile.min_x + tile.max_x) / 2 - position.x, (tile.min_z + tile.max_z) / 2 - position.z
			local center_length = math.sqrt(center_x * center_x + center_z * center_z)
			local in_front = center_length < (tile.max_x - tile.min_x) or (center_x * forward.x + center_z * forward.z) / (center_length * length) > 0.5

			if math.sqrt(dx * dx + dz * dz) < NEAR and in_front then
				near = near + 1
				local wanted, baked = status(tile)

				if not wanted then
					unvisited = unvisited + 1
					ages[math.min(system.GetFrameNumber() - (tile.shown or 0), 60)] = (ages[math.min(system.GetFrameNumber() - (tile.shown or 0), 60)] or 0) + 1
				elseif baked < wanted then
					unbaked = unbaked + 1
					local age = math.min(system.GetFrameNumber() - (tile.shown or 0), 60)
					ages[age] = (ages[age] or 0) + 1
				end
			end
		end
	end

	totals.frames = totals.frames + 1
	totals.near_sum = totals.near_sum + near
	totals.unvisited_sum = totals.unvisited_sum + unvisited
	totals.unbaked_sum = totals.unbaked_sum + unbaked

	if unvisited + unbaked > 0 then totals.gap_frames = totals.gap_frames + 1 end

	if now - last_print >= 3 then
		last_print = now
		print(string.format("t=%.0f near tiles %d, not looked at by scatter %d, units not baked %d | pending bakes %d units %d", now - flight_start, near, unvisited, unbaked, scatter.pending_bakes, scatter.unit_count))
	end

	if now - flight_start > SECONDS then
		local buckets = {0, 0, 0, 0}

		for age, n in pairs(ages) do
			local b = age < 5 and 1 or age < 15 and 2 or age < 60 and 3 or 4
			buckets[b] = buckets[b] + n
		end

		print(string.format("GAPS speed %d: %.1f%% of frames had a gap, mean %.2f of %.1f near tiles lack vegetation (%.2f not looked at, %.2f partly baked)", SPEED, totals.gap_frames / totals.frames * 100, (totals.unvisited_sum + totals.unbaked_sum) / totals.frames, totals.near_sum / totals.frames, totals.unvisited_sum / totals.frames, totals.unbaked_sum / totals.frames))
		print(string.format("GAPS age since shown of the tiles that lack it (frame counts): <5 %d, 5-14 %d, 15-59 %d, 60+ %d", buckets[1], buckets[2], buckets[3], buckets[4]))
		print(string.format("GAPS near tiles removed: %d, replacements fully baked %d, partly %d, none baked %d", removals.count, removals.fully_baked, removals.partial, removals.none_baked))
		table.sort(gap_seconds_list)
		local n = #gap_seconds_list
		print(string.format("GAPS time until the replacements of a removed near tile have all their vegetation (%d of %d finished): median %.2fs p90 %.2fs max %.2fs", n, removals.count, gap_seconds_list[math.ceil(n / 2)] or -1, gap_seconds_list[math.ceil(n * 0.9)] or -1, gap_seconds_list[n] or -1))
		table.sort(waits)
		local timed_out = 0

		for _, w in ipairs(waits) do
			if w >= terrain.ScatterWaitFrames then timed_out = timed_out + 1 end
		end

		print(string.format("GAPS old tiles waited for the vegetation of their replacements (%d near ones): median %d frames, p90 %d, max %d, %d ran into the %d frame limit", #waits, waits[math.ceil(#waits / 2)] or -1, waits[math.ceil(#waits * 0.9)] or -1, waits[#waits] or -1, timed_out, terrain.ScatterWaitFrames))
		print(string.format("GAPS units created %.0f/s, bakes done %.0f/s (budget %d a frame, %.0f fps)", ((scatter.units_created or 0) - created_start) / SECONDS, ((scatter.bakes_done or 0) - baked_start) / SECONDS, scatter.BAKE_BUDGET, totals.frames / SECONDS))
		print(string.format("GAPS mean pending bakes: new or changed %.0f, camera came nearer %.0f, camera went farther %.0f", pending_sum.new / pending_sum.samples, pending_sum.nearer / pending_sum.samples, pending_sum.farther / pending_sum.samples))
		system.ShutDown(0)
	end
end)
