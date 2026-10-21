local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local nav_mesh = import("goluwa/entities/components/nav_mesh.lua")
local SpawnPoint = import("goluwa/entities/components/spawn_point.lua")
local npcs = import("lua/npcs.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local COUNT = tonumber(os.getenv("NPC_COUNT")) or 24
local SPREAD = 40
local SETTLE = 1
local names = npcs.GetNames()
commands.RunString("map gm_construct")
local loaded_at

event.AddListener("Update", "npc_walkers", function()
	if scene_loading.IsLoading() or not nav_mesh.GetMesh() then return end

	loaded_at = loaded_at or system.GetElapsedTime()

	-- the collision of the world is built a moment after the map has loaded
	if system.GetElapsedTime() - loaded_at < SETTLE then return end

	event.RemoveListener("Update", "npc_walkers")
	local mesh = nav_mesh.GetMesh()
	local center = SpawnPoint.Pick():GetPlacement(0)

	for i = 1, COUNT do
		local position = mesh:GetRandomPoint(center, SPREAD) or mesh:GetRandomPoint()
		npcs.Spawn(
			names[i % #names + 1],
			position + Vec3(0, 0.05, 0),
			math.randomf(-math.pi, math.pi)
		)
	end
end)
