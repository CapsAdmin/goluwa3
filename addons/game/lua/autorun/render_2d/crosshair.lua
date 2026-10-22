local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local third_person = import("lua/third_person.lua")
local battlecam = import("lua/battlecam.lua")
local RADIUS = 2.5
local settings = third_person.Settings

event.AddListener("DrawHUD", "crosshair", function()
	local rig = _G.PLAYER_RIG

	if not (rig and rig:IsValid()) then return end

	if battlecam.IsEnabled() then return end

	local w, h = render2d.GetSize()
	local x, y = w / 2, h / 2
	local red = 1

	if settings.enabled then
		local bar = third_person.GetBlackBarHeight()

		if bar > 0 then
			render2d.SetTexture(nil)
			render2d.SetColor(0, 0, 0, 1)
			render2d.DrawRect(0, 0, w, bar)
			render2d.DrawRect(0, h - bar, w, bar)
		end

		if not settings.crosshair then return end

		local point, blocked = third_person.GetCrosshairPoint()
		local screen = render3d.GetMainCamera():WorldPositionToScreen(point, w, h)

		if not screen then return end

		x, y = screen.x, screen.y

		if blocked then red = 0.4 end
	end

	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.6)
	render2d.DrawRoundedRect(x - RADIUS - 1, y - RADIUS - 1, RADIUS * 2 + 2, RADIUS * 2 + 2, RADIUS + 1)
	render2d.SetColor(1, red, red, 0.9)
	render2d.DrawRoundedRect(x - RADIUS, y - RADIUS, RADIUS * 2, RADIUS * 2, RADIUS)
end)
