local prototype = require("prototype")
local event = require("event")
local META = prototype.CreateTemplate("tui_key_input")

local function focused_ki()
	local focused = prototype.GetFocusedObject()

	if focused and focused:IsValid() and focused.tui_key_input then
		return focused.tui_key_input
	end
end

function META:OnFirstCreated()
	event.AddListener(
		"TerminalCharInput",
		"tui_key_input",
		function(char)
			local ki = focused_ki()

			if ki then ki:CharInput(char) end
		end,
		{priority = 100}
	)

	event.AddListener(
		"TerminalKeyInput",
		"tui_key_input",
		function(key, press, modifiers)
			local ki = focused_ki()

			if ki then ki:KeyInput(key, press, modifiers) end
		end,
		{priority = 100}
	)
end

function META:OnLastRemoved()
	event.RemoveListener("TerminalCharInput", "tui_key_input")
	event.RemoveListener("TerminalKeyInput", "tui_key_input")
end

function META:KeyInput(key, press, modifiers)
	return self.Owner:CallLocalEvent("OnKeyInput", key, press, modifiers)
end

function META:CharInput(char)
	return self.Owner:CallLocalEvent("OnCharInput", char)
end

function META:Initialize()
	self.Owner:EnsureComponent("tui_element")
end

return META:Register()
