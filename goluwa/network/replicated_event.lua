local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")
return function(name, handler, is_enabled)
	if CLIENT and not SERVER then
		message.AddListener(name, function(...)
			if is_enabled and not is_enabled() then return end

			handler(...)
		end)
	end

	return function(...)
		if SERVER and network.IsStarted() then
			message.Broadcast(name, ...)
		elseif not is_enabled or is_enabled() then
			handler(...)
		end
	end
end
