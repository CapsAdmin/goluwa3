local commands = import("goluwa/cli/commands.lua")
local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")

local function toggle(entity)
	local health = entity.health
	health:SetGodMode(not health:IsGodMode())
	logn(entity, " god mode ", health:IsGodMode() and "on" or "off")
end

if SERVER then
	message.AddListener("godmode_toggle", function(client)
		toggle(_G.GetPlayerEntity(client))
	end)
end

commands.Add("god", function()
	if network.HasAuthority() then
		toggle(_G.PLAYER_RIG)
	else
		message.Send("godmode_toggle")
	end
end)
