-- how fast the part of the terrain the camera sees fills in: teleports far away with a fixed view and prints the time until
-- 50%, 95% and 100% of the points on screen are covered by a shown tile, then flies fast and prints the mean covered share
-- OLD=1 ranks the way it did before the view was used (no prediction, everything counts as in view)
-- luajit glw --3d --background lua "./test/harnesses/terrain/fill.lua"
local View = import("goluwa/render3d/view.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
import("addons/examples/lua/examples/render3d/terrain_debug.lua")
local terrain = _G.terrain_debug
local SPEED = tonumber(os.getenv("SPEED") or 600)
local TELEPORTS = tonumber(os.getenv("TELEPORTS") or 6)
local FLIGHT_SECONDS = tonumber(os.getenv("FLIGHT") or 14)

if os.getenv("OUT_K") then terrain.ViewPriority.OutsidePenalty = tonumber(os.getenv("OUT_K")) end

if os.getenv("OLD") then
	local original = terrain.UpdateTiles
	terrain.ViewPriority.PredictSeconds = 0

	terrain.UpdateTiles = function(self, position, forward)
		return original(self, position, forward, math.pi)
	end
end

local view = View.New{Priority = 100, Position = Vec3(0, 60, 0), Rotation = QuatDeg3(-10, 0, 0), FOV = math.rad(75)}:Activate()
local width, height = render.GetWidth(), render.GetHeight()
math.randomseed(7)

local function ground_height(x, z)
	return 18 * math.sin(x / 310) * math.cos(z / 260) + 7 * math.sin(x / 97 + z / 131) + 55 * math.sin(x / 1700 + 1) * math.sin(z / 1400) + 2 * math.sin(x / 23) * math.sin(z / 29)
end

local points = {}

local uncovered

local function covered_share(camera)
	local position = camera:GetPosition()
	local total, covered = 0, 0
	local shown = {}

	for _, tile in pairs(terrain.Tiles) do
		if tile.entity and not tile.hidden then shown[#shown + 1] = tile end
	end

	for k = 1, 500 do
		local a = k * 2.399963
		local dist = 15 * 1.0125 ^ k
		local px, pz = position.x + math.cos(a) * dist, position.z + math.sin(a) * dist
		local screen = camera:WorldPositionToScreen(Vec3(px, ground_height(px, pz), pz))

		if screen and screen.x > width * 0.05 and screen.x < width * 0.95 and screen.y > height * 0.05 and screen.y < height * 0.95 then
			total = total + 1
			local was = covered

			for i = 1, #shown do
				local tile = shown[i]

				if px >= tile.min_x and px < tile.max_x and pz >= tile.min_z and pz < tile.max_z then
					covered = covered + 1

					break
				end
			end

			if covered == was and uncovered then uncovered[#uncovered + 1] = {px, pz, dist} end
		end
	end

	return total > 0 and covered / total or 1, total
end

local debugged
local phase = "wait"
local teleport_index = 0
local teleport_time, marks = 0, {}
local results = {}
local flight_sum, flight_frames, flight_start, yaw, pos = 0, 0, 0, 0, nil
local settle_start

event.AddListener("Update", "terrain_fill", function(dt)
	local now = system.GetElapsedTime()
	local camera = render3d.GetCamera()

	if phase == "wait" then
		local stats = terrain:GetStats()

		if now > 6 and stats.totals.loading == 0 and stats.queue == 0 and stats.totals.waiting == 0 then
			if teleport_index >= TELEPORTS then
				phase = "flight"
				flight_start = now
				pos = Vec3(view:GetPosition().x, 60, view:GetPosition().z)
				yaw = math.rad(30)
				return
			end

			teleport_index = teleport_index + 1
			local angle = math.random() * math.pi * 2
			local distance = 8000 + math.random() * 40000
			local yaw_degrees = math.random() * 360
			view:SetPosition(Vec3(math.cos(angle) * distance, 60, math.sin(angle) * distance))
			view:SetRotation(QuatDeg3(-6, yaw_degrees, 0))
			teleport_time = now
			marks = {}
			phase = "filling"
		end
	elseif phase == "filling" then
		local share = covered_share(camera)

		for _, level in ipairs{0.5, 0.95, 1} do
			if not marks[level] and share >= level - 1e-9 then marks[level] = now - teleport_time end
		end

		if marks[1] or now - teleport_time > 25 then
			results[#results + 1] = marks
			print(string.format("teleport %d: 50%% %.2fs  95%% %.2fs  100%% %s", teleport_index, marks[0.5] or -1, marks[0.95] or -1, marks[1] and string.format("%.2fs", marks[1]) or "not within 25 s"))
			phase = "wait"
		end
	elseif phase == "flight" then
		yaw = yaw + math.rad(25) * dt * math.sin(now * 0.9)
		local forward = camera:GetRotation():GetForward()
		local length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
		local fx, fz = forward.x / length, forward.z / length

		if os.getenv("SIDEWAYS") then fx, fz = -fz, fx end

		if os.getenv("BACKWARD") then fx, fz = -fx, -fz end

		pos = pos + Vec3(fx, 0, fz) * SPEED * dt
		view:SetPosition(pos)
		view:SetRotation(QuatDeg3(-6, -math.deg(yaw) + 90, 0))
		local share = covered_share(camera)
		if os.getenv("DEBUGHOLES") and share < 0.9 and not debugged then
			debugged = true
			uncovered = {}
			covered_share(camera)
			local stats = terrain:GetStats()
			print(string.format("HOLES share %.2f queue %d needed %d loading %d", share, stats.queue, stats.totals.needed, stats.totals.loading))

			for i = 1, math.min(#uncovered, 6) do
				local px, pz, dist = uncovered[i][1], uncovered[i][2], uncovered[i][3]
				local info = "no desired tile"

				for key, want in pairs(terrain.Desired) do
					if px >= want.min_x and px < want.max_x and pz >= want.min_z and pz < want.max_z then
						local tile = terrain.Tiles[key]
						local entry = tile and tile.chunk_key and terrain.Chunks[tile.chunk_key]
						info = string.format("desired %s built %s hidden %s retiring %s priority %s loading %s", key, tostring(tile and tile.entity ~= nil), tostring(tile and tile.hidden), tostring(tile and tile.retiring), entry and string.format("%.3g", entry.priority) or "-", tostring(entry and entry.loading))
					end
				end

				print(string.format("HOLES point dist %.0f: %s", dist, info))
			end

			uncovered = nil
		end

		flight_sum = flight_sum + share
		flight_frames = flight_frames + 1

		if now - flight_start > FLIGHT_SECONDS then
			local sums = {0, 0, 0}

			for _, marks in ipairs(results) do
				sums[1] = sums[1] + (marks[0.5] or 25)
				sums[2] = sums[2] + (marks[0.95] or 25)
				sums[3] = sums[3] + (marks[1] or 25)
			end

			print(string.format("FILL %s mean over %d teleports: 50%% %.2fs 95%% %.2fs 100%% %.2fs | flight at %d m/s: mean covered share %.1f%% of on-screen points", os.getenv("OLD") and "old" or "new", #results, sums[1] / #results, sums[2] / #results, sums[3] / #results, SPEED, flight_sum / flight_frames * 100))
			system.ShutDown(0)
		end
	end
end)
