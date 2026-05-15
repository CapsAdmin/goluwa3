local gine = ... or _G.gine
local repl = import("goluwa/repl.lua")
local system = import("goluwa/system.lua")

local function write(str)
	str = tostring(str)

	if repl.term and repl.term.Write then
		repl.term:Write(str)
		return
	end

	io.write(str)
end

function gine.env.Msg(str)
	write(str)
end

function gine.env.MsgN(str)
	write(str)
	write("\n")
end

function gine.env.MsgC(...)
	local terminal = repl.GetTerminal and repl.GetTerminal() or repl.term
	local color_pushed = false

	local function get_color_components(val)
		if type(val) ~= "table" then return nil end

		if val.r and val.g and val.b then return val.r, val.g, val.b end

		if val[1] and val[2] and val[3] then return val[1], val[2], val[3] end

		return nil
	end

	for i = 1, select("#", ...) do
		local val = select(i, ...)
		local r, g, b = get_color_components(val)

		if r and g and b then
			if terminal and terminal.PushForegroundColor then
				if color_pushed then terminal:PopAttribute() end

				terminal:PushForegroundColor(r, g, b)
				color_pushed = true
			end
		else
			write(val)
		end
	end

	if color_pushed and terminal and terminal.PopAttribute then
		terminal:PopAttribute()
	end
end

function gine.env.ErrorNoHalt(...)
	local args = {...}
	list.insert(args, 2)
	wlog(unpack(args))
end
