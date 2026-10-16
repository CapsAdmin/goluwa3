-- a headless client that reports where it sees the npc of net_server.lua, `luajit glw --cli --physics lua "import('test/harnesses/npc/net_client.lua')"`
local network = import("goluwa/network/network.lua")
local timer = import("goluwa/timer.lua")
local NetworkComponent = import("goluwa/entities/components/network.lua")
network.Connect("127.0.0.1", os.getenv("GOLUWA_PORT"))

timer.Repeat("npc_client_report", 2, function()
	for _, component in pairs(NetworkComponent.GetAllNetworked()) do
		local owner = component.Owner

		if owner.npc then
			local p = owner.transform:GetPosition()
			print(
				string.format(
					"CLIENT_NPC %.2f %.2f %.2f authority %s body %s",
					p.x,
					p.y,
					p.z,
					tostring(owner.npc:HasAuthority()),
					tostring(owner.rigid_body ~= nil and owner.rigid_body:GetMotionType())
				)
			)
		end
	end
end)
