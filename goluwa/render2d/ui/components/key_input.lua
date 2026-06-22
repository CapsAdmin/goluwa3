local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local META = objects.CreateTemplate("key_input")

function META:KeyInput(key, press)
	return self.Owner:CallLocalEvent("OnKeyInput", key, press)
end

function META:CharInput(char)
	return self.Owner:CallLocalEvent("OnCharInput", char)
end

function META:OnFirstCreated()
	event.AddListener(
		"KeyInput",
		"ecs_key_input_system",
		function(key, press)
			local focused = objects.GetFocusedObject()

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
			local focused = objects.GetFocusedObject()

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
