local fs = require("fs")
local event = require("event")
local repl = require("repl")
local base_log_dir = "logs/"
fs.create_directory(base_log_dir)
local stdout = assert(io.open(base_log_dir .. "log.txt", "w"))
stdout:setvbuf("no")
local suppress_print = false

local function can_write(str)
	if suppress_print then return end

	do
		suppress_print = true

		if event.Call("StdOutWrite", str) == false then
			suppress_print = false
			return false
		end

		suppress_print = false
	end

	return true
end

local output = {}
output.file = stdout

function output.write(str)
	if can_write(str) == false then return end

	stdout:write(str)
	io.write(str)
	io.flush()
end

return output
