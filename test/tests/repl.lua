local test = require("helpers.test")
local attest = require("helpers.attest")
local clipboard = ""

do
	require("output").normal_stdout = true -- Ensure normal stdout for tests
	package.loaded["bindings.clipboard"] = {
		Get = function()
			return clipboard
		end,
		Set = function(text)
			clipboard = tostring(text)
		end,
	}
end

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
	attest.equal(clipboard, "he")
	-- Cut
	send_key("x", {ctrl = true})
	attest.equal(clipboard, "he")
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

test.Test("repl multiline navigation", function()
	local function reset()
		repl.input_buffer = ""
		repl.input_cursor = 1
		repl.selection_start = nil
		repl.history = {}
		repl.history_index = 1
		repl.input_scroll_offset = 0
	end

	local function send_key(key, modifiers)
		repl.HandleEvent(
			{
				key = key,
				modifiers = modifiers or {ctrl = false, shift = false, alt = false},
			}
		)
	end

	-- 1. Up/down navigation between lines
	reset()
	repl.input_buffer = "hello\nworld"
	repl.input_cursor = 9 -- at 'o' in "world"
	send_key("up")
	attest.equal(repl.input_cursor, 3) -- at 'l' in "hello"
	send_key("down")
	attest.equal(repl.input_cursor, 9) -- back to 'o' in "world"
	-- 2. Home/End on multiline (current line only)
	reset()
	repl.input_buffer = "hello\nworld\ntest"
	repl.input_cursor = 10 -- at 'l' in "world"
	send_key("home")
	attest.equal(repl.input_cursor, 7) -- start of "world" line
	send_key("end")
	attest.equal(repl.input_cursor, 12) -- end of "world" line (at \n)
	-- 3. History navigation from first line
	reset()
	repl.history = {"prev1", "prev2"}
	repl.history_index = 3
	repl.input_buffer = "line1\nline2"
	repl.input_cursor = 1
	send_key("up") -- Should navigate to history
	attest.equal(repl.input_buffer, "prev2")
	-- 4. History navigation: pressing down at last history entry restores empty input
	reset()
	repl.history = {"prev1"}
	repl.history_index = 2 -- Currently at fresh input (beyond history)
	repl.input_buffer = "line1\nline2"
	repl.input_cursor = 1 -- On first line so up will navigate to history
	-- First, go up to enter history
	send_key("up")
	attest.equal(repl.input_buffer, "prev1") -- Now viewing history[1]
	attest.equal(repl.history_index, 1)
	-- Now press down to go back to fresh input
	send_key("down")
	attest.equal(repl.input_buffer, "line1\nline2") -- Should restore saved input
	-- 5. Saved input restoration
	reset()
	repl.history = {"prev1"}
	repl.history_index = 2
	repl.input_buffer = "typing"
	repl.input_cursor = 1
	send_key("up") -- Enter history mode
	attest.equal(repl.input_buffer, "prev1")
	send_key("down") -- Go back
	attest.equal(repl.input_buffer, "typing") -- Should restore saved input
end)

test.Test("repl advanced editing", function()
	local function reset()
		repl.input_buffer = ""
		repl.input_cursor = 1
		repl.selection_start = nil
		repl.clipboard = ""
	end

	local function send_key(key, modifiers)
		repl.HandleEvent(
			{
				key = key,
				modifiers = modifiers or {ctrl = false, shift = false, alt = false},
			}
		)
	end

	-- 1. Ctrl+A to select all
	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 5
	send_key("a", {ctrl = true})
	attest.equal(repl.selection_start, 1)
	attest.equal(repl.input_cursor, 12)
	local start, stop = repl.GetSelection()
	attest.equal(start, 1)
	attest.equal(stop, 12)
	-- 2. Ctrl+X to cut current line (no selection)
	reset()
	repl.input_buffer = "line1\nline2\nline3"
	repl.input_cursor = 9 -- in "line2"
	send_key("x", {ctrl = true})
	attest.equal(clipboard, "line2\n")
	attest.equal(repl.input_buffer, "line1\nline3")
	attest.equal(repl.input_cursor, 7) -- start of where line2 was
	-- 3. Ctrl+D to duplicate line
	reset()
	repl.input_buffer = "line1\nline2\nline3"
	repl.input_cursor = 9 -- in "line2"
	send_key("d", {ctrl = true})
	attest.equal(repl.input_buffer, "line1\nline2\nline2\nline3")
	attest.equal(repl.input_cursor, 13) -- start of duplicated line
	-- 4. Ctrl+X with selection (should cut selection)
	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 1
	repl.selection_start = 1
	repl.input_cursor = 6 -- "hello" selected
	send_key("x", {ctrl = true})
	attest.equal(clipboard, "hello")
	attest.equal(repl.input_buffer, " world")
end)

test.Test("repl history", function()
	local function reset()
		repl.input_buffer = ""
		repl.input_cursor = 1
		repl.history = {}
		repl.history_index = 1
	end

	-- 1. No duplicate history entries
	reset()
	repl.input_buffer = "test"
	repl.HandleEvent({key = "enter", modifiers = {ctrl = false, shift = false, alt = false}})
	repl.input_buffer = "test"
	repl.HandleEvent({key = "enter", modifiers = {ctrl = false, shift = false, alt = false}})
	attest.equal(#repl.history, 1)
	attest.equal(repl.history[1], "test")
	-- 2. No empty history entries
	reset()
	repl.input_buffer = ""
	repl.HandleEvent({key = "enter", modifiers = {ctrl = false, shift = false, alt = false}})
	attest.equal(#repl.history, 0)
	-- 3. Different entries are added
	reset()
	repl.input_buffer = "first"
	repl.HandleEvent({key = "enter", modifiers = {ctrl = false, shift = false, alt = false}})
	repl.input_buffer = "second"
	repl.HandleEvent({key = "enter", modifiers = {ctrl = false, shift = false, alt = false}})
	attest.equal(#repl.history, 2)
	attest.equal(repl.history[1], "first")
	attest.equal(repl.history[2], "second")
end)
