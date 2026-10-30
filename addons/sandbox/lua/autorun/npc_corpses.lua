local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local timer = import("goluwa/timer.lua")
local props = import("lua/props.lua")
local CORPSE_TIME = 20

local function remove_corpse(corpse)
	corpse:Remove()
end

event.AddListener("EntityKilled", "npc_corpses", function(victim)
	if not victim.ai_controller or victim.ragdoll or not victim.model then return end

	if not network.HasAuthority() then return end

	local model_path = victim.model.ModelPath

	if model_path == "" then return end

	props.Spawn(
		model_path,
		victim.transform:GetPosition():Copy(),
		victim.transform:GetRotation():Copy(),
		function(corpse)
			timer.Delay(CORPSE_TIME, remove_corpse, nil, corpse, corpse)
		end
	)
end)
