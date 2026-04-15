local gine = ... or _G.gine
local repl = import("goluwa/repl.lua")
local system = import("goluwa/system.lua")

local function write(str)
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
	local terminal = system.GetTerminal()

	for i = 1, select("#", ...) do
		local val = select(i, ...)

		if type(val) == "table" then
			terminal:ForegroundColor(val.r, val.g, val.b)
		else
			write(val)
		end
	end
end

function gine.env.ErrorNoHalt(...)
	local args = {...}
	list.insert(args, 2)
	wlog(unpack(args))
end