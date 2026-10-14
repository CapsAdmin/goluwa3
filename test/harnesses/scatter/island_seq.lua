-- a png of each view of the island example (VIEWS=6,7 picks some, PREFIX names the files), waiting for the scatter bakes first
-- luajit glw --3d --background --validate lua "./test/harnesses/scatter/island_seq.lua"
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local scatter = import("goluwa/render3d/scatter.lua")
local View = import("goluwa/render3d/view.lua")
local locate = import("test/harnesses/scatter/island_locate.lua")
local island = import("addons/examples/lua/examples/render3d/island_terrain.lua")
local only = os.getenv("VIEWS")
local list_of, names = {}, {}
for i, v in ipairs(island.views) do
	if not only or ("," .. only .. ","):find("," .. i .. ",", 1, true) then
		list_of[#list_of + 1] = island.GetView(i)
		names[#names + 1] = v.name:gsub(" ", "_")
	end
end
local MIN_FIRST, MAX_WAIT = 25, tonumber(os.getenv("MAX_WAIT") or 90)
local view = View.New{Priority = 100, Position = list_of[1].Position, Rotation = list_of[1].Rotation, FOV = list_of[1].FOV}:Activate()
local index, state, state_start, quiet = 1, "locate", system.GetTime(), nil
locate.Go(view, list_of[1], function() state, state_start = "wait", system.GetTime() end)
local first = true
event.AddListener("Update", "island_seq", function()
	local now = system.GetTime()
	if state ~= "wait" then return end
	local min = first and MIN_FIRST or 4
	if (scatter.pending_bakes or 1) == 0 and now - state_start > min then quiet = quiet or now else quiet = nil end
	if (quiet and now - quiet > 3) or now - state_start > MAX_WAIT then
		state = "shot"
		print(string.format("view %d after %.0f s: units %d pool %d pending %d", index, now - state_start, scatter.unit_count, scatter.pool_top, scatter.pending_bakes))
		Screenshot(function(texture)
			print("saved", texture:SaveWithoutAlpha("storage/logs/island_" .. (os.getenv("PREFIX") or "q") .. "_" .. index .. "_" .. names[index] .. ".png"))
			index = index + 1
			first = false
			if not list_of[index] then system.ShutDown(0) return end
			state, quiet = "locate", nil
			locate.Go(view, list_of[index], function() state, state_start = "wait", system.GetTime() end)
		end)
	end
end)
