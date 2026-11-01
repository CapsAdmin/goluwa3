local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local third_person = import("lua/third_person.lua")
local CELL_WIDTH = 124
local CELL_HEIGHT = 40
local CELL_GAP = 6
local BOTTOM_MARGIN = 28
local VISIBLE_TIME = 2.5
local FADE_TIME = 0.5
local last_right, last_left, last_chest
local last_change = -math.huge

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

	local active = theme.active
	local text_color = active:GetColor("text_on_dark")
	local right_color = active:GetColor("neutral")
	local left_color = active:GetColor("primary")
	local mount_color = active:GetColor("positive")
	local font, weight = active:GetTextStyle("body")
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
		local state = {alpha = alpha, opacity = equipped and 0.8 or 0.55, accent_side = "bottom"}

		if in_right and in_left then
			state.accent = right_color
			tag = "L R"
		elseif in_right then
			state.accent, state.accent_from = right_color, 0.5
			tag = "R"
		elseif in_left then
			state.accent, state.accent_to = left_color, 0.5
			tag = "L"
		elseif equipped then
			state.accent = mount_color
		end

		active:DrawHudPanel(x, y, CELL_WIDTH, CELL_HEIGHT, state)

		render2d.DrawText{
			text = (mounted and "F" or math.floor(info:GetSlot())) .. "  " .. info:GetDisplayName(),
			x = x + 12,
			y = y + 12,
			size = 16,
			font = font,
			weight = weight,
			foreground_color = text_color,
			alpha = (equipped and 1 or 0.6) * alpha,
		}

		if tag then
			render2d.DrawText{
				text = tag,
				x = x + CELL_WIDTH - 10,
				y = y + 12,
				size = 14,
				font = font,
				weight = weight,
				foreground_color = in_right and right_color or left_color,
				alpha = alpha,
				align_x = 1,
			}
		end

		x = x + CELL_WIDTH + CELL_GAP
	end
end)
