local line = import("goluwa/love/line.lua")
local event = import("goluwa/event.lua")
local window = import("goluwa/window.lua")
local input = import("goluwa/input.lua")
local package = _G.package
local love = ... or _G.love
local ENV = love._line_env
love.mouse = love.mouse or {}

local function get_active_window()
	return window.current
end

local function apply_mouse_state()
	local wnd = get_active_window()

	if not wnd then return end

	if ENV.mouse_relative_mode then
		wnd:SetMouseTrapped(true)
		wnd:SetCursor("hidden")
		return
	end

	wnd:SetMouseTrapped(false)

	if ENV.mouse_visible == false then
		wnd:SetCursor("hidden")
		return
	end

	local cursor = ENV.mouse_cursor

	if type(cursor) == "table" and cursor.__line_type == "Cursor" and cursor.getType then
		cursor = cursor:getType()
	end

	if type(cursor) ~= "string" then cursor = "arrow" end

	wnd:SetCursor(cursor)
end

function love.mouse.setPosition(x, y) --window.SetMousePosition(Vec2(x, y))
end

function love.mouse.getPosition()
	return window.GetMousePosition():Unpack()
end

function love.mouse.getX()
	return window.GetMousePosition().x
end

function love.mouse.getY()
	return window.GetMousePosition().y
end

function love.mouse.setRelativeMode(b)
	ENV.mouse_relative_mode = not not b
	apply_mouse_state()
end

love.mouse.setGrabbed = love.mouse.setRelativeMode
local Cursor = line.TypeTemplate("Cursor")
line.RegisterType(Cursor)

function love.mouse.newCursor()
	local obj = line.CreateObject("Cursor")
	return obj
end

function love.mouse.getCursor()
	local obj = line.CreateObject("Cursor")
	obj.getType = function()
		return window.GetCursor()
	end
	return obj
end

function love.mouse.setCursor(cursor)
	ENV.mouse_cursor = cursor
	apply_mouse_state()
end

function love.mouse.getSystemCursor(name)
	local obj = line.CreateObject("Cursor")
	obj.getType = function()
		return name or "arrow"
	end
	return obj
end

do
	ENV.mouse_visible = true
	ENV.mouse_relative_mode = false
	ENV.mouse_cursor = "arrow"

	function love.mouse.setVisible(bool)
		ENV.mouse_visible = bool
		apply_mouse_state()
	end

	function love.mouse.getVisible(bool)
		return ENV.mouse_visible
	end
end

apply_mouse_state()
local mouse_keymap = {
	button_1 = "l",
	button_2 = "r",
	button_3 = "m",
	button_4 = "x1",
	button_5 = "x2",
	mwheel_up = "wu",
	mwheel_down = "wd",
}
local mouse_keymap_10 = {
	button_1 = 1,
	button_2 = 2,
	button_3 = 3,
	button_4 = 4,
	button_5 = 5,
}
local mouse_keymap_reverse = {}

for k, v in pairs(mouse_keymap) do
	mouse_keymap_reverse[v] = k
end

local mouse_keymap_10_reverse = {}

for k, v in pairs(mouse_keymap_10) do
	mouse_keymap_10_reverse[v] = k
end

local function mouse_uses_numeric_buttons()
	return (love._version_major or 0) >= 11
end

local function refresh_loveframes_hover_state()
	local loaded = package and package.loaded

	if not loaded then return end

	local loveframes = loaded.loveframes

	if type(loveframes) ~= "table" or type(loveframes.GetCollisions) ~= "function" then
		return
	end

	local ok, collisions = pcall(loveframes.GetCollisions)

	if not ok or type(collisions) ~= "table" then return end

	loveframes.collisions = collisions
	loveframes.hoverobject = false
	loveframes.hover = false

	if #collisions > 0 then
		local top = collisions[#collisions]
		local downobject = loveframes.downobject

		if not downobject or downobject == top then
			loveframes.hoverobject = top
			loveframes.hover = true
		end
	end
end

function love.mouse.isDown(key)
	return input.IsMouseDown(mouse_keymap_10_reverse[key]) or
		input.IsMouseDown(mouse_keymap_reverse[key])
end

event.AddListener("LoveNewIndex", "line_mouse", function(love, key, val)
	if key == "mousepressed" or key == "mousereleased" then
		if val then
			event.AddListener("MouseInput", "line", function(key, press)
				local x, y = window.GetMousePosition():Unpack()
				local mapped_button = mouse_uses_numeric_buttons() and mouse_keymap_10[key] or mouse_keymap[key]

				if key == "mwheel_up" or key == "mwheel_down" then
					refresh_loveframes_hover_state()
					line.CallEvent("wheelmoved", 0, key == "mwheel_up" and 1 or -1)
				end

				if mapped_button == nil then return end

				refresh_loveframes_hover_state()

				if press then
					line.CallEvent("mousepressed", x, y, mapped_button)
				else
					line.CallEvent("mousereleased", x, y, mapped_button)
				end
			end)
		else
			event.RemoveListener("MouseInput", "line")
		end
	end
end)
