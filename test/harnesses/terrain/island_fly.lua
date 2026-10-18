-- flies the island example around the mountain at KMH (300) and prints frame times per 2 s window, the lua heap growth
-- and what the collector and the vulkan frees cost. NOGC=1 stops the collector, SECONDS, KMH, RADIUS, HEIGHT
-- luajit glw --3d --background lua "./test/harnesses/terrain/island_fly.lua"
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local island = import("addons/examples/lua/examples/render3d/island_terrain.lua")
local SECONDS = tonumber(os.getenv("SECONDS") or 40)
local WARMUP = tonumber(os.getenv("WARMUP") or 12)
local GetTime = system.GetTime
if os.getenv("NOGC") then collectgarbage("stop") end
local t, started, window, all = 0, false, {}, {}
-- ALLOC=1 stops the collector and prints MB allocated per second by every event listener, the terrain and scene bvh methods
local alloc, alloc_calls, alloc_on = {}, {}, false
local cpu, cpu_prev, vk_prev = {}, {}, {}
local function wrap_allocs()
	local function wrap(object, name, label)
		local original = object[name]
		if not original or alloc[label] then return end
		alloc[label], alloc_calls[label], cpu[label] = 0, 0, 0
		object[name] = function(...)
			if not alloc_on then return original(...) end
			local before, t0 = collectgarbage("count"), GetTime()
			local a, b, c, d = original(...)
			cpu[label] = cpu[label] + GetTime() - t0
			alloc[label] = alloc[label] + collectgarbage("count") - before
			alloc_calls[label] = alloc_calls[label] + 1
			return a, b, c, d
		end
	end
	for event_type, list in pairs(event.active) do
		for _, config in ipairs(list) do
			if not config.a_wrapped then
				config.a_wrapped = true
				local cb = config.callback
				local label = "ev " .. tostring(event_type) .. "->" .. tostring(config.id)
				alloc[label], alloc_calls[label], cpu[label] = 0, 0, 0
				config.callback = function(...)
					if not alloc_on then return cb(...) end
					local before, t0 = collectgarbage("count"), GetTime()
					local a, b, c, d = cb(...)
					cpu[label] = cpu[label] + GetTime() - t0
					alloc[label] = alloc[label] + collectgarbage("count") - before
					alloc_calls[label] = alloc_calls[label] + 1
					return a, b, c, d
				end
			end
		end
	end
	local terrain = _G.island_terrain
	for _, name in ipairs{"UpdateTiles", "GatherDesiredTiles", "ProcessBuildQueue", "CreateTile", "RemoveTile", "RetireTiles", "ProcessPendingReleases", "IsTileReplaced", "IsTileBlocked", "AreReplacementsDrawn", "AcquireChunk", "ReleaseChunk"} do wrap(terrain, name, "terrain." .. name) end
	for _, name in ipairs{"Update", "Submit", "CompleteBatch", "ReleaseChunk", "RecycleTexture"} do wrap(terrain.Source, name, "source." .. name) end
	local tiles = import("goluwa/terrain/tiles.lua")
	for k, v in pairs(tiles) do if type(v) == "function" then wrap(tiles, k, "tiles." .. k) end end
	local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
	for _, name in ipairs{"UploadVertexArray", "BuildAABB", "SetGridCells", "Remove", "OnRemove"} do wrap(Polygon3D, name, "polygon." .. name) end
	local Entity = import("goluwa/entities/entity.lua")
	for _, name in ipairs{"New", "AddComponent", "Remove"} do wrap(Entity, name, "entity." .. name) end
end
-- every vulkan call that creates, frees or waits, with its time and count
local vk_cpu, vk_calls = {}, {}
local function wrap_vulkan()
	local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
	local real = vulkan.lib
	local prefixes = {"vkAllocate", "vkFree", "vkCreate", "vkDestroy", "vkWait", "vkDeviceWait", "vkQueue", "vkMap", "vkUnmap", "vkBind", "vkReset", "vkGetFence", "vkAcquire"}
	vulkan.lib = setmetatable({}, {
		__index = function(_, name)
			local original = real[name]
			if type(name) ~= "string" then return original end
			local watched = false
			for _, prefix in ipairs(prefixes) do if name:find("^" .. prefix) then watched = true end end
			if not watched then return original end
			vk_cpu[name], vk_calls[name] = 0, 0
			local f = function(...)
				if not alloc_on then return original(...) end
				local t0 = GetTime()
				local a = original(...)
				vk_cpu[name] = vk_cpu[name] + GetTime() - t0
				vk_calls[name] = vk_calls[name] + 1
				return a
			end
			rawset(vulkan.lib, name, f)
			return f
		end,
	})
end
local mem_labels = {}
local function wrap_memory()
	local Memory = import("goluwa/render/vulkan/internal/memory.lua")
	local new = Memory.New
	Memory.New = function(device, config)
		if alloc_on then
			local label = tostring(config.label):gsub("size=%d+", ""):gsub("%d+", "#")
			local row = mem_labels[label] or {0, 0}
			mem_labels[label] = row
			row[1] = row[1] + 1
			row[2] = row[2] + tonumber(config.size)
		end
		return new(device, config)
	end
end
local mesh_sources = {}
local function wrap_mesh()
	local Memory = import("goluwa/render/vulkan/internal/memory.lua")
	local new = Memory.New
	Memory.New = function(device, config)
		if alloc_on and tostring(config.label):find("mesh vert") then
			local parts = {}
			for level = 3, 12 do
				local info = debug.getinfo(level, "Sl")
				if not info then break end
				parts[#parts + 1] = info.short_src:gsub("^.*/", "") .. ":" .. info.currentline
			end
			local key = table.concat(parts, " < ")
			mesh_sources[key] = (mesh_sources[key] or 0) + 1
		end
		return new(device, config)
	end
end
-- time and count of the deferred vulkan releases (the destroys and frees queued by the __gc of the vulkan objects)
local flush = {calls = 0, ready = 0, time = 0, max = 0}
local function wrap_flush()
	local Device = getmetatable(import("goluwa/render/render.lua").GetDevice()).__index
	local original = Device.FlushDeferredReleases
	Device.FlushDeferredReleases = function(self, force)
		local pending = self.deferred_releases and #self.deferred_releases or 0
		local t0 = GetTime()
		local a = original(self, force)
		local dt = GetTime() - t0
		flush.calls, flush.time, flush.max = flush.calls + 1, flush.time + dt, math.max(flush.max, dt)
		flush.ready = flush.ready + pending - (self.deferred_releases and #self.deferred_releases or 0)
		return a
	end
end
local last_print, mem_start, last_mem = 0, 0, 0
event.AddListener("Update", "island_fly_harness", function(dt)
	t = t + dt
	if t < WARMUP then return end
	if not started then
		started = true
		if os.getenv("ALLOC") then wrap_mesh() wrap_memory() wrap_vulkan() wrap_allocs() collectgarbage("collect") if not os.getenv("KEEPGC") then collectgarbage("stop") end alloc_on = true end
		island.Fly(tonumber(os.getenv("KMH") or 300), tonumber(os.getenv("RADIUS") or 1100), tonumber(os.getenv("HEIGHT") or 60))
		wrap_flush()
		if os.getenv("PROF") then _G.PROF.Start("island_fly", {frames = 100000, shutdown = false, trace_recorder = false}) end
		last_print, mem_start, last_mem = t, collectgarbage("count"), collectgarbage("count")
		return
	end
	if alloc_on then
		if dt > 0.045 then
			local rows = {}
			for k, v in pairs(cpu) do
				local d = v - (cpu_prev[k] or 0)
				if d > 0.004 then rows[#rows + 1] = {k, d} end
			end
			table.sort(rows, function(a, b) return a[2] > b[2] end)
			local parts = {}
			for i = 1, math.min(#rows, 7) do parts[#parts + 1] = string.format("%s %.0f", rows[i][1], rows[i][2] * 1000) end
			local vk = {}
			for k, v in pairs(vk_cpu) do if v - (vk_prev[k] or 0) > 0.003 then vk[#vk + 1] = string.format("%s %.0f", k, (v - vk_prev[k]) * 1000) end end
			print(string.format("SLOW %.0f ms: %s | vk: %s", dt * 1000, table.concat(parts, ", "), table.concat(vk, ", ")))
		end
		for k, v in pairs(cpu) do cpu_prev[k] = v end
		for k, v in pairs(vk_cpu) do vk_prev[k] = v end
	end
	window[#window + 1] = dt
	all[#all + 1] = dt
	if t - last_print >= 2 then
		last_print = t
		table.sort(window)
		local n, sum = #window, 0
		for _, v in ipairs(window) do sum = sum + v end
		local mem = collectgarbage("count")
		print(string.format("t=%4.1f frames %3d avg %5.1f p50 %5.1f p95 %5.1f max %6.1f ms | heap %.0f MB (%+.0f MB)", t, n, sum / n * 1000, window[math.ceil(n * 0.5)] * 1000, window[math.ceil(n * 0.95)] * 1000, window[n] * 1000, mem / 1024, (mem - last_mem) / 1024))
		last_mem = mem
		window = {}
	end
	if t > WARMUP + SECONDS then
		if os.getenv("PROF") then _G.PROF.Stop() end
		if alloc_on then
			for label, row in pairs(mem_labels) do print(string.format("MEM %-60s %6.1f allocs/frame %7.2f MB/s", label, row[1] / #all, row[2] / 1048576 / SECONDS)) end
			for k, v in pairs(mesh_sources) do print(string.format("MESH %-99s %5.2f/frame", k, v / #all)) end
			local vk_rows = {}
			for k in pairs(vk_cpu) do if vk_calls[k] > 0 then vk_rows[#vk_rows + 1] = k end end
			table.sort(vk_rows, function(a, b) return vk_cpu[a] > vk_cpu[b] end)
			for i = 1, math.min(#vk_rows, 12) do print(string.format("VK %-34s %7.2f ms/frame %7.1f calls/frame %7.1f us/call", vk_rows[i], vk_cpu[vk_rows[i]] / #all * 1000, vk_calls[vk_rows[i]] / #all, vk_cpu[vk_rows[i]] / vk_calls[vk_rows[i]] * 1e6)) end
			local rows = {}
			for k, v in pairs(alloc) do if v > 0 or cpu[k] > 0.05 then rows[#rows + 1] = k end end
			table.sort(rows, function(a, b) return cpu[a] > cpu[b] end)
			for i = 1, math.min(#rows, 25) do print(string.format("ALLOC %-55s %7.1f MB/s %7.1f KB/call %6.1f calls/frame %6.2f ms/frame", rows[i], alloc[rows[i]] / 1024 / SECONDS, alloc[rows[i]] / alloc_calls[rows[i]], alloc_calls[rows[i]] / #all, cpu[rows[i]] / #all * 1000)) end
		end
		table.sort(all)
		local n, over = #all, 0
		for _, v in ipairs(all) do if v > 0.0167 * 1.3 then over = over + 1 end end
		print(string.format("FLUSH calls %d released %d total %.1f ms max %.1f ms", flush.calls, flush.ready, flush.time * 1000, flush.max * 1000))
		print(string.format("overall %d frames p50 %.1f p95 %.1f p99 %.1f max %.1f ms, %d frames over 22 ms, heap grew %.0f MB", n, all[math.ceil(n * 0.5)] * 1000, all[math.ceil(n * 0.95)] * 1000, all[math.ceil(n * 0.99)] * 1000, all[n] * 1000, over, (collectgarbage("count") - mem_start) / 1024))
		system.ShutDown(0)
	end
end)
