local test = import("goluwa/test.lua")
local attest = import("goluwa/attest.lua")
local commands = import("goluwa/cli/commands.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")
local repl = import("goluwa/cli/repl.lua")

local function send_key(key, modifiers)
	repl.HandleEvent{
		key = key,
		modifiers = modifiers or {ctrl = false, shift = false, alt = false},
	}
end

test.Test("repl input", function()
	local function reset()
		repl.input_buffer = ""
		repl.input_cursor = 1
		repl.selection_start = nil
		commands.history = {}
		commands.history_map = {}
		repl.history_index = 1
	end

	reset()
	send_key("a")
	send_key("b")
	attest.equal(repl.input_buffer, "ab")
	attest.equal(repl.input_cursor, 3)
	send_key("home")
	attest.equal(repl.input_cursor, 1)
	send_key("end")
	attest.equal(repl.input_cursor, 3)
	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 1
	send_key("right", {ctrl = true})
	attest.equal(repl.input_cursor, 6)
	send_key("right", {ctrl = true})
	attest.equal(repl.input_cursor, 12)
	send_key("left", {ctrl = true})
	attest.equal(repl.input_cursor, 7)
	send_key("left", {ctrl = true})
	attest.equal(repl.input_cursor, 1)
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
	send_key("c", {ctrl = true})
	attest.equal(clipboard.Get(), "he")
	send_key("x", {ctrl = true})
	attest.equal(clipboard.Get(), "he")
	attest.equal(repl.input_buffer, "llo")
	attest.equal(repl.input_cursor, 1)
	attest.equal(repl.selection_start, nil)
	send_key("v", {ctrl = true})
	attest.equal(repl.input_buffer, "hello")
	attest.equal(repl.input_cursor, 3)
	reset()
	send_key("a")
	send_key("enter", {shift = true})
	send_key("b")
	attest.equal(repl.input_buffer, "a\nb")
	attest.equal(repl.input_cursor, 4)
	reset()
	repl.input_buffer = "hello"
	repl.input_cursor = 1
	send_key("right", {shift = true})
	send_key("right", {shift = true})
	send_key("backspace")
	attest.equal(repl.input_buffer, "llo")
	attest.equal(repl.input_cursor, 1)
	reset()
	repl.input_buffer = "hello"
	repl.input_cursor = 1
	send_key("right", {shift = true})
	send_key("right", {shift = true})
	send_key("delete")
	attest.equal(repl.input_buffer, "llo")
	attest.equal(repl.input_cursor, 1)
	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 7
	send_key("backspace", {ctrl = true})
	attest.equal(repl.input_buffer, "world")
	attest.equal(repl.input_cursor, 1)
	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 6
	send_key("delete", {ctrl = true})
	attest.equal(repl.input_buffer, "hello")
	attest.equal(repl.input_cursor, 6)
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
	reset()
	send_key("a")
	send_key("enter", {shift = true})
	send_key("b")
	attest.equal(repl.input_buffer, "a\nb")
	attest.equal(repl.input_cursor, 4)
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
	reset()
	repl.input_buffer = "hello"
	repl.input_cursor = 1
	send_key("right", {shift = true})
	send_key("right", {shift = true})
	send_key("enter", {shift = true})
	attest.equal(repl.input_buffer, "\nllo")
	attest.equal(repl.input_cursor, 2)
	attest.equal(repl.selection_start, nil)
	reset()
	repl.input_buffer = "line1\nline2\nline3\nline4\nline5\nline6"
	repl.input_cursor = #repl.input_buffer + 1
	attest.equal(repl.input_scroll_offset, 0)
	send_key("enter", {shift = true})
	attest.equal(repl.input_scroll_offset, 2)
	reset()
	repl.input_buffer = "line1\nline2\nline3\nline4\nline5\nline6"
	repl.input_scroll_offset = 1
	send_key("up", {ctrl = true})
	attest.equal(repl.input_scroll_offset, 0)
	send_key("down", {ctrl = true})
	attest.equal(repl.input_scroll_offset, 1)
	send_key("down", {ctrl = true})
	attest.equal(repl.input_scroll_offset, 1)
end)

test.Test("repl multiline navigation", function()
	local function reset()
		repl.input_buffer = ""
		repl.input_cursor = 1
		repl.selection_start = nil
		commands.history = {}
		commands.history_map = {}
		repl.history_index = 1
		repl.input_scroll_offset = 0
	end

	reset()
	repl.input_buffer = "hello\nworld"
	repl.input_cursor = 9
	send_key("up")
	attest.equal(repl.input_cursor, 3)
	send_key("down")
	attest.equal(repl.input_cursor, 9)
	reset()
	repl.input_buffer = "hello\nworld\ntest"
	repl.input_cursor = 10
	send_key("home")
	attest.equal(repl.input_cursor, 7)
	send_key("end")
	attest.equal(repl.input_cursor, 12)
	reset()
	commands.history = {"prev1", "prev2"}
	commands.history_map = {prev1 = true, prev2 = true}
	repl.history_index = 3
	repl.input_buffer = "line1\nline2"
	repl.input_cursor = 1
	send_key("up")
	attest.equal(repl.input_buffer, "prev2")
	reset()
	commands.history = {"prev1"}
	commands.history_map = {prev1 = true}
	repl.history_index = 2
	repl.input_buffer = "line1\nline2"
	repl.input_cursor = 1
	send_key("up")
	attest.equal(repl.input_buffer, "prev1")
	attest.equal(repl.history_index, 1)
	send_key("down")
	attest.equal(repl.input_buffer, "line1\nline2")
	reset()
	commands.history = {"prev1"}
	commands.history_map = {prev1 = true}
	repl.history_index = 2
	repl.input_buffer = "typing"
	repl.input_cursor = 1
	send_key("up")
	attest.equal(repl.input_buffer, "prev1")
	send_key("down")
	attest.equal(repl.input_buffer, "typing")
end)

test.Test("repl wrapped visual navigation", function()
	local function reset()
		repl.input_buffer = ""
		repl.input_cursor = 1
		repl.selection_start = nil
		repl.input_scroll_offset = 0
		commands.history = {}
		commands.history_map = {}
		repl.history_index = 1
	end

	local old_term = repl.term
	repl.term = {
		GetSize = function()
			return 8, 24
		end,
	}
	reset()
	repl.input_buffer = "abcdefghij"
	repl.input_cursor = 8
	send_key("up")
	attest.equal(repl.input_cursor, 3)
	send_key("down")
	attest.equal(repl.input_cursor, 8)
	reset()
	repl.input_buffer = string.rep("a", 26)
	repl.input_cursor = #repl.input_buffer + 1
	send_key("b")
	attest.equal(repl.input_scroll_offset, 1)
	reset()
	repl.input_buffer = string.rep("a", 25)
	repl.input_cursor = #repl.input_buffer + 1
	send_key("down", {ctrl = true})
	attest.equal(repl.input_scroll_offset, 1)
	repl.term = old_term
end)

test.Test("repl advanced editing", function()
	local function reset()
		repl.input_buffer = ""
		repl.input_cursor = 1
		repl.selection_start = nil
	end

	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 5
	send_key("a", {ctrl = true})
	attest.equal(repl.selection_start, 1)
	attest.equal(repl.input_cursor, 12)
	local start, stop = repl.GetSelection()
	attest.equal(start, 1)
	attest.equal(stop, 12)
	reset()
	repl.input_buffer = "line1\nline2\nline3"
	repl.input_cursor = 9
	send_key("x", {ctrl = true})
	attest.equal(clipboard.Get(), "line2\n")
	attest.equal(repl.input_buffer, "line1\nline3")
	attest.equal(repl.input_cursor, 7)
	reset()
	repl.input_buffer = "line1\nline2\nline3"
	repl.input_cursor = 9
	send_key("d", {ctrl = true})
	attest.equal(repl.input_buffer, "line1\nline2\nline2\nline3")
	attest.equal(repl.input_cursor, 13)
	reset()
	repl.input_buffer = "hello world"
	repl.input_cursor = 1
	repl.selection_start = 1
	repl.input_cursor = 6
	send_key("x", {ctrl = true})
	attest.equal(clipboard.Get(), "hello")
	attest.equal(repl.input_buffer, " world")
	reset()
	repl.HandleEvent{paste = true, text = "print(1)\nprint(2)", raw_input = ""}
	attest.equal(repl.input_buffer, "print(1)\nprint(2)")
	attest.equal(repl.input_cursor, #repl.input_buffer + 1)
end)

test.Test("repl history", function()
	local function reset()
		repl.input_buffer = ""
		repl.input_cursor = 1
		commands.history = {}
		commands.history_map = {}
		repl.history_index = 1
	end

	reset()
	repl.input_buffer = "asdf"
	repl.HandleEvent{key = "enter", modifiers = {ctrl = false, shift = false, alt = false}}
	repl.input_buffer = "asdf"
	repl.HandleEvent{key = "enter", modifiers = {ctrl = false, shift = false, alt = false}}
	attest.equal(#commands.history, 1)
	attest.equal(commands.history[1], "asdf")
	reset()
	repl.input_buffer = ""
	repl.HandleEvent{key = "enter", modifiers = {ctrl = false, shift = false, alt = false}}
	attest.equal(#commands.history, 0)
	reset()
	repl.input_buffer = "first"
	repl.HandleEvent{key = "enter", modifiers = {ctrl = false, shift = false, alt = false}}
	repl.input_buffer = "second"
	repl.HandleEvent{key = "enter", modifiers = {ctrl = false, shift = false, alt = false}}
	attest.equal(#commands.history, 2)
	attest.equal(commands.history[1], "first")
	attest.equal(commands.history[2], "second")
	repl.input_buffer = "first"
	repl.HandleEvent{key = "enter", modifiers = {ctrl = false, shift = false, alt = false}}
	attest.equal(#commands.history, 2)
	attest.equal(commands.history[1], "second")
	attest.equal(commands.history[2], "first")
end)
