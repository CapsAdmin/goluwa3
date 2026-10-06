local T = import("test/environment.lua")
local packet = import("goluwa/network/packet.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Quat = import("goluwa/structs/quat.lua")
local BUTTON = usercmd.BUTTON

T.Test("usercmd round trips through a packet buffer", function()
	local cmd = usercmd.New()
	cmd.number = 123456
	cmd.view = Quat(0.1, 0.2, 0.3, 0.9):Normalize()
	cmd.forward = 1
	cmd.side = -1
	cmd.up = 0
	cmd.buttons = bit.bor(BUTTON.JUMP, BUTTON.CROUCH)
	cmd.mode = "walk"
	cmd.fov = 1.2
	cmd.scroll = -3
	local buffer = packet.CreateBuffer()
	usercmd.Write(buffer, cmd)
	buffer:SetPosition(1)
	local out = usercmd.Read(buffer)
	T(out.number)["=="](123456)
	T(out.forward)["=="](1)
	T(out.side)["=="](-1)
	T(out.up)["=="](0)
	T(out.buttons)["=="](bit.bor(BUTTON.JUMP, BUTTON.CROUCH))
	T(out.mode)["=="]("walk")
	T(out.scroll)["=="](-3)
	T(math.abs(out.fov - 1.2))["<"](0.0001)
	T(math.abs(out.view:Dot(cmd.view) - 1))["<"](0.00001)
end)

T.Test("usercmd batches keep order", function()
	local commands = {}

	for i = 1, 5 do
		commands[i] = usercmd.New()
		commands[i].number = 100 + i
	end

	local buffer = packet.CreateBuffer()
	usercmd.WriteBatch(buffer, commands)
	buffer:SetPosition(1)
	local out = usercmd.ReadBatch(buffer)
	T(#out)["=="](5)

	for i = 1, 5 do
		T(out[i].number)["=="](100 + i)
	end
end)

T.Test("usercmd copy is independent", function()
	local cmd = usercmd.New()
	cmd.number = 7
	local copy = usercmd.Copy(cmd)
	copy.view.x = 0.5
	copy.number = 8
	T(cmd.view.x)["=="](0)
	T(cmd.number)["=="](7)
end)
