local terminal = require("terminal")

-- Initialize terminal
local term = terminal.WrapFile(io.stdin, io.stdout)
term:UseAlternateScreen(true)
term:EnableCaret(false)
term:Clear()

-- Enable mouse tracking with motion events
term:EnableMouse(true)
-- Enable mouse motion tracking (mode 1002 = button motion only)
term:Write("\27[?1002h")
term:Flush()

-- Draw header
term:PushBold()
term:PushForegroundColor(100, 200, 255)
term:Write("Mouse & Keyboard Input Test\n")
term:PopAttribute()
term:PopAttribute()
term:Write("Move mouse, click, drag, scroll wheel. Type keys.\n")
term:Write("Press Ctrl+C to quit\n\n")
term:Flush()

local running = true
local mouse_button_held = nil
local last_x, last_y = 0, 0
local click_count = 0
local drag_count = 0
local move_count = 0
local key_count = 0
local last_key = nil
local last_key_char = nil

while running do
	local event = term:ReadEvent()

	if event then
		if event.key == "c" and event.modifiers.ctrl then
			running = false
			break
		end

		if event.key and not event.mouse then
			-- Keyboard event
			key_count = key_count + 1
			last_key = event.key
			last_key_char = event.char

			-- Clear screen and redraw
			term:Clear()
			term:SetCaretPosition(1, 1)

			-- Header
			term:PushBold()
			term:PushForegroundColor(100, 200, 255)
			term:Write("Mouse & Keyboard Input Test\n")
			term:PopAttribute()
			term:PopAttribute()
			term:Write("Move mouse, click, drag, scroll wheel. Type keys.\n")
			term:Write("Press Ctrl+C to quit\n\n")

			-- Stats
			term:PushForegroundColor(200, 200, 100)
			term:Write(string.format("Keys: %d  Clicks: %d  Drags: %d  Moves: %d\n\n", key_count, click_count, drag_count, move_count))
			term:PopAttribute()

			-- Current keyboard event details
			term:PushBold()
			term:Write("Last Keyboard Event:\n")
			term:PopAttribute()

			term:Write(string.format("  Key: %s\n", tostring(event.key)))
			term:Write(string.format("  Char: %s\n", event.char and string.format("'%s'", event.char) or "nil"))
			term:Write(string.format("  Modifiers: ctrl=%s shift=%s alt=%s\n",
				tostring(event.modifiers.ctrl),
				tostring(event.modifiers.shift),
				tostring(event.modifiers.alt)))

			term:Flush()
		elseif event.mouse then
			-- Track button state
			if event.action == "pressed" then
				mouse_button_held = event.button
				click_count = click_count + 1
			elseif event.action == "released" then
				mouse_button_held = nil
			elseif event.action == "moved" then
				if mouse_button_held then
					drag_count = drag_count + 1
				else
					move_count = move_count + 1
				end
			end

			-- Clear screen and redraw
			term:Clear()
			term:SetCaretPosition(1, 1)

			-- Header
			term:PushBold()
			term:PushForegroundColor(100, 200, 255)
			term:Write("Mouse & Keyboard Input Test\n")
			term:PopAttribute()
			term:PopAttribute()
			term:Write("Move mouse, click, drag, scroll wheel. Type keys.\n")
			term:Write("Press Ctrl+C to quit\n\n")

			-- Stats
			term:PushForegroundColor(200, 200, 100)
			term:Write(string.format("Keys: %d  Clicks: %d  Drags: %d  Moves: %d\n\n", key_count, click_count, drag_count, move_count))
			term:PopAttribute()

			-- Current mouse event details
			term:PushBold()
			term:Write("Last Mouse Event:\n")
			term:PopAttribute()

			term:Write(string.format("  Position: x=%d, y=%d\n", event.x, event.y))
			term:Write(string.format("  Button: %s\n", event.button))
			term:Write(string.format("  Action: %s\n", event.action))
			term:Write(string.format("  Modifiers: ctrl=%s shift=%s alt=%s\n",
				tostring(event.modifiers.ctrl),
				tostring(event.modifiers.shift),
				tostring(event.modifiers.alt)))

			-- Button state
			term:Write(string.format("\n  Button Held: %s\n", tostring(mouse_button_held)))

			-- Visual indicator at mouse position
			if event.action == "pressed" then
				term:PushForegroundColor(255, 100, 100)
				term:WriteStringToScreen(event.x, event.y, "X")
				term:PopAttribute()
			elseif event.action == "moved" and mouse_button_held then
				term:PushForegroundColor(100, 255, 100)
				term:WriteStringToScreen(event.x, event.y, "*")
				term:PopAttribute()
			elseif event.action == "moved" then
				term:PushForegroundColor(200, 200, 200)
				term:WriteStringToScreen(event.x, event.y, ".")
				term:PopAttribute()
			end

			-- Draw line during drag
			if event.action == "moved" and mouse_button_held and last_x > 0 and last_y > 0 then
				-- Simple line drawing (horizontal or vertical only for simplicity)
				if event.x == last_x then
					-- Vertical line
					local start_y = math.min(last_y, event.y)
					local end_y = math.max(last_y, event.y)
					for y = start_y, end_y do
						term:WriteStringToScreen(event.x, y, "|")
					end
				elseif event.y == last_y then
					-- Horizontal line
					local start_x = math.min(last_x, event.x)
					local end_x = math.max(last_x, event.x)
					for x = start_x, end_x do
						term:WriteStringToScreen(x, event.y, "-")
					end
				end
			end

			last_x, last_y = event.x, event.y
			term:Flush()
		end
	end
end

-- Cleanup
term:Write("\27[?1002l")
term:EnableMouse(false)
term:EnableCaret(true)
term:UseAlternateScreen(false)
term:Clear()
term:Write("Input test finished.\n")
term:Write(string.format("Total - Keys: %d, Clicks: %d, Drags: %d, Moves: %d\n", key_count, click_count, drag_count, move_count))
