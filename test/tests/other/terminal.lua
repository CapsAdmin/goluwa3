local test = import("goluwa/test.lua")
local attest = import("goluwa/attest.lua")

if jit.os == "Windows" then
	test.Unavailable("terminal escape decoding is POSIX-only")
	return
end

local terminal = import("goluwa/bindings/terminal.lua")

local function decode_one(bytes, opts)
	local events = terminal._DecodeBytes(bytes, opts)
	attest.equal(#events, 1)
	return events[1]
end

test.Test("plain characters and control keys", function()
	local events = terminal._DecodeBytes("ab")
	attest.equal(#events, 2)
	attest.equal(events[1].key, "a")
	attest.equal(events[2].key, "b")
	attest.equal(decode_one("\r").key, "enter")
	attest.equal(decode_one("\n").key, "enter")
	attest.equal(decode_one("\t").key, "tab")
	attest.equal(decode_one(string.char(127)).key, "backspace")
	attest.equal(decode_one(string.char(8)).key, "backspace")
	local ctrl_a = decode_one(string.char(1))
	attest.equal(ctrl_a.key, "a")
	attest.equal(ctrl_a.modifiers.ctrl, true)
	-- Ctrl+W is remapped to backspace
	local ctrl_w = decode_one(string.char(23))
	attest.equal(ctrl_w.key, "backspace")
	attest.equal(ctrl_w.modifiers.ctrl, true)
end)

test.Test("lone escape key", function()
	attest.equal(decode_one("\27").key, "escape")
end)

test.Test("plain arrow/nav keys via escape_sequences table", function()
	attest.equal(decode_one("\27[A").key, "up")
	attest.equal(decode_one("\27[B").key, "down")
	attest.equal(decode_one("\27[C").key, "right")
	attest.equal(decode_one("\27[D").key, "left")
	attest.equal(decode_one("\27[H").key, "home")
	attest.equal(decode_one("\27[F").key, "end")
	attest.equal(decode_one("\27[15~").key, "f5")
	local shift_tab = decode_one("\27[Z")
	attest.equal(shift_tab.key, "tab")
	attest.equal(shift_tab.modifiers.shift, true)
end)

test.Test("CSI sequences with modifiers", function()
	-- \x1b[1;MODkey form
	local ctrl_right = decode_one("\27[1;5C")
	attest.equal(ctrl_right.key, "right")
	attest.equal(ctrl_right.modifiers.ctrl, true)
	attest.equal(ctrl_right.modifiers.shift, false)
	attest.equal(ctrl_right.modifiers.alt, false)
	local shift_right = decode_one("\27[1;2C")
	attest.equal(shift_right.key, "right")
	attest.equal(shift_right.modifiers.shift, true)
	local alt_right = decode_one("\27[1;3C")
	attest.equal(alt_right.key, "right")
	attest.equal(alt_right.modifiers.alt, true)
	-- \x1b[MODkey form (no literal "1;")
	local ctrl_right_short = decode_one("\27[5C")
	attest.equal(ctrl_right_short.key, "right")
	attest.equal(ctrl_right_short.modifiers.ctrl, true)
end)

test.Test("tilde-terminated sequences with modifiers", function()
	local ctrl_delete = decode_one("\27[3;5~")
	attest.equal(ctrl_delete.key, "delete")
	attest.equal(ctrl_delete.modifiers.ctrl, true)
end)

test.Test("SS3 sequences", function()
	local up = decode_one("\27OA")
	attest.equal(up.key, "up")
	attest.equal(up.modifiers.shift, false)
	-- SS3 M is treated as Shift+Enter
	local shift_enter = decode_one("\27OM")
	attest.equal(shift_enter.key, "enter")
	attest.equal(shift_enter.modifiers.shift, true)
end)

test.Test("Alt+key combinations", function()
	local alt_a = decode_one("\27a")
	attest.equal(alt_a.key, "a")
	attest.equal(alt_a.modifiers.alt, true)
	local alt_enter = decode_one("\27\r")
	attest.equal(alt_enter.key, "enter")
	attest.equal(alt_enter.modifiers.alt, true)
	local alt_backspace = decode_one("\27" .. string.char(127))
	attest.equal(alt_backspace.key, "backspace")
	attest.equal(alt_backspace.modifiers.alt, true)
	local alt_backspace2 = decode_one("\27" .. string.char(8))
	attest.equal(alt_backspace2.key, "backspace")
	attest.equal(alt_backspace2.modifiers.alt, true)
end)

test.Test("SGR mouse events", function()
	local press = decode_one("\27[<0;10;20M")
	attest.equal(press.mouse, true)
	attest.equal(press.button, "left")
	attest.equal(press.action, "pressed")
	attest.equal(press.x, 10)
	attest.equal(press.y, 20)
	local release = decode_one("\27[<0;10;20m")
	attest.equal(release.action, "released")
	-- button_code 0x10 = ctrl held
	local ctrl_click = decode_one("\27[<16;3;4M")
	attest.equal(ctrl_click.modifiers.ctrl, true)
	attest.equal(ctrl_click.modifiers.shift, false)
	-- motion bit (0x20) set -> drag/move
	local moved = decode_one("\27[<32;5;5M")
	attest.equal(moved.action, "moved")
	-- wheel bit (0x40) set
	local wheel = decode_one("\27[<64;1;1M")
	attest.equal(wheel.button, "wheel_up")
end)

test.Test("mouse events are swallowed when mouse reporting is disabled", function()
	local event = decode_one("\27[<0;10;20M", {mouse_enabled = false})
	attest.not_equal(event.mouse, true)
	attest.equal(event.key, "escape")
end)

test.Test("malformed SGR-like sequence does not crash and falls back to escape", function()
	-- Looks terminated (digits/`;` then `M`) but has no leading button number.
	local event = decode_one("\27[<;M")
	attest.equal(event.mouse, nil)
	attest.equal(event.key, "escape")
end)

test.Test("unrecognized letter-terminated CSI sequence falls back to escape", function()
	local event = decode_one("\27[9;9;9X")
	attest.equal(event.key, "escape")
end)

test.Test("bracketed paste", function()
	local events = terminal._DecodeBytes("\27[200~hello world\27[201~", {bracketed_paste_enabled = true})
	attest.equal(#events, 1)
	attest.equal(events[1].paste, true)
	attest.equal(events[1].text, "hello world")
	attest.equal(events[1].raw_input, "\27[200~hello world\27[201~")
end)

test.Test("bracketed paste followed by more input", function()
	local events = terminal._DecodeBytes("\27[200~abc\27[201~xy", {bracketed_paste_enabled = true})
	attest.equal(#events, 3)
	attest.equal(events[1].paste, true)
	attest.equal(events[1].text, "abc")
	attest.equal(events[2].key, "x")
	attest.equal(events[3].key, "y")
end)

test.Test("cursor position report parsing", function()
	local x, y = terminal._ParseCursorReport("\27[12;34R")
	attest.equal(x, 12)
	attest.equal(y, 34)
	attest.equal(terminal._ParseCursorReport("garbage"), nil)
	attest.equal(terminal._ParseCursorReport("\27[12;R"), nil)
	attest.equal(terminal._ParseCursorReport("\27[;34R"), nil)
	attest.equal(terminal._ParseCursorReport("\27[12;34X"), nil)
end)

test.Test("read_coordinates accumulates bytes across multiple Read() calls", function()
	-- Regression test: read_coordinates() used to hand each single byte from
	-- Read() straight to the parser without accumulating, so a real multi-byte
	-- CPR response like "\27[12;34R" (fed one byte at a time, as Read() does)
	-- could never match and the loop would spin forever.
	local bytes = "\27[12;34R"
	local pos = 0
	local fake_self = {
		Read = function()
			pos = pos + 1

			if pos > #bytes then return nil end

			return bytes:sub(pos, pos)
		end,
	}
	local x, y = terminal._ReadCoordinates(fake_self)
	attest.equal(x, 12)
	attest.equal(y, 34)
end)
