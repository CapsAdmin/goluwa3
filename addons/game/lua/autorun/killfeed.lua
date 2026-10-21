local event = import("goluwa/event.lua")
local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")
local killfeed = import("lua/killfeed.lua")

event.AddListener("EntityKilled", "killfeed", function(victim, info)
	local attacker = info.Attacker
	local killer = attacker and attacker ~= victim and attacker:GetName() or ""

	if SERVER and network.IsStarted() then
		message.Broadcast("killfeed", killer, victim:GetName())
	elseif CLIENT then
		killfeed.Add(killer, victim:GetName())
	end
end)

if CLIENT then message.AddListener("killfeed", killfeed.Add) end
