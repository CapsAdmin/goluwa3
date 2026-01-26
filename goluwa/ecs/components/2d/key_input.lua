local prototype = require("prototype")
local event = require("event")
local ecs = require("ecs.ecs")
local META = prototype.CreateTemplate("key_input_2d")
META.ComponentName = "key_input_2d"

function META:OnPreKeyInput(key, press) end

function META:OnKeyInput(key, press) end

function META:OnPostKeyInput(key, press) end

function META:OnCharInput(char) end

function META:KeyInput(key, press)
	local b

	if self.OnPreKeyInput and self:OnPreKeyInput(key, press) ~= false then
		if self.OnKeyInput then b = self:OnKeyInput(key, press) end

		if self.OnPostKeyInput then self:OnPostKeyInput(key, press) end
	end

	return b
end

function META:CharInput(char)
	if self.OnCharInput then return self:OnCharInput(char) end
end

local key_input = library()
key_input.Component = META:Register()

function key_input.KeyInput(key, press)
	local focused = ecs.GetFocusedEntity()

	if focused and focused:IsValid() then
		for _, comp in pairs(focused.ComponentsHash) do
			if comp.KeyInput then
				if comp:KeyInput(key, press) then return true end
			end
		end

		if focused.OnKeyInput then
			if focused:OnKeyInput(key, press) then return true end
		end
	end
end

function key_input.CharInput(char)
	local focused = ecs.GetFocusedEntity()

	if focused and focused:IsValid() then
		for _, comp in pairs(focused.ComponentsHash) do
			if comp.CharInput then if comp:CharInput(char) then return true end end
		end

		if focused.OnCharInput then
			if focused:OnCharInput(char) then return true end
		end
	end
end

function key_input.StartSystem()
	event.AddListener("KeyInput", "ecs_key_input_system", key_input.KeyInput, {priority = 100})
	event.AddListener("CharInput", "ecs_key_input_system", key_input.CharInput, {priority = 100})
end

function key_input.StopSystem()
	event.RemoveListener("KeyInput", "ecs_key_input_system")
	event.RemoveListener("CharInput", "ecs_key_input_system")
end

return key_input
