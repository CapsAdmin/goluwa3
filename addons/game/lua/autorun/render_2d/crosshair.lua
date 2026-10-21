local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local RADIUS = 2.5

event.AddListener("DrawHUD", "crosshair", function()
	local rig = _G.PLAYER_RIG

	if not (rig and rig:IsValid()) then return end

	local w, h = render2d.GetSize()
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.6)
	render2d.DrawRoundedRect(w / 2 - RADIUS - 1, h / 2 - RADIUS - 1, RADIUS * 2 + 2, RADIUS * 2 + 2, RADIUS + 1)
	render2d.SetColor(1, 1, 1, 0.9)
	render2d.DrawRoundedRect(w / 2 - RADIUS, h / 2 - RADIUS, RADIUS * 2, RADIUS * 2, RADIUS)
end)
