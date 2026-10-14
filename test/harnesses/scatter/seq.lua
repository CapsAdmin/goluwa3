-- views: {name, pos = {x, y, z}, ground = meters above the terrain at x,z (replaces y), ang = {pitch, yaw}, fov}
local Shot = import("goluwa/render3d/shot.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local scene = os.getenv("SCENE") or "test/harnesses/scatter/scene.lua"
import(scene)
local views = dofile(os.getenv("VIEWS") or "test/harnesses/scatter/views.lua")
local list_of = {}
for i, v in ipairs(views) do
	local pos = Vec3(v.pos[1], v.pos[2], v.pos[3])
	if v.ground then pos.y = _G.scatter_height(pos.x, pos.z) + v.ground end
	list_of[i] = {Position = pos, Rotation = Quat():SetAngles(Deg3(v.ang[1], v.ang[2], v.ang[3] or 0)), FOV = math.rad(v.fov or 70)}
end
Shot.Sequence(list_of, function(texture, info, i)
	print("saved", texture:SaveWithoutAlpha("storage/logs/scatter_" .. (os.getenv("PREFIX") or "q") .. "_" .. views[i].name .. ".png"))
end, {settle = tonumber(os.getenv("SETTLE") or 6)}, function() system.ShutDown(0) end)
