local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Color = import("goluwa/structs/color.lua")
local third_person = import("lua/third_person.lua")
local TEXT_SIZE = 26
local HINT_SIZE = 16
local TEXT = Color(1, 1, 1, 1)
local HINT = Color(0.8, 0.8, 0.8, 1)
local HINTS = {
	car = "W/S drive and brake  A/D steer  SPACE handbrake  E exit",
	bike = "W/S drive and brake  A/D steer  SPACE handbrake  E exit",
	boat = "W/S throttle  A/D steer  E exit",
	plane = "SHIFT/CTRL throttle  W/S pitch  A/D roll  SPACE brakes  E exit",
}

event.AddListener("DrawHUD", "vehicle_hud", function()
	local rig = _G.PLAYER_RIG

	if not (rig and rig:IsValid()) or third_person.IsHudHidden() then return end

	local seat = rig.character_pose:GetSeat()

	if not (seat:IsValid() and seat.vehicle) then return end

	local vehicle = seat.vehicle
	local kind = vehicle.def.Type
	local text = string.format("%d km/h", math.abs(vehicle:GetForwardSpeed()) * 3.6)

	if kind == "plane" then
		text = string.format(
			"%s   throttle %d%%   altitude %d m",
			text,
			vehicle:GetThrottle() * 100,
			seat.transform:GetPosition().y
		)
	end

	local w, h = render2d.GetSize()
	local text_w, text_h = render2d.GetTextSize(text, nil, TEXT_SIZE)
	local hint = HINTS[kind]
	local hint_w, hint_h = render2d.GetTextSize(hint, nil, HINT_SIZE)
	local box_w = math.max(text_w, hint_w) + 40
	local box_h = text_h + hint_h + 28
	local x = (w - box_w) / 2
	local y = h - box_h - 40
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.5)
	render2d.DrawRoundedRect(x, y, box_w, box_h, 6)
	render2d.DrawText{
		text = text,
		x = (w - text_w) / 2,
		y = y + 10,
		size = TEXT_SIZE,
		foreground_color = TEXT,
	}
	render2d.DrawText{
		text = hint,
		x = (w - hint_w) / 2,
		y = y + text_h + 18,
		size = HINT_SIZE,
		foreground_color = HINT,
	}
end)
