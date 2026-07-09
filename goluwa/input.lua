local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local codec = import("goluwa/codec.lua")
local input = library()
input.PressedThreshold = 0.2

function input.SetupAccessorFunctions(tbl, name, up_id, down_id, on_self)
	up_id = up_id or name .. "_up_time"
	down_id = down_id or name .. "_down_time"
	input[down_id] = {}
	input[up_id] = {}
	local is_down = function(self, key)
		return self[down_id][key]
	end
	local get_up_time = function(self, key)
		return system.GetTime() - (self[up_id][key] or 0)
	end
	local was_pressed = function(self, key)
		return system.GetTime() - (self[down_id][key] or 0) < input.PressedThreshold
	end
	local get_down_time = function(self, key)
		return system.GetTime() - (self[down_id][key] or 0)
	end

	if on_self then
		tbl["Is" .. name .. "Down"] = is_down
		tbl["Get" .. name .. "UpTime"] = get_up_time
		tbl["Was" .. name .. "Pressed"] = was_pressed
		tbl["Get" .. name .. "DownTime"] = get_down_time
	else
		tbl["Is" .. name .. "Down"] = function(key)
			return is_down(input, key)
		end
		tbl["Get" .. name .. "UpTime"] = function(key)
			return get_up_time(input, key)
		end
		tbl["Was" .. name .. "Pressed"] = function(key)
			return was_pressed(input, key)
		end
		tbl["Get" .. name .. "DownTime"] = function(key)
			return get_down_time(input, key)
		end
	end
end

function input.CallOnTable(tbl, name, key, press, up_id, down_id)
	if not tbl then return end

	if not key then return end

	up_id = up_id or name .. "_up_time"
	down_id = down_id or name .. "_down_time"
	tbl[up_id] = tbl[up_id] or {}
	tbl[down_id] = tbl[down_id] or {}

	if key then
		if type(key) == "string" and #key == 1 then
			local byte = string.byte(key)

			if byte >= 65 and byte <= 90 then -- Uppercase letters
				key = string.char(byte + 32)
			end
		end

		if press and not tbl[down_id][key] then
			if input.debug then print(name, "key", key, "pressed") end

			tbl[up_id][key] = nil
			tbl[down_id][key] = system.GetTime()
		elseif not press and tbl[down_id][key] and not tbl[up_id][key] then
			if input.debug then print(name, "key", key, "released") end

			tbl[up_id][key] = system.GetTime()
			tbl[down_id][key] = nil
		end
	end
end

function input.SetupInputEvent(name)
	local down_id = name .. "_down_time"
	local up_id = name .. "_up_time"
	input[down_id] = {}
	input[up_id] = {}
	input.SetupAccessorFunctions(input, name)
	return function(key, press)
		return input.CallOnTable(input, name, key, press, up_id, down_id)
	end
end

function input.GetDownKeys(name)
	local down = input[name .. "_down_time"] or {}
	local keys = {}

	for key in pairs(down) do
		keys[#keys + 1] = key
	end

	return keys
end

function input.ReleaseAll(name, callback)
	for _, key in ipairs(input.GetDownKeys(name)) do
		input.CallOnTable(input, name, key, false)

		if callback then callback(key, false) end
	end
end

do
	input.binds = {}

	function input.Bind(key, cmd, callback, important)
		codec.StoreInFile("luadata", "data/input.txt", key, cmd)
		local modifiers = key:split("+")
		list.remove(modifiers, 1)
		input.binds[key .. cmd] = {
			key = key:sub(1, 1) == "+" and key:sub(2) or key,
			trigger = key:match("^%-(.-)%+") or key:match("^(.-)%+") or key,
			cmd = cmd,
			modifiers = modifiers,
			trigger_on_release = cmd:sub(1, 1) == "-",
			important = important,
		}

		if callback then commands.Add(cmd .. "=nil", callback) end
	end

	function input.Unbind(key)
		for k, v in pairs(input.binds) do
			if k:starts_with(key) then
				input.binds[k] = nil
				commands.Remove(v.cmd)

				break
			end
		end
	end

	function input.Initialize()
		input.binds = codec.ReadFile("luadata", "data/input.txt") or {}
	end

	input.disable_focus = 0

	do
		local last_focus_frame = 0

		function input.PushDisableFocus()
			local frame = system.GetFrameNumber()

			if last_focus_frame ~= frame then
				input.disable_focus = input.disable_focus + 1
				last_focus_frame = frame
			end
		end

		local last_unfocus_frame = 0

		function input.PopDisableFocus()
			local frame = system.GetFrameNumber()

			if last_unfocus_frame ~= frame then
				input.disable_focus = math.max(input.disable_focus - 1, 0)
				last_unfocus_frame = frame
			end
		end
	end

	function input.Call(key, press)
		for _, data in pairs(input.binds) do
			if data.important or input.disable_focus == 0 then
				if data.trigger == key then
					if (press and not data.trigger_on_release) or (not press and data.trigger_on_release) then
						local ok = true

						for _, v in ipairs(data.modifiers) do
							if not input.IsKeyDown(v) then
								ok = false

								break
							end
						end

						if ok then
							commands.RunString(data.cmd)
							return false
						end
					end
				end
			end
		end
	end

	event.AddListener(
		"KeyInput",
		"keybind",
		input.Call,
		{on_error = system.OnError, priority = math.huge}
	)

	commands.Add("bind=string,string_rest", function(key, str)
		input.Bind(key, str)
	end)
end

return input
