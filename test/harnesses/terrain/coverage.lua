-- flies over the terrain_debug scene and every frame counts how many drawn tiles (the gpu culling's visible entries) cover
-- sample points ahead of the camera: 0 is a hole, 2 or more is an overlap. prints the frames where that happens
-- luajit glw --3d --background --validate lua "./test/harnesses/terrain/coverage.lua"
local View = import("goluwa/render3d/view.lua")
local visual = import("goluwa/entities/components/visual.lua").Library
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local debug_terrain = import("addons/examples/lua/examples/render3d/terrain_debug.lua")
local terrain = _G.terrain_debug
local SPEED = tonumber(os.getenv("SPEED") or 150)
local TURN = tonumber(os.getenv("TURN") or 60)
local SECONDS = tonumber(os.getenv("SECONDS") or 25)
local view = View.New{Priority = 100, Position = Vec3(0, 60, 0), Rotation = QuatDeg3(-10, 0, 0), FOV = math.rad(75)}:Activate()
local drawn = {}
local last_records, last_ptr, last_count, last_cull
local original = visual.GetVisibleMainGPUEntries
import("goluwa/test.lua").GetCurrentRunningTestName = function() return "coverage" end

function visual.GetVisibleMainGPUEntries()
	local records, ptr, count, cull = original()
	table.clear(drawn)
	last_records, last_count, last_cull = records, count, cull
	last_ptr = ptr

	if records and ptr then
		for i = 0, count - 1 do
			local record = records[tonumber(ptr[i]) + 1]
			local name = record and record.component and record.component.Owner and record.component.Owner:GetName()
			local level, x, z = tostring(name):match("terrain_debug_tile_(%d+)_(%-?%d+)_(%-?%d+)")

			if level then drawn[#drawn + 1] = {level = tonumber(level), x = tonumber(x), z = tonumber(z)} end
		end
	end

	return records, ptr, count, cull
end

local function ground_height(x, z)
	return 18 * math.sin(x / 310) * math.cos(z / 260) + 7 * math.sin(x / 97 + z / 131) + 55 * math.sin(x / 1700 + 1) * math.sin(z / 1400) + 2 * math.sin(x / 23) * math.sin(z / 29)
end

local t = 0
local yaw = 0
local pos = Vec3(0, 60, 0)
local frames, bad_holes, bad_overlaps = 0, 0, 0
local ready_frames = 0

event.AddListener("Update", "terrain_coverage", function(dt)
	t = t + dt
	yaw = yaw + math.rad(TURN) * dt * math.sin(t * 0.7)
	pos = pos + Vec3(math.cos(yaw), 0, math.sin(yaw)) * SPEED * dt
	view:SetPosition(pos)
	view:SetRotation(QuatDeg3(-10, -math.deg(yaw) + 90, 0))
end)

local seen_at, latencies = {}, {}

event.AddListener("PostDraw", "terrain_latency", function()
	local frame = system.GetFrameNumber()
	local in_drawn = {}

	for _, tile in ipairs(drawn) do
		in_drawn[tile.level .. ":" .. tile.x .. ":" .. tile.z] = true
	end

	local camera = render3d.GetCamera()

	for key, tile in pairs(terrain.Tiles) do
		if tile.entity and tile.shown and not tile.hidden and not seen_at[tile] then
			local size = terrain:GetLevelChunkSize(tile.level)
			local screen = camera:WorldPositionToScreen(Vec3((tile.chunk_x + 0.5) * size, 0, (tile.chunk_z + 0.5) * size))

			if in_drawn[key] then
				seen_at[tile] = true
				latencies[#latencies + 1] = frame - tile.shown
			end
		end
	end
end)

event.AddListener("PostDraw", "terrain_coverage_check", function()
	if t < 8 then return end

	frames = frames + 1
	local holes, overlaps = {}, {}

	local camera = render3d.GetCamera()
	local width, height = render.GetWidth(), render.GetHeight()

	for k = 1, 400 do
		local a = k * 2.399963
		local dist = 15 * 1.012 ^ k
		local px, pz = pos.x + math.cos(a) * dist, pos.z + math.sin(a) * dist
		local screen = camera:WorldPositionToScreen(Vec3(px, ground_height(px, pz), pz))
		local in_view = screen and screen.x > width * 0.1 and screen.x < width * 0.9 and screen.y > height * 0.1 and screen.y < height * 0.9

		if not in_view then goto continue end

		local n = 0

		for _, tile in ipairs(drawn) do
			local size = terrain:GetLevelChunkSize(tile.level)

			if px >= tile.x * size and px < (tile.x + 1) * size and pz >= tile.z * size and pz < (tile.z + 1) * size then
				n = n + 1
			end
		end

		if n == 0 then
			local why = "no desired tile"

			for key, want in pairs(terrain.Desired) do
				local size = terrain:GetLevelChunkSize(want.level)

				if px >= want.chunk_x * size and px < (want.chunk_x + 1) * size and pz >= want.chunk_z * size and pz < (want.chunk_z + 1) * size then
					local tile = terrain.Tiles[key]
					local v = tile and tile.entity and tile.entity.visual
					why = string.format("L%d %s entity=%s hidden=%s retiring=%s visible=%s gpu_entry=%s age=%s", want.level, key, tostring(tile and tile.entity ~= nil), tostring(tile and tile.hidden), tostring(tile and tile.retiring), tostring(v and v.Visible), tostring(v and v.main_gpu_entry_offset), tostring(tile and tile.entity and (system.GetFrameNumber() - (tile.shown or 0))))
					local box = v and v:GetWorldAABB()

					if v and last_records then
						local off = v.main_gpu_entry_offset
						local rec = off and last_records[off + 1]
						local found = false

						for i = 0, last_count - 1 do
							if tonumber(last_ptr[i]) == off then found = true end
						end

						why = why .. string.format(" rec=%s samecomp=%s inlist=%s listcount=%d entries=%d", tostring(rec ~= nil), tostring(rec and rec.component == v), tostring(found), last_count, #last_records)
					end

					if box then why = why .. string.format(" aabb x%.0f..%.0f y%.0f..%.0f z%.0f..%.0f", box.min_x, box.max_x, box.min_y, box.max_y, box.min_z, box.max_z) end
				end
			end

			holes[#holes + 1] = string.format("dist %.0f %s", dist, why)
		elseif n > 1 then overlaps[#overlaps + 1] = n end

		::continue::
	end

	if #holes > 0 then bad_holes = bad_holes + 1 end
	if #overlaps > 0 then bad_overlaps = bad_overlaps + 1 end

	if #holes > 0 or #overlaps > 0 then
		print(string.format("frame %d t=%.2f holes=%d overlaps=%d drawn=%d %s", system.GetFrameNumber(), t, #holes, #overlaps, #drawn, holes[1] or ""))
	end

	if t > SECONDS then
		table.sort(latencies)
		print("latency frames median", latencies[math.floor(#latencies / 2)], "p90", latencies[math.floor(#latencies * 0.9)], "max", latencies[#latencies], "n", #latencies)
		print(string.format("frames %d, with holes %d, with overlaps %d", frames, bad_holes, bad_overlaps))
		system.ShutDown(0)
	end
end)
