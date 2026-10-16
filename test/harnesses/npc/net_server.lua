-- a server with an npc walking a square on a flat floor, run with `luajit glw --server lua "import('test/harnesses/npc/net_server.lua')"`
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local navmesh = import("goluwa/navigation/navmesh.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local npcs = import("lua/npcs.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
shapes.Box{
	Name = "npc_ground",
	Position = Vec3(0, -0.5, 0),
	Scale = Vec3(200, 1, 200),
	RigidBody = {MotionType = "static"},
	Network = true,
}
local mesh = navmesh.New()
mesh:AddArea{Polygon = {Vec3(-30, 0, -30), Vec3(30, 0, -30), Vec3(30, 0, 30), Vec3(-30, 0, 30)}}
Entity.New{Name = "nav", transform = {}, nav_mesh = {}}.nav_mesh:SetMesh(mesh)
local npc = npcs.Spawn("zombie", Vec3(0, 0.05, 0), 0)
npc.npc:SetWander(true)
npc.npc:SetWanderMinDelay(0)
npc.npc:SetWanderMaxDelay(1)
local timer = import("goluwa/timer.lua")

timer.Repeat("npc_server_report", 2, function()
	local p = npc.transform:GetPosition()
	print(string.format("SERVER_NPC %.2f %.2f %.2f goal %s", p.x, p.y, p.z, tostring(npc.npc:GetGoal() ~= nil)))
end)
