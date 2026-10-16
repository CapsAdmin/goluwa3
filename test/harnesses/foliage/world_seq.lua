-- a png of each view of examples/render3d/foliage_world.lua into tmp/foliage_world_<n>.png, ONLY=1,3 for some
-- luajit glw --3d --background lua test/harnesses/foliage/world_seq.lua
local Shot = import("goluwa/render3d/shot.lua")
local Quat = import("goluwa/structs/quat.lua")
local system = import("goluwa/system.lua")
local world = import("addons/examples/lua/examples/render3d/foliage_world.lua")
local only = {}

for i in (os.getenv("ONLY") or ""):gmatch("%d+") do
	only[tonumber(i)] = true
end

local list_of, names = {}, {}

for i in ipairs(world.views) do
	if not next(only) or only[i] then
		world.SetView(i)
		local properties = world.view
		list_of[#list_of + 1] = {Position = properties.Position:Copy(), Rotation = properties.Rotation:Copy(), FOV = properties.FOV}
		names[#names + 1] = i
	end
end

world.SetView(nil)

Shot.Sequence(list_of, function(texture, info, i)
	print("saved", texture:SaveWithoutAlpha("tmp/foliage_world_" .. names[i] .. ".png"), ("%.1f s"):format(info.seconds))
end, {settle = tonumber(os.getenv("SETTLE") or 6)}, function() system.ShutDown(0) end)
