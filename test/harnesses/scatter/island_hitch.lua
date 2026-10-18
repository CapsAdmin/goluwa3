-- names the stage that a long frame went in while the island jumps (see island_fill.lua): the time of every stage that is
-- wrapped since the last call of this listener, printed when that is over 150 ms
-- luajit glw --3d --background lua "./test/harnesses/scatter/island_hitch.lua"
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local scatter = import("goluwa/render3d/scatter.lua")
local render = import("goluwa/render/render.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local View = import("goluwa/render3d/view.lua")
local island = import("addons/examples/lua/examples/render3d/island_terrain.lua")
local terrain = _G.island_terrain
local GetTime = system.GetTime
local acc = {}

local function wrap(object, name, label)
	local original = object[name]
	acc[label] = 0

	object[name] = function(...)
		local t0 = GetTime()
		local a, b = original(...)
		acc[label] = acc[label] + GetTime() - t0
		return a, b
	end
end

for _, name in ipairs{"Update", "UpdateTiles", "RetireTiles", "RemoveTile", "ProcessBuildQueue", "CreateTile", "ProcessPendingReleases"} do
	wrap(terrain, name, "terrain." .. name)
end

for _, name in ipairs{"Update", "RequestChunk", "CompleteBatch", "ReleaseChunk", "RecycleTexture"} do
	wrap(terrain.Source, name, "source." .. name)
end

wrap(scatter, "PreDraw", "scatter.PreDraw")
wrap(scatter, "Preload", "scatter.Preload")
wrap(render, "BeginFrame", "render.BeginFrame")
wrap(render, "EndFrame", "render.EndFrame")
local previous, last_time = {}, nil
local v0 = island.GetView(5)
local view = View.New{Priority = 100, Position = v0.Position, Rotation = v0.Rotation, FOV = v0.FOV}:Activate()
local phase, phase_start = "settle", system.GetElapsedTime()

event.AddListener("Update", "island_hitch", function()
	local now = GetTime()
	local wall = last_time and now - last_time or 0
	last_time = now

	if wall > 0.15 and phase == "jump" then
		local parts = {}

		for label, value in pairs(acc) do
			local delta = value - (previous[label] or 0)

			if delta > 0.01 then parts[#parts + 1] = {label, delta} end
		end

		table.sort(parts, function(a, b) return a[2] > b[2] end)

		for i, part in ipairs(parts) do
			parts[i] = string.format("%s %.0f", part[1], part[2] * 1000)
		end

		print(string.format("HITCH %.0f ms since the last call: %s", wall * 1000, table.concat(parts, ", ")))
	end

	for label, value in pairs(acc) do
		previous[label] = value
	end

	if phase == "settle" then
		if system.GetElapsedTime() - phase_start > 12 and (scatter.pending_bakes or 1) == 0 then
			phase = "jump"
			phase_start = system.GetElapsedTime()
			view:SetPosition(Vec3(2250, 150, 100))
			view:SetRotation(QuatDeg3(-6, 200, 0))
		end
	elseif system.GetElapsedTime() - phase_start > 8 then
		system.ShutDown(0)
	end
end)
