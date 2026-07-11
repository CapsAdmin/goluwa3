local chatsounds = import("lua/chatsounds.lua")
local event = import("goluwa/event.lua")
local ready = false
local loading = false

event.AddListener("ClientChat", "chatsounds", function(client, str, seed)
	if loading then return end

	if not ready then
		chatsounds.Initialize()

		chatsounds.LoadRepositories():Then(function()
			chatsounds.Say(str, seed)
			loading = false
			ready = true
		end)

		loading = true
	else
		chatsounds.Say(str, seed)
	end
end)
