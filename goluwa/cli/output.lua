local event = import("goluwa/event.lua")
local fs = import("goluwa/filesystem/fs.lua")
local output = library()
local suppress_print = false
local LOG_FILE = "storage/logs/log.txt"

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
	fs.create_directory("storage/logs/")
	output.file = assert(fs.file_open(LOG_FILE, "w"))
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

do
	local function read_log_tail()
		local file = fs.file_open(LOG_FILE, "r")

		if not file then return "", 0 end

		file:seek(0, 2) -- SEEK_END
		local size = tonumber(file:tell())
		file:seek(0, 0) -- SEEK_SET
		local content = file:read(size, 1)
		file:close()
		return content or "", size
	end

	function output.Capture(func)
		local _, log_size_before = read_log_tail()
		local res = list.pack(func())
		local log_after, _ = read_log_tail()
		local output = ""

		if log_size_before < #log_after then
			output = log_after:sub(log_size_before + 1)
		end

		return output, list.unpack(res)
	end
end

function output.GetLogLines(count)
	count = count or 50
	local file = fs.file_open(LOG_FILE, "r")
	file:seek(0, 2) -- SEEK_END
	local fsize = tonumber(file:tell())
	file:seek(0, 0) -- SEEK_SET
	local content = file:read(fsize, 1)
	file:close()
	local lines = content:split("\n")
	local result = {}
	count = math.min(count, #lines)

	for i = #lines - count + 1, #lines do
		table.insert(result, lines[i])
	end

	return lines
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
