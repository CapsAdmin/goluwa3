-- flies faster and faster over terrain_debug with large teleports in between, and times where the frame goes: every
-- terrain stage (inclusive, they nest) plus the frame time. no --validate, that triples cpu time
-- luajit glw --3d --background lua "./test/harnesses/terrain/stress.lua"
-- SECONDS, MAX_SPEED (m/s at the end), TELEPORT (seconds between jumps, 0 for none), PROF=1 adds the jit profiler
local View = import("goluwa/render3d/view.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
_G.TERRAIN_BVH_LEVELS = tonumber(os.getenv("BVH_LEVELS"))
_G.TERRAIN_BVH_DELAY = tonumber(os.getenv("BVH_DELAY"))
local debug_terrain = import("addons/examples/lua/examples/render3d/terrain_debug.lua")
local terrain = _G.terrain_debug
local SECONDS = tonumber(os.getenv("SECONDS") or 40)
local MAX_SPEED = tonumber(os.getenv("MAX_SPEED") or 3000)
local TELEPORT = tonumber(os.getenv("TELEPORT") or 7)
local WARMUP = 8
local LEAN = os.getenv("LEAN")
if os.getenv("NOGC") then collectgarbage("stop") end

local GC_MODE = os.getenv("GC_MODE")

if GC_MODE == "tuned" then
	collectgarbage("setpause", 300)
	collectgarbage("setstepmul", 400)
elseif GC_MODE == "stepped" then
	collectgarbage("stop")
end
local view = View.New{Priority = 100, Position = Vec3(0, 60, 0), Rotation = QuatDeg3(-10, 0, 0), FOV = math.rad(75)}:Activate()
local acc, calls, mem = {}, {}, {}
local GetTime = system.GetTime

local function wrap(object, name, label)
	if LEAN then return end

	local original = object[name]
	label = label or name
	acc[label] = 0
	calls[label] = 0

	object[name] = function(...)
		local t0 = GetTime()
		local m0 = collectgarbage("count")
		local a, b = original(...)
		acc[label] = acc[label] + GetTime() - t0
		calls[label] = calls[label] + 1
		mem[label] = (mem[label] or 0) + math.max(collectgarbage("count") - m0, 0)
		return a, b
	end
end

for _, name in ipairs{
	"Update",
	"UpdateTiles",
	"GatherDesiredTiles",
	"ProcessBuildQueue",
	"RetireTiles",
	"CreateTile",
	"RemoveTile",
	"ProcessPendingReleases",
	"IsTileReplaced",
	"IsTileBlocked",
	"AreReplacementsDrawn",
} do
	wrap(terrain, name)
end

for _, name in ipairs{"Update", "Submit", "CompleteBatch", "RequestChunk"} do
	wrap(terrain.Source, name, "Source." .. name)
end

wrap(terrain.Source, "ReleaseChunk", "Source.ReleaseChunk")

if terrain.Physics then wrap(terrain.Physics, "Update", "Physics.Update") end

local render = import("goluwa/render/render.lua")
wrap(render, "BeginFrame", "render.BeginFrame")
wrap(render, "EndFrame", "render.EndFrame")

do
	local swapchain = render.target and render.target.swapchain

	if swapchain then
		local meta = getmetatable(swapchain)
		meta = meta.__index and (type(meta.__index) == "table" and meta.__index or meta) or meta
		wrap(meta, "GetNextImage", "swapchain.Acquire")
		wrap(meta, "Present", "swapchain.Present")
	end
end

if not LEAN then
	local original_call = event.Call
	local timed = {Draw = true, PostDraw = true, Update = true, PreFrame = true, FrameEnd = true, Draw3DGeometry = true, Draw2D = true}
	local depth = 0
	local totals = {}

	for name in pairs(timed) do
		acc["event." .. name] = 0
	end

	function event.Call(name, ...)
		if not timed[name] then return original_call(name, ...) end

		local label = "event." .. name
		local t0 = GetTime()
		local a, b = original_call(name, ...)
		acc[label] = acc[label] + GetTime() - t0
		return a, b
	end
end

if not LEAN then
	local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
	local real = vulkan.lib
	local wrapped = {}
	local watched = "^vk(Wait|Allocate|Free|Queue|Acquire|Map|Unmap|DeviceWait|GetFence|ResetFences|CreateBuffer|DestroyBuffer|CreateImage|DestroyImage|CmdBuildAcc|BuildAcc|GetQuery|ResetCommandPool|CreateImageView|CreateGraphics|CreateDescriptor|UpdateDescriptor|CreateFence)"
	local names = {"Wait", "Allocate", "Free", "Queue", "Acquire", "Map", "Unmap", "DeviceWait", "GetFence", "ResetFences", "CreateBuffer", "DestroyBuffer", "CreateImage", "DestroyImage", "BuildAcc", "GetQuery", "ResetCommandPool", "CreateImageView", "UpdateDescriptor", "CreateFence"}

	local function watch(name)
		for _, prefix in ipairs(names) do
			if name:find("^vk" .. prefix) then return true end
		end
	end

	vulkan.lib = setmetatable({}, {
		__index = function(_, name)
			local original = real[name]

			if type(name) ~= "string" or not watch(name) then return original end

			local label = "vk:" .. name
			acc[label] = acc[label] or 0
			local f = function(...)
				local t0 = GetTime()
				local a = original(...)
				acc[label] = acc[label] + GetTime() - t0
				return a
			end
			rawset(vulkan.lib, name, f)
			return f
		end,
	})
end

if not LEAN then
	local protected_call = import("goluwa/protected_call.lua")
	local original_call = protected_call.call
	local labels = {}

	function protected_call.call(callback, ...)
		local label = labels[callback]

		if not label then
			local info = debug.getinfo(callback, "S")
			label = "cb:" .. info.short_src:gsub("^.*/", "") .. ":" .. info.linedefined
			labels[callback] = label
			acc[label] = acc[label] or 0
		end

		local t0 = GetTime()
		local m0 = collectgarbage("count")
		local a, b, c, d, e, f = original_call(callback, ...)
		acc[label] = acc[label] + GetTime() - t0
		mem[label] = (mem[label] or 0) + math.max(collectgarbage("count") - m0, 0)
		return a, b, c, d, e, f
	end
end

local function wrap_listeners(event_type)
	for _, data in ipairs(event.active[event_type] or {}) do
		if data and not data.timed then
			data.timed = true
			local label = event_type:sub(1, 3) .. ":" .. tostring(data.unique or data.id)
			local original = data.callback
			acc[label] = 0

			data.callback = function(...)
				local t0 = GetTime()
				local a, b = original(...)
				acc[label] = acc[label] + GetTime() - t0
				return a, b
			end
		end
	end
end

do
	local render3d = import("goluwa/render3d/render3d.lua")

	for _, pipeline in ipairs(render3d.pipelines_i) do
		wrap(pipeline, "Draw", "pass:" .. tostring(pipeline.name))

		if pipeline.pre_render then wrap(pipeline, "pre_render", "pre:" .. tostring(pipeline.name)) end
	end
end

local gpu_timing = import("goluwa/render/gpu_timing.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
wrap(scene_bvh, "EnsureBuilt", "scene_bvh.EnsureBuilt")
wrap(scene_bvh, "BuildIncremental", "scene_bvh.BuildIncremental")

local frame_times = {}
local window_frame_times = {}
local t, yaw = 0, 0
local pos = Vec3(0, 60, 0)
local last_teleport = 0
local teleports = 0
local last_print = 0
local snapshot = {}

local function print_window(final)
	table.sort(window_frame_times)
	local n = #window_frame_times

	if n == 0 then return end

	local sum = 0

	for i = 1, n do
		sum = sum + window_frame_times[i]
	end

	local s = terrain:GetStats()
	local line = {
		string.format(
			"t=%4.1f speed %5.0f frames %3d avg %5.1f p50 %5.1f p95 %5.1f max %6.1f ms | queue %3d tiles %3d built %.0f/s |",
			t,
			math.min(MAX_SPEED, 100 + (MAX_SPEED - 100) * math.max(t - WARMUP, 0) / (SECONDS - WARMUP)),
			n,
			sum / n * 1000,
			window_frame_times[math.floor(n / 2) + 1] * 1000,
			window_frame_times[math.max(math.floor(n * 0.95), 1)] * 1000,
			window_frame_times[n] * 1000,
			s.queue,
			s.totals.tiles,
			(s.build.built - (snapshot.built or 0)) / math.max(t - (snapshot.t or 0), 0.001)
		),
	}
	local names = {}

	for label in pairs(acc) do
		names[#names + 1] = label
	end

	table.sort(names, function(a, b)
		return acc[a] - (snapshot[a] or 0) > acc[b] - (snapshot[b] or 0)
	end)

	for i = 1, math.min(#names, final and 20 or 6) do
		local label = names[i]
		local delta = acc[label] - (snapshot[label] or 0)
		line[#line + 1] = string.format(" %s %.2f", label, delta / n * 1000)
	end

	print(table.concat(line))
	snapshot = {built = s.build.built, t = t}

	for label, value in pairs(acc) do
		snapshot[label] = value
	end

	table.clear(window_frame_times)
end

local previous_acc, previous_mem = {}, {}
local wall_dt, last_wall, frame_gap, last_frame
local time_after, time_before, time_at_update, time_at_frame_end = 0, 0, 0, 0
local mem_at_update, mem_at_frame_end, grew_in_update, grew_outside = 0, 0, 0, 0

event.AddListener("FrameEnd", "terrain_stress_frame_end", function()
	local now = collectgarbage("count")
	grew_in_update = now - mem_at_update
	mem_at_frame_end = now
	time_after = GetTime() - time_at_update
	time_at_frame_end = GetTime()
end)

event.AddListener("Update", "terrain_stress", function(dt)
	t = t + dt
	time_before = GetTime() - time_at_frame_end
	if os.getenv("TRACE") and t < 20 then print(string.format("TRACE frame %d dt %.1f wall %.1f gettime %.3f elapsed %.3f", system.GetFrameNumber(), dt * 1000, (GetTime() - (last_wall or GetTime())) * 1000, GetTime(), system.GetElapsedTime())) end
	frame_gap = system.GetFrameNumber() - (last_frame or system.GetFrameNumber())
	last_frame = system.GetFrameNumber()
	wall_dt = GetTime() - (last_wall or GetTime())
	last_wall = GetTime()
	time_at_update = GetTime()
	local now_mem = collectgarbage("count")
	grew_outside = now_mem - mem_at_frame_end
	mem_at_update = now_mem

	if not LEAN then
		wrap_listeners("Update")
		wrap_listeners("Draw")
		wrap_listeners("PreFrame")
		wrap_listeners("PostDraw")
		wrap_listeners("FrameEnd")
	end

	if wall_dt and wall_dt > 0.1 and t > WARMUP then
		local parts = {}

		for label, value in pairs(acc) do
			local delta = value - (previous_acc[label] or 0)

			if delta > 0.0015 then parts[#parts + 1] = string.format("%s %.0f", label, delta * 1000) end
		end

		table.sort(parts)
		local scopes = {}

		for _, name in ipairs(gpu_timing.GetScopeNames()) do
			local ms = gpu_timing.GetRawMilliseconds(name)

			if ms and ms > 3 then scopes[#scopes + 1] = string.format("%s %.0f", name, ms) end
		end

		local rss = 0

		for line in io.lines("/proc/self/status") do
			local kb = line:match("^VmRSS:%s+(%d+)")

			if kb then rss = tonumber(kb) / 1024 end
		end

		local allocs = {}

		for label, kb in pairs(mem) do
			if kb - (previous_mem[label] or 0) > 2000 then allocs[#allocs + 1] = {label, (kb - (previous_mem[label] or 0)) / 1024} end
		end

		table.sort(allocs, function(a, b) return a[2] > b[2] end)

		for i = 1, #allocs do
			allocs[i] = string.format("%s %.0fMB", allocs[i][1], allocs[i][2])
		end

		print("   allocated: " .. table.concat(allocs, ", "))
		print(string.format("SLOW FRAME %.0f ms (wall %.0f, %d frames) (lua %.0f MB, rss %.0f MB, after my listener %.0f ms, before it %.0f ms): %s | gpu: %s", dt * 1000, wall_dt * 1000, frame_gap, collectgarbage("count") / 1024, rss, time_after * 1000, time_before * 1000, table.concat(parts, ", "), table.concat(scopes, ", ")))
	end

	for label, value in pairs(acc) do
		previous_acc[label] = value
	end

	for label, kb in pairs(mem) do
		previous_mem[label] = kb
	end

	if t < WARMUP then return end

	if GC_MODE == "stepped" then
		local t0 = GetTime()
		repeat
			collectgarbage("step", 30)
		until GetTime() - t0 > 0.002
	end

	frame_times[#frame_times + 1] = dt
	window_frame_times[#window_frame_times + 1] = dt
	local speed = 100 + (MAX_SPEED - 100) * math.min((t - WARMUP) / (SECONDS - WARMUP), 1)
	yaw = yaw + math.rad(40) * dt * math.sin(t * 0.9)
	pos = pos + Vec3(math.cos(yaw), 0, math.sin(yaw)) * speed * dt

	if TELEPORT > 0 and t - last_teleport > TELEPORT then
		last_teleport = t
		teleports = teleports + 1
		local angle = math.random() * math.pi * 2
		local distance = 5000 + math.random() * 60000
		pos = Vec3(pos.x + math.cos(angle) * distance, 60, pos.z + math.sin(angle) * distance)
		print(string.format("teleport %d to %.0f %.0f", teleports, pos.x, pos.z))
	end

	view:SetPosition(pos)
	view:SetRotation(QuatDeg3(-10, -math.deg(yaw) + 90, 0))

	if t - last_print >= 2 then
		last_print = t
		print_window()
	end

	if t > SECONDS then
		print_window(true)
		table.sort(frame_times)
		local n = #frame_times
		print(string.format("overall %d frames p50 %.1f p95 %.1f p99 %.1f max %.1f ms", n, frame_times[math.floor(n / 2) + 1] * 1000, frame_times[math.floor(n * 0.95)] * 1000, frame_times[math.floor(n * 0.99)] * 1000, frame_times[n] * 1000))
		system.ShutDown(0)
	end
end)

if os.getenv("PROF") then _G.PROF.Start("terrain_stress", {frames = tonumber(os.getenv("PROF_FRAMES") or 700), trace_recorder = false}) end
