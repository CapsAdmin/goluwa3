local test = require("helpers.test")
local attest = require("helpers.attest")
local repl = require("repl")

test.Test("repl input", function()
	local function reset()
		repl.input_buffer = ""
		repl.input_cursor = 1
		repl.selection_start = nil
		repl.history = {}
		repl.history_index = 1
	end

	local function send_key(key, modifiers)
		repl.HandleEvent(
			{
				key = key,
				modifiers = modifiers or {ctrl = false, shift = false, alt = false},
			}
		)
	end

	-- 1. Basic typing
	reset()
	send_key("a")
	send_key("b")
	attest.equal(repl.input_buffer, "ab")
	attest.equal(repl.input_cursor, 3)
	-- 2. Home/End
	send_key("home")
	attest.equal(repl.input_cursor, 1)
	send_key("end")
	attest.equal(repl.input_cursor, 3)
	-- 3. Ctrl + Left/Right (Word jumping)
	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 1
	send_key("right", {ctrl = true})
	attest.equal(repl.input_cursor, 6) -- after "hello"
	send_key("right", {ctrl = true})
	attest.equal(repl.input_cursor, 12) -- after "world"
	send_key("left", {ctrl = true})
	attest.equal(repl.input_cursor, 7) -- before "world"
	send_key("left", {ctrl = true})
	attest.equal(repl.input_cursor, 1) -- before "hello"
	-- 4. Shift + Navigation (Selection)
	reset()
	repl.input_buffer = "hello"
	repl.input_cursor = 1
	send_key("right", {shift = true})
	attest.equal(repl.selection_start, 1)
	attest.equal(repl.input_cursor, 2)
	local start, stop = repl.GetSelection()
	attest.equal(start, 1)
	attest.equal(stop, 2)
	send_key("right", {shift = true})
	attest.equal(repl.input_cursor, 3)
	start, stop = repl.GetSelection()
	attest.equal(start, 1)
	attest.equal(stop, 3)
	-- 5. Ctrl + X/C/V (Clipboard)
	-- Copy
	send_key("c", {ctrl = true})
	attest.equal(repl.clipboard, "he")
	-- Cut
	send_key("x", {ctrl = true})
	attest.equal(repl.clipboard, "he")
	attest.equal(repl.input_buffer, "llo")
	attest.equal(repl.input_cursor, 1)
	attest.equal(repl.selection_start, nil)
	-- Paste
	send_key("v", {ctrl = true})
	attest.equal(repl.input_buffer, "hello")
	attest.equal(repl.input_cursor, 3)
	-- 6. Shift + Enter (Newline) - changed from Ctrl+Enter
	reset()
	send_key("a")
	send_key("enter", {shift = true})
	send_key("b")
	attest.equal(repl.input_buffer, "a\nb")
	attest.equal(repl.input_cursor, 4)
	-- 7. Backspace/Delete with selection
	reset()
	repl.input_buffer = "hello"
	repl.input_cursor = 1
	send_key("right", {shift = true})
	send_key("right", {shift = true}) -- "he" selected
	send_key("backspace")
	attest.equal(repl.input_buffer, "llo")
	attest.equal(repl.input_cursor, 1)
	reset()
	repl.input_buffer = "hello"
	repl.input_cursor = 1
	send_key("right", {shift = true})
	send_key("right", {shift = true}) -- "he" selected
	send_key("delete")
	attest.equal(repl.input_buffer, "llo")
	attest.equal(repl.input_cursor, 1)
	-- 8. Ctrl + Backspace / Ctrl + Delete
	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 7 -- at 'w'
	send_key("backspace", {ctrl = true})
	attest.equal(repl.input_buffer, "world")
	attest.equal(repl.input_cursor, 1)
	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 6 -- at ' '
	send_key("delete", {ctrl = true})
	attest.equal(repl.input_buffer, "hello")
	attest.equal(repl.input_cursor, 6)
	-- 9. Ctrl + Shift + Navigation (Word selection)
	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 1
	send_key("right", {ctrl = true, shift = true})
	attest.equal(repl.input_cursor, 6)
	attest.equal(repl.selection_start, 1)
	send_key("right", {ctrl = true, shift = true})
	attest.equal(repl.input_cursor, 12)
	attest.equal(repl.selection_start, 1)
	send_key("left", {ctrl = true, shift = true})
	attest.equal(repl.input_cursor, 7)
	attest.equal(repl.selection_start, 1)
	-- 10. Shift + Enter (Multiline input)
	reset()
	send_key("a")
	send_key("enter", {shift = true})
	send_key("b")
	attest.equal(repl.input_buffer, "a\nb")
	attest.equal(repl.input_cursor, 4)
	-- 11. Multiple newlines
	reset()
	send_key("l")
	send_key("i")
	send_key("n")
	send_key("e")
	send_key("1")
	send_key("enter", {shift = true})
	send_key("l")
	send_key("i")
	send_key("n")
	send_key("e")
	send_key("2")
	send_key("enter", {shift = true})
	send_key("l")
	send_key("i")
	send_key("n")
	send_key("e")
	send_key("3")
	attest.equal(repl.input_buffer, "line1\nline2\nline3")
	-- 12. Shift + Enter with selection (should delete selection first)
	reset()
	repl.input_buffer = "hello"
	repl.input_cursor = 1
	send_key("right", {shift = true})
	send_key("right", {shift = true}) -- "he" selected
	send_key("enter", {shift = true})
	attest.equal(repl.input_buffer, "\nllo")
	attest.equal(repl.input_cursor, 2)
	attest.equal(repl.selection_start, nil)
	-- 13. Input scroll offset on multiline
	reset()
	repl.input_buffer = "line1\nline2\nline3\nline4\nline5\nline6"
	repl.input_cursor = #repl.input_buffer + 1
	attest.equal(repl.input_scroll_offset, 0) -- Not scrolled yet
	send_key("enter", {shift = true})
	-- After entering line 7, should auto-scroll since we have more than 5 lines
	attest.equal(repl.input_scroll_offset, 2) -- Lines 3-7 visible
	-- 14. Ctrl + Up/Down for input scrolling
	reset()
	repl.input_buffer = "line1\nline2\nline3\nline4\nline5\nline6"
	repl.input_scroll_offset = 1
	send_key("up", {ctrl = true})
	attest.equal(repl.input_scroll_offset, 0)
	send_key("down", {ctrl = true})
	attest.equal(repl.input_scroll_offset, 1)
	send_key("down", {ctrl = true})
	attest.equal(repl.input_scroll_offset, 1) -- max is 1 (6 lines - 5 visible)
end)

test.Test("repl output", function()
	-- Test StyledWrite doesn't create extra blank lines
	repl.output_lines = {}
	repl.StyledWrite("foo\nbar\nbaz\nqux")
	attest.equal(#repl.output_lines, 4)
	attest.equal(repl.output_lines[1], "foo")
	attest.equal(repl.output_lines[2], "bar")
	attest.equal(repl.output_lines[3], "baz")
	attest.equal(repl.output_lines[4], "qux")
	-- Test with trailing newline
	repl.output_lines = {}
	repl.StyledWrite("foo\nbar\nbaz\n")
	attest.equal(#repl.output_lines, 3)
	attest.equal(repl.output_lines[1], "foo")
	attest.equal(repl.output_lines[2], "bar")
	attest.equal(repl.output_lines[3], "baz")
	-- Test single line
	repl.output_lines = {}
	repl.StyledWrite("hello")
	attest.equal(#repl.output_lines, 1)
	attest.equal(repl.output_lines[1], "hello")
end)
