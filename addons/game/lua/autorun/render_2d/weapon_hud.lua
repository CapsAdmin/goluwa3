local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local CELL_WIDTH = 110
local CELL_HEIGHT = 40
local CELL_GAP = 6
local BOTTOM_MARGIN = 28
local VISIBLE_TIME = 2.5
local FADE_TIME = 0.5
local TEXT = Color(0.88, 0.9, 0.94, 1)
local last_slot = 0
local last_change = -math.huge

event.AddListener("Draw2D", "weapon_hud", function()
	local rig = _G.PLAYER_RIG

	if not (rig and rig:IsValid()) then return end

	local holder = rig.weapon_holder
	local slot = holder:GetActiveSlot()
	local now = system.GetElapsedTime()

	if slot ~= last_slot then
		last_slot = slot
		last_change = now
	end

	local alpha = math.min((last_change + VISIBLE_TIME + FADE_TIME - now) / FADE_TIME, 1)

	if alpha <= 0 then return end

	local weapons = holder:GetWeapons()
	local screen_w, screen_h = render2d.GetSize()
	local total = #weapons * CELL_WIDTH + (#weapons - 1) * CELL_GAP
	local x = (screen_w - total) / 2
	local y = screen_h - BOTTOM_MARGIN - CELL_HEIGHT
	render2d.SetTexture(nil)

	for _, weapon in ipairs(weapons) do
		local info = weapon.weapon
		local active = info:IsActive()
		render2d.SetColor(0, 0, 0, (active and 0.8 or 0.55) * alpha)
		render2d.DrawRoundedRect(x, y, CELL_WIDTH, CELL_HEIGHT, 6)

		if active then
			render2d.SetColor(1, 0.85, 0.4, alpha)
			render2d.DrawRoundedRect(x, y + CELL_HEIGHT - 3, CELL_WIDTH, 3, 1.5)
		end

		render2d.DrawText{
			text = info:GetSlot() .. "  " .. info:GetDisplayName(),
			x = x + 12,
			y = y + 12,
			size = 16,
			foreground_color = TEXT,
			alpha = (active and 1 or 0.6) * alpha,
		}
		x = x + CELL_WIDTH + CELL_GAP
	end
end)
