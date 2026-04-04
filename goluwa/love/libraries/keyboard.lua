local love = ... or _G.love
local ENV = love._line_env
local event = import("goluwa/event.lua")
local line = import("goluwa/love/line.lua")
local input = import("goluwa/input.lua")
love.keyboard = love.keyboard or {}

function love.keyboard.getKeyRepeat()
	return ENV.keyboard_delay or 0.5, ENV.keyboard_interval or 0.1
end

function love.keyboard.setKeyRepeat(delay, interval)
	ENV.keyboard_delay = delay
	ENV.keyboard_interval = interval
end

local keyboard_map = {
	lshift = "left_shift",
	rshift = "right_shift",
	lctrl = "left_control",
	rctrl = "right_control",
	lalt = "left_alt",
	ralt = "right_alt",
	escape = "esc",
	kp_0 = "kp0",
	kp_1 = "kp1",
	kp_2 = "kp2",
	kp_3 = "kp3",
	kp_4 = "kp4",
	kp_5 = "kp5",
	kp_6 = "kp6",
	kp_7 = "kp7",
	kp_8 = "kp8",
	kp_9 = "kp9",
	kp_enter = "kpenter",
	kp_add = "kp+",
	kp_subtract = "kp-",
	kp_divide = "kp/",
	kp_multiply = "kp*",
	kp_decimal = "kp.",
	num_lock = "numlock",
	enter = "return",
}
local scancode_aliases = {
	grave = "`",
	backquote = "`",
}
local reverse_keyboard_map = {}

for k, v in pairs(keyboard_map) do
	reverse_keyboard_map[v] = k
end

local function normalize_key_name(key)
	if type(key) ~= "string" then return key end

	return scancode_aliases[key] or key
end

local function to_input_key_constant(key)
	key = normalize_key_name(key)
	return reverse_keyboard_map[key] or key
end

local function to_input_scancode(scancode)
	scancode = normalize_key_name(scancode)
	return keyboard_map[scancode] or scancode
end

local function is_any_key_down(map_key, ...)
	for index = 1, select("#", ...) do
		if input.IsKeyDown(map_key(select(index, ...))) then return true end
	end

	return false
end

function love.keyboard.isDown(...)
	return is_any_key_down(to_input_key_constant, ...)
end

function love.keyboard.isScancodeDown(...)
	return is_any_key_down(to_input_scancode, ...)
end

function love.keyboard.getScancodeFromKey(key)
	return normalize_key_name(key)
end

function love.keyboard.getKeyFromScancode(scancode)
	return normalize_key_name(scancode)
end

function love.keyboard.setTextInput(b) end

event.AddListener("LoveNewIndex", "line_keyboard", function(love, key, val)
	if key == "keypressed" or key == "keyreleased" or key == "textinput" then
		if val then
			local char_hack

			event.AddListener("KeyInput", "line", function(key, press)
				key = keyboard_map[key] or key

				if press then
					line.CallEvent("keypressed", key, char_hack)
				else
					line.CallEvent("keyreleased", key)
				end
			end)

			event.AddListener("CharInput", "line", function(char)
				char_hack = char
				line.CallEvent("textinput", char)
			end)
		else
			event.RemoveListener("CharInput", "line")
			event.RemoveListener("KeyInput", "line")
		end
	end
end)
