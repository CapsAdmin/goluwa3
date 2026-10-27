local camera_modes = {}
local list = {}

-- a mode with a higher Priority wins when several are enabled
function camera_modes.Register(mode)
	local priority = mode.Priority or 0
	local index = #list + 1

	for i = 1, #list do
		if priority > (list[i].Priority or 0) then
			index = i

			break
		end
	end

	table.insert(list, index, mode)
end

function camera_modes.GetActive()
	for i = 1, #list do
		if list[i].IsEnabled() then return list[i] end
	end
end

function camera_modes.IsFirstPerson(third_person_enabled)
	local mode = camera_modes.GetActive()

	if mode then return mode.IsFirstPerson() end

	return not third_person_enabled
end

function camera_modes.Disable()
	for i = 1, #list do
		list[i].Disable()
	end
end

function camera_modes.AdjustCommand(cmd)
	for i = 1, #list do
		list[i].AdjustCommand(cmd)
	end
end

function camera_modes.ApplyMovement(player_input, dt, attacking)
	for i = 1, #list do
		list[i].ApplyMovement(player_input, dt, attacking)
	end
end

return camera_modes
