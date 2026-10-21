local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local META = objects.CreateTemplate("key_input")

local suppressed = {}
local last_focused

local function get_focused()
	local focused = objects.GetFocusedObject()

	if focused ~= last_focused then
		last_focused = focused
		suppressed = {}

		for _, key in ipairs(input.GetDownKeys("Key")) do
			suppressed[key] = true
		end
	end

	if focused and focused:IsValid() and focused.key_input then return focused end
end

function META:KeyInput(key, press)
	return self.Owner:CallLocalEvent("OnKeyInput", key, press)
end

function META:KeyInputRepeat(key)
	return self.Owner:CallLocalEvent("OnKeyInputRepeat", key)
end

function META:CharInput(char)
	return self.Owner:CallLocalEvent("OnCharInput", char)
end

function META:OnFirstCreated()
	event.AddListener(
		"KeyInput",
		"ecs_key_input_system",
		function(key, press)
			local focused = get_focused()

			if not press then suppressed[key] = nil end

			if focused and not suppressed[key] then
				return focused.key_input:KeyInput(key, press)
			end
		end,
		{priority = 100}
	)

	event.AddListener(
		"KeyInputRepeat",
		"ecs_key_input_system",
		function(key)
			local focused = get_focused()

			if focused and not suppressed[key] then
				return focused.key_input:KeyInputRepeat(key)
			end
		end,
		{priority = 100}
	)

	event.AddListener(
		"CharInput",
		"ecs_key_input_system",
		function(char)
			local focused = get_focused()

			if focused and not suppressed[char:lower()] then
				return focused.key_input:CharInput(char)
			end
		end,
		{priority = 100}
	)
end

function META:OnLastRemoved()
	event.RemoveListener("KeyInput", "ecs_key_input_system")
	event.RemoveListener("CharInput", "ecs_key_input_system")
end

return META:Register()
