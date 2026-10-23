local camera_modes = {}
local list = {}

function camera_modes.Register(mode)
	list[#list + 1] = mode
end

function camera_modes.GetActive()
	for i = 1, #list do
		if list[i].IsEnabled() then return list[i] end
	end
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
