local android = import("goluwa/bindings/android.lua")

if not android.active then return end

local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local players = import("lua/players.lua")
local inventory_menu = import("lua/inventory_menu.lua")
local STICK_REGION = 0.4
local STICK_RADIUS = 0.2
local STICK_DEAD_ZONE = 0.35
local LOOK_UNITS_PER_HEIGHT = 360
local OFF_ALPHA = 0.3
local ON_ALPHA = 0.65
local white = {r = 1, g = 1, b = 1, a = 1}
-- positions are in screen heights from the bottom right corner (top right for negative y)
local BUTTONS = {
	{
		name = "fire",
		x = 0.3,
		y = 0.26,
		radius = 0.11,
		label = "FIRE",
		mouse = "button_1",
	},
	{name = "jump", x = 0.52, y = 0.16, radius = 0.07, label = "UP", key = "space"},
	{
		name = "crouch",
		x = 0.2,
		y = 0.52,
		radius = 0.07,
		label = "DOWN",
		key = "left_control",
	},
	{name = "use", x = 0.5, y = 0.38, radius = 0.06, label = "USE", key = "e"},
	{name = "mode", x = 0.17, y = -0.1, radius = 0.065, tap = "mode"},
	{name = "next", x = 0.33, y = -0.1, radius = 0.06, label = ">", tap = "next"},
	{
		name = "previous",
		x = 0.47,
		y = -0.1,
		radius = 0.06,
		label = "<",
		tap = "previous",
	},
}
local touches = {}
local held = {}
local stick = nil
local window

local function get_rig()
	local rig = players.GetLocal()

	if not (rig and rig:IsValid()) then return end

	if not rig.player_input:IsReceivingInput() or inventory_menu.IsOpen() then
		return
	end

	return rig
end

local function place(button, w, h)
	local y = button.y < 0 and -button.y * h or h - button.y * h
	return w - button.x * h, y, button.radius * h
end

local function set_held(name, down)
	if (held[name] or false) == down then return end

	held[name] = down
	local button

	for _, other in ipairs(BUTTONS) do
		if other.name == name then
			button = other

			break
		end
	end

	if button then
		if button.key then window:OnKeyInput(button.key, down) end

		if button.mouse then window:OnMouseInput(button.mouse, down) end
	end
end

local function set_key(key, down)
	window:OnKeyInput(key, down)
end

local function release_all()
	for name in pairs(held) do
		set_held(name, false)
	end

	set_key("w", false)
	set_key("a", false)
	set_key("s", false)
	set_key("d", false)
	table.clear(touches)
	stick = nil
end

local function update_stick()
	local x, y = 0, 0

	if stick then
		local radius = STICK_RADIUS * select(2, render2d.GetSize())
		local offset = (stick.position - stick.origin) / radius
		local length = offset:GetLength()

		if length > 1 then offset = offset / length end

		x, y = offset.x, offset.y
		stick.knob = stick.origin + offset * radius
	end

	set_key("w", y < -STICK_DEAD_ZONE)
	set_key("s", y > STICK_DEAD_ZONE)
	set_key("a", x < -STICK_DEAD_ZONE)
	set_key("d", x > STICK_DEAD_ZONE)
end

local function tap(rig, action)
	if action == "mode" then
		rig.player_input:OnCameraToggleMode()
	elseif action == "next" then
		rig.player_input:ScrollWeapons(1, 1, false)
	elseif action == "previous" then
		rig.player_input:ScrollWeapons(-1, 1, false)
	end
end

event.AddListener("TouchInput", "touch_controls", function(id, phase, position)
	window = window or system.GetWindow()
	local w, h = render2d.GetSize()

	if phase == "down" then
		local rig = get_rig()

		if not rig then return end

		for _, button in ipairs(BUTTONS) do
			local x, y, radius = place(button, w, h)

			if (position - Vec2(x, y)):GetLength() <= radius * 1.3 then
				touches[id] = {kind = "button", button = button}

				if button.tap then tap(rig, button.tap) else set_held(button.name, true) end

				return true
			end
		end

		if position.x < w * STICK_REGION and not stick then
			stick = {
				id = id,
				origin = position:Copy(),
				position = position:Copy(),
				knob = position:Copy(),
			}
			touches[id] = {kind = "stick"}
			update_stick()
			return true
		end

		touches[id] = {kind = "look", last = position:Copy()}
		return true
	end

	local touch = touches[id]

	if not touch then return end

	if phase == "move" then
		if touch.kind == "stick" then
			stick.position = position:Copy()
			update_stick()
		elseif touch.kind == "look" then
			window:SetMouseDelta(window:GetMouseDelta() + (position - touch.last) * (LOOK_UNITS_PER_HEIGHT / h))
			touch.last = position:Copy()
		end
	elseif phase == "up" then
		if touch.kind == "button" and not touch.button.tap then
			set_held(touch.button.name, false)
		elseif touch.kind == "stick" then
			stick = nil
			update_stick()
		end

		touches[id] = nil
	end
end)

event.AddListener("Update", "touch_controls", function()
	if next(touches) and not get_rig() then release_all() end
end)

event.AddListener("Draw2D", "touch_controls", function()
	local rig = get_rig()

	if not rig then return end

	local w, h = render2d.GetSize()
	render2d.SetTexture(nil)

	if stick then
		local radius = STICK_RADIUS * h
		render2d.SetColor(1, 1, 1, 0.12)
		render2d.PushBorderRadius(radius, radius, radius, radius)
		render2d.DrawRect(stick.origin.x - radius, stick.origin.y - radius, radius * 2, radius * 2)
		render2d.SetColor(1, 1, 1, ON_ALPHA)
		render2d.PopBorderRadius()
		local knob = radius * 0.4
		render2d.PushBorderRadius(knob, knob, knob, knob)
		render2d.DrawRect(stick.knob.x - knob, stick.knob.y - knob, knob * 2, knob * 2)
		render2d.PopBorderRadius()
	end

	local weapon = rig.weapon_holder:GetWeapon("right")
	render2d.DrawText{
		text = weapon and weapon.weapon:GetDisplayName() or "no weapon",
		x = w - 0.4 * h,
		y = 0.2 * h,
		size = math.max(math.floor(0.05 * h), 8),
		foreground_color = white,
		align_x = 0.5,
		align_y = 0.5,
		alpha = 0.9,
	}

	for _, button in ipairs(BUTTONS) do
		local x, y, radius = place(button, w, h)
		local label = button.label

		if button.name == "mode" then
			label = rig.player_input.Mode == "fly" and "FLY" or "WALK"
		end

		render2d.SetColor(1, 1, 1, held[button.name] and ON_ALPHA or OFF_ALPHA)
		render2d.PushBorderRadius(radius, radius, radius, radius)
		render2d.DrawRect(x - radius, y - radius, radius * 2, radius * 2)
		render2d.PopBorderRadius()
		render2d.DrawText{
			text = label,
			x = x,
			y = y,
			size = math.max(math.floor(radius * 0.6), 8),
			foreground_color = white,
			align_x = 0.5,
			align_y = 0.5,
			alpha = 0.9,
		}
	end
end)
