local T = import("test/environment.lua")

local function new_love_keyboard_env()
	local love = {_line_env = {}}
	assert(loadfile("goluwa/love/libraries/keyboard.lua"))(love)
	return love
end

T.Test("love keyboard scancode queries map to engine key names", function()
	local love = new_love_keyboard_env()
	local input = import("goluwa/input.lua")
	local original_is_key_down = input.IsKeyDown
	local seen = {}

	input.IsKeyDown = function(key)
		seen[#seen + 1] = key
		return key == "left_shift" or key == "`"
	end

	local ok, err = pcall(function()
		T(love.keyboard.isScancodeDown("lshift"))["=="](true)
		T(love.keyboard.isScancodeDown("grave"))["=="](true)
		T(love.keyboard.isScancodeDown("rshift", "grave"))["=="](true)
		T(love.keyboard.isDown("return"))["=="](false)
		T(love.keyboard.getScancodeFromKey("grave"))["=="]("`")
		T(love.keyboard.getKeyFromScancode("backquote"))["=="]("`")
	end)

	input.IsKeyDown = original_is_key_down
	if not ok then error(err, 0) end

	T(seen[1])["=="]("left_shift")
	T(seen[2])["=="]("`")
	T(seen[3])["=="]("right_shift")
	T(seen[4])["=="]("`")
	T(seen[5])["=="]("enter")
	T(#seen)["=="](5)
end)