local ljsocket = import("goluwa/bindings/socket.lua")
local prototype = import("goluwa/prototype.lua")
local event = import("goluwa/event.lua")
local pool = prototype.CreateObjectPool("sockets")

event.AddListener("Update", "sockets", function()
	if pool.list[1] == nil then return end

	local entries = {}

	for i, obj in ipairs(pool.list) do
		entries[i] = {obj:GetPollSocket(), obj:GetPollFlags(), obj}
	end

	for _, result in ipairs(assert(ljsocket.poll(entries, 0))) do
		local obj = result.entry[3]

		if obj:IsValid() then obj:OnPollReady(result.events) end
	end
end)

return pool
