local socket = require("socket")
local terminal = require("terminal")
local threads = require("threads")

-- Parse command line arguments
local host = arg[1] or "mapscii.me"
local port = arg[2] or "23"

-- Debug mode
local DEBUG = os.getenv("DEBUG") == "1"
local debug_file
if DEBUG then
	debug_file = io.open("./telnet_debug.log", "w")
end
local function debug_print(...)
	if DEBUG and debug_file then
		debug_file:write(string.format(...) .. "\n")
		debug_file:flush()
	end
end

-- Initialize terminal
local term = terminal.WrapFile(io.stdin, io.stdout)
term:UseAlternateScreen(true)
term:EnableCaret(true)
term:Clear()

-- Print header
term:PushBold()
term:PushForegroundColor(100, 200, 255)
term:Write(string.format("Telnet Client - Connecting to %s:%s\n", host, port))
term:PopAttribute()
term:PopAttribute()
term:Write("Press Ctrl+C to quit\n\n")
term:Flush()

-- Create and connect socket
local sock, err = socket.create("inet", "stream", "tcp")

if not sock then
	term:PushForegroundColor(255, 100, 100)
	term:Write("Failed to create socket: " .. tostring(err) .. "\n")
	term:PopAttribute()
	term:Flush()
	os.exit(1)
end

-- Set socket to non-blocking mode
sock:set_blocking(false)

-- Connect to host
local ok, err, num = sock:connect(host, port)
debug_print("Connect result: ok=%s, err=%s, num=%s", tostring(ok), tostring(err), tostring(num))

-- For non-blocking sockets, connect returns nil,"timeout" or true when in progress
if ok == nil and err ~= "timeout" then
	term:PushForegroundColor(255, 100, 100)
	term:Write("Failed to connect: " .. tostring(err) .. "\n")
	term:PopAttribute()
	term:Flush()
	sock:close()
	os.exit(1)
end

-- Wait for connection to complete
term:PushForegroundColor(200, 200, 100)
term:Write("Connecting")
term:PopAttribute()
term:Flush()

local connected = false
local timeout_count = 0
while not connected and timeout_count < 50 do
	local result, err = sock:poll(100, "out", "err")
	debug_print("Connection poll: result=%s (type=%s), err=%s", tostring(result), type(result), tostring(err))

	if result == nil then
		term:Write("\n")
		term:PushForegroundColor(255, 100, 100)
		term:Write("Poll error: " .. tostring(err) .. "\n")
		term:PopAttribute()
		term:Flush()
		sock:close()
		os.exit(1)
	elseif type(result) == "table" then
		debug_print("Connection poll events: in=%s, out=%s, err=%s, hup=%s",
			tostring(result["in"]), tostring(result.out), tostring(result.err), tostring(result.hup))

		-- Check for actual connection status first
		if result.out or result.err then
			-- Socket is writable or has error condition - check actual status
			local is_conn, conn_err, conn_num = sock:is_connected()
			debug_print("is_connected check: %s, err=%s, num=%s", tostring(is_conn), tostring(conn_err), tostring(conn_num))

			if is_conn then
				connected = true
				break
			elseif is_conn == false then
				-- Definitely not connected and got error
				-- Check the socket error
				local sock_err = sock:get_option("error")
				debug_print("Socket error option: %s", tostring(sock_err))

				if sock_err and sock_err ~= 0 then
					term:Write("\n")
					term:PushForegroundColor(255, 100, 100)
					term:Write("Connection failed: " .. tostring(conn_err) .. "\n")
					term:PopAttribute()
					term:Flush()
					sock:close()
					os.exit(1)
				end
			end
		end
	end
	term:Write(".")
	term:Flush()
	timeout_count = timeout_count + 1
end

if not connected then
	term:Write("\n")
	term:PushForegroundColor(255, 100, 100)
	term:Write("Connection timeout\n")
	term:PopAttribute()
	term:Flush()
	sock:close()
	os.exit(1)
end

term:Write("\n")
term:PushForegroundColor(100, 255, 100)
term:Write("Connected!\n\n")
term:PopAttribute()
term:Flush()

-- Enable mouse tracking with motion events
term:EnableMouse(true)
-- Enable mouse motion tracking (mode 1003 = any motion, or 1002 = button motion only)
-- Mode 1002: Send mouse motion events only when a button is pressed (dragging)
term:Write("\27[?1002h")
term:Flush()

-- Telnet protocol constants
local IAC  = 255  -- Interpret As Command
local DONT = 254  -- Don't do option
local DO   = 253  -- Do option
local WONT = 252  -- Won't do option
local WILL = 251  -- Will do option
local SB   = 250  -- Subnegotiation begin
local SE   = 240  -- Subnegotiation end
local NOP  = 241  -- No operation
local DM   = 242  -- Data Mark
local BRK  = 243  -- Break
local IP   = 244  -- Interrupt Process
local AO   = 245  -- Abort Output
local AYT  = 246  -- Are You There
local EC   = 247  -- Erase Character
local EL   = 248  -- Erase Line
local GA   = 249  -- Go Ahead

-- Telnet options
local ECHO = 1
local SUPPRESS_GO_AHEAD = 3
local TERMINAL_TYPE = 24
local NAWS = 31  -- Negotiate About Window Size

-- Buffer for incomplete telnet commands
local telnet_buffer = ""

-- Handle telnet protocol commands
local function process_telnet_data(data)
	debug_print("Processing telnet data: %d bytes", #data)
	local output = ""
	local i = 1

	-- Prepend any buffered data
	if #telnet_buffer > 0 then
		data = telnet_buffer .. data
		telnet_buffer = ""
	end

	while i <= #data do
		local byte = data:byte(i)

		if byte == IAC then
			if i + 1 > #data then
				-- Incomplete command, buffer it
				telnet_buffer = data:sub(i)
				break
			end

			local cmd = data:byte(i + 1)

			if cmd == IAC then
				-- Escaped IAC, output single IAC
				output = output .. string.char(IAC)
				i = i + 2
			elseif cmd == WILL or cmd == WONT or cmd == DO or cmd == DONT then
				if i + 2 > #data then
					-- Incomplete command, buffer it
					telnet_buffer = data:sub(i)
					break
				end

				local option = data:byte(i + 2)

				-- Respond to telnet negotiations
				if cmd == WILL then
					-- Server will do something - acknowledge common options
					debug_print("Telnet: Server WILL %d", option)
					if option == SUPPRESS_GO_AHEAD or option == ECHO then
						-- Accept these options
						debug_print("Telnet: Sending DO %d", option)
						sock:send(string.char(IAC, DO, option))
					else
						-- Reject other options
						debug_print("Telnet: Sending DONT %d", option)
						sock:send(string.char(IAC, DONT, option))
					end
				elseif cmd == DO then
					-- Server wants us to do something
					debug_print("Telnet: Server DO %d", option)
					if option == TERMINAL_TYPE then
						-- We can send terminal type
						debug_print("Telnet: Sending WILL TERMINAL_TYPE")
						sock:send(string.char(IAC, WILL, option))
					elseif option == NAWS then
						-- We can send window size
						debug_print("Telnet: Sending WILL NAWS")
						sock:send(string.char(IAC, WILL, option))
						-- Send window size
						local width, height = term:GetSize()
						debug_print("Telnet: Sending window size %dx%d", width, height)
						sock:send(string.char(IAC, SB, NAWS,
							bit.rshift(width, 8), bit.band(width, 0xFF),
							bit.rshift(height, 8), bit.band(height, 0xFF),
							IAC, SE))
					else
						-- We won't do other options
						debug_print("Telnet: Sending WONT %d", option)
						sock:send(string.char(IAC, WONT, option))
					end
				elseif cmd == WONT then
					-- Server won't do something - acknowledge
					sock:send(string.char(IAC, DONT, option))
				elseif cmd == DONT then
					-- Server doesn't want us to do something - acknowledge
					sock:send(string.char(IAC, WONT, option))
				end

				i = i + 3
			elseif cmd == SB then
				-- Subnegotiation
				local se_pos = data:find(string.char(IAC) .. string.char(SE), i + 2, true)
				if not se_pos then
					-- Incomplete subnegotiation, buffer it
					telnet_buffer = data:sub(i)
					break
				end

				local option = data:byte(i + 2)
				if option == TERMINAL_TYPE then
					local subopt = data:byte(i + 3)
					if subopt == 1 then  -- SEND
						-- Send terminal type
						local term_type = "xterm-256color"
						sock:send(string.char(IAC, SB, TERMINAL_TYPE, 0) .. term_type .. string.char(IAC, SE))
					end
				end

				i = se_pos + 2
			elseif cmd == NOP or cmd == DM or cmd == GA then
				-- Skip these commands
				i = i + 2
			else
				-- Unknown command, skip
				i = i + 2
			end
		else
			-- Regular data
			output = output .. string.char(byte)
			i = i + 1
		end
	end

	debug_print("Telnet output: %d bytes", #output)
	return output
end

-- Main event loop
local running = true
local line_buffer = ""
local last_width, last_height = term:GetSize()

while running do
	-- Check for terminal resize
	local width, height = term:GetSize()
	if width ~= last_width or height ~= last_height then
		debug_print("Terminal resized: %dx%d -> %dx%d", last_width, last_height, width, height)
		last_width, last_height = width, height
		-- Send new window size via NAWS
		sock:send(string.char(IAC, SB, NAWS,
			bit.rshift(width, 8), bit.band(width, 0xFF),
			bit.rshift(height, 8), bit.band(height, 0xFF),
			IAC, SE))
	end

	-- Check for socket data
	local result, poll_err = sock:poll(0, "in", "err", "hup")
	debug_print("Poll result: %s (type: %s), err=%s", tostring(result), type(result), tostring(poll_err))

	if result == nil then
		-- Poll error
		term:Write("\n")
		term:PushForegroundColor(255, 100, 100)
		term:Write("Poll failed: " .. tostring(poll_err) .. "\n")
		term:PopAttribute()
		term:Flush()
		running = false
		break
	elseif type(result) == "table" then
		debug_print("Poll events: in=%s, out=%s, err=%s, hup=%s",
			tostring(result["in"]), tostring(result.out), tostring(result.err), tostring(result.hup))

		if result["in"] then
			local data, addr_or_err = sock:receive()
			debug_print("Receive result: data_len=%s, err=%s", data and #data or "nil", tostring(addr_or_err))

			if data then
				-- Process telnet protocol
				local output = process_telnet_data(data)

				-- Write to terminal
				if #output > 0 then
					term:Write(output)
					term:Flush()
				end
			elseif addr_or_err == "closed" then
				-- Connection closed
				term:Write("\n")
				term:PushForegroundColor(255, 100, 100)
				term:Write("Connection closed by remote\n")
				term:PopAttribute()
				term:Flush()
				running = false
				break
			elseif addr_or_err ~= "tryagain" then
				-- Other error
				term:Write("\n")
				term:PushForegroundColor(255, 100, 100)
				term:Write("Connection error: " .. tostring(addr_or_err) .. "\n")
				term:PopAttribute()
				term:Flush()
				running = false
				break
			end
		end
	end

	-- Check for keyboard input
	local event = term:ReadEvent()

	if event then
		-- Handle mouse events
		if event.mouse then
			debug_print("Mouse event: button=%s, action=%s, x=%d, y=%d",
				event.button, event.action, event.x, event.y)

			-- Send mouse events in SGR format
			local button_code = 0

			if event.action == "moved" then
				-- Drag event - add motion bit (32) to button code
				if event.button == "left" then
					button_code = 32  -- Left button drag
				elseif event.button == "middle" then
					button_code = 33  -- Middle button drag
				elseif event.button == "right" then
					button_code = 34  -- Right button drag
				end
			elseif event.button == "left" then
				button_code = 0
			elseif event.button == "middle" then
				button_code = 1
			elseif event.button == "right" then
				button_code = 2
			elseif event.button == "wheel_up" then
				button_code = 64
			elseif event.button == "wheel_down" then
				button_code = 65
			end

			-- Add modifiers
			if event.modifiers.shift then button_code = button_code + 4 end
			if event.modifiers.alt then button_code = button_code + 8 end
			if event.modifiers.ctrl then button_code = button_code + 16 end

			local action_char
			if event.action == "moved" then
				-- For motion events, always use 'M'
				action_char = "M"
			else
				action_char = (event.action == "pressed") and "M" or "m"
			end

			local mouse_seq = string.format("\27[<%d;%d;%d%s", button_code, event.x, event.y, action_char)
			debug_print("Sending mouse: %s", mouse_seq:gsub("\27", "ESC"))
			sock:send(mouse_seq)
		elseif event.key == "c" and event.modifiers.ctrl then
			-- Ctrl+C to quit
			running = false
			break
		elseif event.key == "enter" then
			-- Send line and echo locally
			local send_data = line_buffer .. "\r\n"
			local bytes_sent = sock:send(send_data)

			if not bytes_sent then
				term:Write("\n")
				term:PushForegroundColor(255, 100, 100)
				term:Write("Failed to send data\n")
				term:PopAttribute()
				term:Flush()
				running = false
				break
			end

			line_buffer = ""
		elseif event.key == "backspace" then
			-- Handle backspace
			if #line_buffer > 0 then
				line_buffer = line_buffer:sub(1, -2)
				-- Send backspace to server
				sock:send(string.char(8))
			end
		elseif event.key == "escape" then
			-- Send escape
			sock:send(string.char(27))
		elseif event.key == "up" then
			sock:send(string.char(27) .. "[A")
		elseif event.key == "down" then
			sock:send(string.char(27) .. "[B")
		elseif event.key == "right" then
			sock:send(string.char(27) .. "[C")
		elseif event.key == "left" then
			sock:send(string.char(27) .. "[D")
		elseif event.key == "home" then
			sock:send(string.char(27) .. "[H")
		elseif event.key == "end" then
			sock:send(string.char(27) .. "[F")
		elseif event.key == "delete" then
			sock:send(string.char(27) .. "[3~")
		elseif #event.key == 1 then
			-- Regular character
			if event.modifiers.ctrl then
				-- Send control character
				local byte = event.key:byte()
				if byte >= 97 and byte <= 122 then  -- a-z
					sock:send(string.char(byte - 96))
				end
			else
				-- Regular character
				line_buffer = line_buffer .. event.key
				sock:send(event.key)
			end
		end
	end

	threads.sleep(1)
end

-- Cleanup
sock:close()
-- Disable mouse motion tracking
term:Write("\27[?1002l")
term:EnableMouse(false)
term:UseAlternateScreen(false)
term:ClearAttributeStack()
term:Write("\nDisconnected.\n")
term:Flush()

if debug_file then
	debug_file:close()
end
