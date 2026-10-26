local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local third_person = import("lua/third_person.lua")
local CELL_WIDTH = 124
local CELL_HEIGHT = 40
local CELL_GAP = 6
local BOTTOM_MARGIN = 28
local VISIBLE_TIME = 2.5
local FADE_TIME = 0.5
local TEXT = Color(0.88, 0.9, 0.94, 1)
local RIGHT = Color(1, 0.85, 0.4, 1)
local LEFT = Color(0.45, 0.75, 1, 1)
local MOUNT = Color(0.75, 0.95, 0.7, 1)
local last_right, last_left, last_chest
local last_change = -math.huge

local function draw_bar(color, x, y, w, alpha)
	render2d.SetColor(color.r, color.g, color.b, alpha)
	render2d.DrawRoundedRect(x, y + CELL_HEIGHT - 3, w, 3, 1.5)
end

event.AddListener("DrawHUD", "weapon_hud", function()
	local rig = _G.PLAYER_RIG

	if
		not (
			rig and
			rig:IsValid()
		) or
		third_person.IsDefaultHudReplaced(rig) or
		third_person.IsHudHidden()
	then
		return
	end

	local holder = rig.weapon_holder
	local right = holder:GetWeapon("right")
	local left = holder:GetWeapon("left")
	local chest = holder:GetWeapon("chest")
	local now = system.GetElapsedTime()

	if right ~= last_right or left ~= last_left or chest ~= last_chest then
		last_right, last_left, last_chest = right, left, chest
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
		local in_right = weapon == right
		local in_left = weapon == left
		local mounted = info:GetMount() ~= "hand"
		local equipped = info:IsEquipped()
		local tag
		render2d.SetColor(0, 0, 0, (equipped and 0.8 or 0.55) * alpha)
		render2d.DrawRoundedRect(x, y, CELL_WIDTH, CELL_HEIGHT, 6)

		if in_right and in_left then
			draw_bar(RIGHT, x, y, CELL_WIDTH, alpha)
			tag = "L R"
		elseif in_right then
			draw_bar(RIGHT, x + CELL_WIDTH / 2, y, CELL_WIDTH / 2, alpha)
			tag = "R"
		elseif in_left then
			draw_bar(LEFT, x, y, CELL_WIDTH / 2, alpha)
			tag = "L"
		elseif equipped then
			draw_bar(MOUNT, x, y, CELL_WIDTH, alpha)
		end

		render2d.DrawText{
			text = (mounted and "F" or math.floor(info:GetSlot())) .. "  " .. info:GetDisplayName(),
			x = x + 12,
			y = y + 12,
			size = 16,
			foreground_color = TEXT,
			alpha = (equipped and 1 or 0.6) * alpha,
		}

		if tag then
			render2d.DrawText{
				text = tag,
				x = x + CELL_WIDTH - 10,
				y = y + 12,
				size = 14,
				foreground_color = in_right and RIGHT or LEFT,
				alpha = alpha,
				align_x = 1,
			}
		end

		x = x + CELL_WIDTH + CELL_GAP
	end
end)
