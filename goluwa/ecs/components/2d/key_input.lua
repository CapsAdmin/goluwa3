local prototype = require("prototype")
local event = require("event")
local META = prototype.CreateTemplate("key_input")

function META:KeyInput(key, press)
	return self.Owner:CallLocalListeners("OnKeyInput", key, press)
end

function META:CharInput(char)
	return self.Owner:CallLocalListeners("OnCharInput", char)
end

function META:OnFirstCreated()
	event.AddListener(
		"KeyInput",
		"ecs_key_input_system",
		function(key, press)
			local focused = prototype.GetFocusedObject()

			if focused and focused:IsValid() and focused.key_input then
				if focused.key_input:KeyInput(key, press) then return true end
			end
		end,
		{priority = 100}
	)

	event.AddListener(
		"CharInput",
		"ecs_key_input_system",
		function(char)
			local focused = prototype.GetFocusedObject()

			if focused and focused:IsValid() and focused.key_input then
				if focused.key_input:CharInput(char) then return true end
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
