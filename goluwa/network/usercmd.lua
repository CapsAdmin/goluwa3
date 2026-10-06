local Quat = import("goluwa/structs/quat.lua")
local usercmd = {}
usercmd.BUTTON = {
	JUMP = 1,
	CROUCH = 2,
	SPRINT = 4,
	ATTACK1 = 8,
	ATTACK2 = 16,
	USE = 32,
	ACTIVE = 64,
}
usercmd.MODE = {fly = 0, walk = 1}
usercmd.MODE_NAME = {[0] = "fly", [1] = "walk"}
usercmd.MAX_BATCH = 8
usercmd.HELD_COLLISION_GROUP = 2

function usercmd.New()
	return {
		number = 0,
		view = Quat(0, 0, 0, 1),
		forward = 0,
		side = 0,
		up = 0,
		buttons = 0,
		pressed = 0,
		mode = "fly",
		fov = math.rad(90),
		scroll = 0,
		rotate_x = 0,
		rotate_y = 0,
		select = 0,
	}
end

function usercmd.Copy(cmd)
	local out = usercmd.New()
	out.number = cmd.number
	out.view:CopyFrom(cmd.view)
	out.forward = cmd.forward
	out.side = cmd.side
	out.up = cmd.up
	out.buttons = cmd.buttons
	out.pressed = cmd.pressed
	out.mode = cmd.mode
	out.fov = cmd.fov
	out.scroll = cmd.scroll
	out.rotate_x = cmd.rotate_x
	out.rotate_y = cmd.rotate_y
	out.select = cmd.select
	return out
end

function usercmd.HasButton(cmd, button)
	return bit.band(cmd.buttons, button) ~= 0
end

function usercmd.WasPressed(cmd, button)
	return bit.band(cmd.pressed, button) ~= 0
end

local function write_axis(buffer, value)
	buffer:WriteByte(math.floor(math.clamp(value, -1, 1) * 127 + 128.5))
end

local function read_axis(buffer)
	return (buffer:ReadByte() - 128) / 127
end

function usercmd.Write(buffer, cmd)
	buffer:WriteU32(cmd.number)
	buffer:WriteQuat(cmd.view)
	write_axis(buffer, cmd.forward)
	write_axis(buffer, cmd.side)
	write_axis(buffer, cmd.up)
	buffer:WriteU16(cmd.buttons)
	buffer:WriteByte(usercmd.MODE[cmd.mode])
	buffer:WriteFloat(cmd.fov)
	buffer:WriteByte(math.floor(math.clamp(cmd.scroll, -127, 127) + 128))
	buffer:WriteI16(math.floor(math.clamp(cmd.rotate_x, -30, 30) * 1000 + 0.5))
	buffer:WriteI16(math.floor(math.clamp(cmd.rotate_y, -30, 30) * 1000 + 0.5))
	buffer:WriteByte(cmd.select)
end

function usercmd.Read(buffer, out)
	out = out or usercmd.New()
	out.number = buffer:ReadU32()
	out.view = buffer:ReadQuat()
	out.forward = read_axis(buffer)
	out.side = read_axis(buffer)
	out.up = read_axis(buffer)
	out.buttons = buffer:ReadU16()
	out.mode = usercmd.MODE_NAME[buffer:ReadByte()]
	out.fov = buffer:ReadFloat()
	out.scroll = buffer:ReadByte() - 128
	out.rotate_x = buffer:ReadI16() / 1000
	out.rotate_y = buffer:ReadI16() / 1000
	out.select = buffer:ReadByte()
	return out
end

function usercmd.WriteBatch(buffer, commands)
	buffer:WriteByte(#commands)

	for _, cmd in ipairs(commands) do
		usercmd.Write(buffer, cmd)
	end
end

function usercmd.ReadBatch(buffer)
	local commands = {}

	for i = 1, buffer:ReadByte() do
		commands[i] = usercmd.Read(buffer)
	end

	return commands
end

return usercmd
