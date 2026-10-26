local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")
local clients = import("goluwa/network/clients.lua")
return function(name, handler, is_enabled, get_predicted_client)
	if CLIENT and not SERVER then
		message.AddListener(name, function(...)
			if is_enabled and not is_enabled() then return end

			handler(...)
		end)
	end

	return function(...)
		if SERVER and network.IsStarted() then
			local predicted = get_predicted_client and get_predicted_client(...)

			if predicted and predicted:IsValid() then
				message.Send(name, clients.CreateFilter():AddAllExcept(predicted), ...)
			else
				message.Broadcast(name, ...)
			end
		elseif not is_enabled or is_enabled() then
			handler(...)
		end
	end
end
