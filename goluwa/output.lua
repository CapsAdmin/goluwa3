local event = require("event")
local fs = require("fs")
local output = library()
local suppress_print = false

function output.CanWrite(str)
	if suppress_print then return false end

	suppress_print = true
	local result = event.Call("StdOutWrite", str)
	suppress_print = false
	return result ~= false
end

function output.Initialize()
	if output.initialized then return end

	output.initialized = true
	fs.create_directory("logs/")
	output.file = assert(fs.file_open("logs/log.txt", "w"))
end

function output.Write(str)
	-- Always write to log file first, regardless of event handler result
	if output.file and not suppress_print then
		assert(output.file:write(str, 1, #str))
		assert(output.file:flush())
	end

	-- CanWrite fires the StdOutWrite event; if a listener returns false it means
	-- it handled the terminal output itself (e.g. the REPL), so skip io.write.
	if not output.CanWrite(str) then return end

	io.write(str)
	io.flush()
end

function output.WriteDirect(str)
	io.write(str)
	io.flush()
end

function output.Flush()
	io.flush()
end

function output.Shutdown()
	if output.file then assert(output.file:close()) end
end

return output