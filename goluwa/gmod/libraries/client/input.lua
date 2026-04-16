local gine = ... or _G.gine
local system = import("goluwa/system.lua")
local host_input = import("goluwa/input.lua")
local window = import("goluwa/window.lua")
local vfs = import("goluwa/vfs.lua")
local event = import("goluwa/event.lua")

do
	local translate_key = {}

	local function find_enums(name)
		for k, v in pairs(gine.env) do
			if k:starts_with(name .. "_") then
				translate_key[k:match(name .. "_(.+)"):lower()] = v
			end
		end
	end

	find_enums("KEY")
	find_enums("MOUSE")
	find_enums("BUTTON")
	find_enums("JOYSTICK")
	translate_key.left = gine.env.KEY_LEFT
	translate_key.right = gine.env.KEY_RIGHT
	translate_key.left_shift = gine.env.KEY_LSHIFT
	translate_key.lshift = nil
	translate_key.right_shift = gine.env.KEY_RSHIFT
	translate_key.rshift = nil
	translate_key.lcontrol = nil
	translate_key.left_control = gine.env.KEY_LCONTROL
	translate_key.right_control = gine.env.KEY_RCONTROL
	translate_key.rcontrol = nil
	translate_key.left_alt = gine.env.KEY_LALT
	translate_key.lalt = nil
	translate_key.right_alt = gine.env.KEY_RALT
	translate_key.ralt = nil
	local translate_key_rev = {}

	for k, v in pairs(translate_key) do
		translate_key_rev[v] = k
	end

	gine.translate_key = translate_key
	gine.translate_key_rev = translate_key_rev

	function gine.GetKeyCode(key, rev)
		if rev then
			if translate_key_rev[key] then
				--if gine.print_keys then llog("key reverse: ", key, " >> ", translate_key_rev[key]) end
				return translate_key_rev[key]
			else
				--logf("key %q could not be translated!\n", key)
				return translate_key_rev.KEY_P -- dunno
			end
		else
			if translate_key[key] then
				if gine.print_keys then llog("key: ", key, " >> ", translate_key[key]) end

				return translate_key[key]
			else
				--logf("key %q could not be translated!\n", key)
				return translate_key.p -- dunno
			end
		end
	end

	local translate_mouse = {
		button_1 = gine.env.MOUSE_LEFT,
		button_2 = gine.env.MOUSE_RIGHT,
		button_3 = gine.env.MOUSE_MIDDLE,
		button_4 = gine.env.MOUSE_4,
		button_5 = gine.env.MOUSE_5,
		mwheel_up = gine.env.MOUSE_WHEEL_UP,
		mwheel_down = gine.env.MOUSE_WHEEL_DOWN,
	}
	local translate_mouse_rev = {}

	for k, v in pairs(translate_mouse) do
		translate_mouse_rev[v] = k
	end

	gine.translate_mouse = translate_mouse
	gine.translate_mouse_rev = translate_mouse_rev

	function gine.GetMouseCode(button, rev)
		if rev then
			if translate_mouse_rev[button] then
				return translate_mouse_rev[button]
			else
				--llog("mouse button %q could not be translated!\n", button)
				return translate_mouse.MOUSE_5
			end
		else
			if translate_mouse[button] then
				return translate_mouse[button]
			else
				--llog("mouse button %q could not be translated!\n", button)
				return translate_mouse.button_5
			end
		end
	end
end

do
	gine.bindings = gine.bindings or {}
	gine.default_bindings = gine.default_bindings or {}
	gine.default_bindings_rev = gine.default_bindings_rev or {}

	local function translate_binding_name(name)
		if type(name) ~= "string" then return nil end

		local upper = name:upper()

		if #upper == 1 then
			if upper:match("%d") or upper:match("%a") then
				return gine.env["KEY_" .. upper]
			end

			if upper == "`" then return gine.env.KEY_BACKQUOTE end
		end

		local aliases = {
			UPARROW = "KEY_UP",
			DOWNARROW = "KEY_DOWN",
			LEFTARROW = "KEY_LEFT",
			RIGHTARROW = "KEY_RIGHT",
			SPACE = "KEY_SPACE",
			CTRL = "KEY_LCONTROL",
			SHIFT = "KEY_LSHIFT",
			ALT = "KEY_LALT",
			ENTER = "KEY_ENTER",
			ESCAPE = "KEY_ESCAPE",
			TAB = "KEY_TAB",
			PAUSE = "KEY_PAUSE",
			F1 = "KEY_F1",
			F2 = "KEY_F2",
			F3 = "KEY_F3",
			F4 = "KEY_F4",
			F5 = "KEY_F5",
			F6 = "KEY_F6",
			F7 = "KEY_F7",
			F8 = "KEY_F8",
			F9 = "KEY_F9",
			F10 = "KEY_F10",
			F11 = "KEY_F11",
			F12 = "KEY_F12",
			MOUSE1 = "MOUSE_LEFT",
			MOUSE2 = "MOUSE_RIGHT",
			MOUSE3 = "MOUSE_MIDDLE",
			MOUSE4 = "MOUSE_4",
			MOUSE5 = "MOUSE_5",
			MWHEELUP = "MOUSE_WHEEL_UP",
			MWHEELDOWN = "MOUSE_WHEEL_DOWN",
		}

		return gine.env[aliases[upper] or ""]
	end

	local function add_default_binding(key_name, cmd)
		local code = translate_binding_name(key_name)
		if not code then return end

		gine.default_bindings[code] = cmd
		gine.default_bindings_rev[cmd] = gine.default_bindings_rev[cmd] or key_name
	end

	local default_bind_path = "goluwa/gmod/src/garrysmod/garrysmod/scripts/kb_def.lst"
	local default_bind_data = vfs.Read(default_bind_path)

	if default_bind_data then
		for key_name, cmd in default_bind_data:gmatch('"([^"]+)"%s+"([^"]+)"') do
			add_default_binding(key_name, cmd)
		end
	end

	function gine.SetupKeyBind(key, cmd, on_press, on_release)
		if host_input.Unbind then host_input.Unbind(key) end
		local p = cmd:match("^(%p)")

		if p then key = p .. key end

		gine.bindings[key] = {
			cmd = cmd,
			p = p,
			on_press = on_press,
			on_release = on_release or p and on_press,
		}
	end

	gine.AddEvent("KeyInput", function(key, press)
		local focus_disable = (gine.env.input and gine.env.input.disable_focus) or 0
		if focus_disable > 0 then return end

		local ply = gine.env.LocalPlayer()

		if press then
			gine.env.gamemode.Call("KeyPress", ply, gine.GetKeyCode(key))
		else
			gine.env.gamemode.Call("KeyRelease", ply, gine.GetKeyCode(key))
		end

		local info = gine.bindings[key] or
			(
				press and
				gine.bindings["+" .. key] or
				gine.bindings["-" .. key]
			)

		if info then
			if gine.env.gamemode.Call("PlayerBindPress", ply, info.cmd, press) ~= true then
				if press then
					if info.on_press and (not info.p or info.p == "+") then
						info.on_press()
					end
				else
					if info.on_release and (not info.p or info.p == "-") then
						info.on_release()
					end
				end

				gine.env.RunConsoleCommand(info.cmd)
			end

			return false
		end
	end)

	gine.SetupKeyBind("q", "+menu")
	gine.SetupKeyBind("q", "-menu")
	gine.SetupKeyBind("c", "+menu_context")
	gine.SetupKeyBind("c", "-menu_context")

	gine.SetupKeyBind("x", "+voicerecord", function()
		gine.env.gamemode.Call("PlayerStartVoice", gine.env.LocalPlayer())
	end)

	gine.SetupKeyBind("x", "-voicerecord", function()
		gine.env.gamemode.Call("PlayerEndVoice", gine.env.LocalPlayer())
	end)
	gine.SetupKeyBind("t", "messagemode", function()
		chat.Open()
	end)

	gine.SetupKeyBind("u", "messagemode2", function()
		chat.Open()
	end)

	gine.SetupKeyBind("tab", "+score", function()
		gine.env.gamemode.Call("ScoreboardShow")
	end)

	gine.SetupKeyBind("tab", "-score", function()
		gine.env.gamemode.Call("ScoreboardHide")
	end)
end

local input = gine.env.input
local lib = host_input
local function get_window()
	return system.GetCurrentWindow()
end

local function is_mouse_code(code)
	return gine.translate_mouse_rev and gine.translate_mouse_rev[code] ~= nil
end

local function normalize_binding_key(key)
	if type(key) ~= "string" then return nil end

	key = key:gsub("^[%+%-]", "")

	local aliases = {
		button_1 = "mouse1",
		button_2 = "mouse2",
		button_3 = "mouse3",
		button_4 = "mouse4",
		button_5 = "mouse5",
		mwheel_up = "mwheelup",
		mwheel_down = "mwheeldown",
	}

	return aliases[key] or key
end

local function get_runtime_binding_for_code(code)
	if type(code) ~= "number" then return nil end

	local key = is_mouse_code(code) and gine.GetMouseCode(code, true) or gine.GetKeyCode(code, true)

	if not key then return nil end

	local info = gine.bindings[key] or gine.bindings["+" .. key] or gine.bindings["-" .. key]
	return info and info.cmd or nil
end

function input.LookupBinding(cmd)
	for k, v in pairs(gine.bindings) do
		if v.cmd == cmd then return normalize_binding_key(k) end
	end

	return gine.default_bindings_rev[cmd]
end

function input.LookupKeyBinding(code)
	if type(code) ~= "number" then return nil end

	return get_runtime_binding_for_code(code) or gine.default_bindings[code]
end

function input.SetCursorPos(x, y)
	get_window():SetMousePosition(Vec2(x, y))
end

function input.GetCursorPos()
	return get_window():GetMousePosition():Unpack()
end

function input.IsShiftDown()
	return lib.IsKeyDown("left_shift") or lib.IsKeyDown("right_shift")
end

function input.IsControlDown()
	return lib.IsKeyDown("left_control") or lib.IsKeyDown("right_control")
end

function input.IsMouseDown(code)
	if not lib.IsMouseDown and lib.SetupAccessorFunctions then
		lib.Mouse_down_time = lib.Mouse_down_time or {}
		lib.Mouse_up_time = lib.Mouse_up_time or {}
		lib.SetupAccessorFunctions(lib, "Mouse")
	end

	if not lib.IsMouseDown then return false end

	return lib.IsMouseDown(gine.GetMouseCode(code, true))
end

function input.IsKeyDown(code)
	return lib.IsKeyDown(gine.GetKeyCode(code, true))
end

function input.IsButtonDown(code)
	if is_mouse_code(code) then return input.IsMouseDown(code) end

	return input.IsKeyDown(code)
end

function input.GetKeyName(code)
	return gine.GetKeyCode(code, true)
end

do
	local last_key
	local b = false

	function input.StartKeyTrapping()
		b = true
		last_key = nil

		event.AddListener("KeyInput", "gine_keytrap", function(key, press)
			last_key = gine.GetKeyCode(key)
		end)

		event.AddListener("MouseInput", "gine_keytrap", function(key, press)
			last_key = gine.GetMouseCode(key)
		end)
	end

	function input.IsKeyTrapping()
		return b
	end

	function input.CheckKeyTrapping()
		return last_key
	end

	function input.StopKeyTrapping()
		b = false
		event.RemoveListener("KeyInput", "gine_keytrap")
		event.RemoveListener("MouseInput", "gine_keytrap")
	end
end