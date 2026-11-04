local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local killfeed = import("lua/killfeed.lua")
local third_person = import("lua/third_person.lua")
local MARGIN = 20
local PADDING = 10
local ROW_HEIGHT = 28
local ROW_GAP = 4
local FONT_SIZE = 16
local FADE_TIME = 0.5
local parts_scratch = {}

event.AddListener("DrawHUD", "killfeed_hud", function()
	if third_person.IsHudHidden() then return end

	local now = system.GetUnscaledElapsedTime()
	local entries = killfeed.Entries

	while entries[1] and now - entries[1].time > killfeed.Duration + FADE_TIME do
		table.remove(entries, 1)
	end

	local screen_w = render2d.GetSize()
	local active = theme.active
	local TEXT = active:GetColor("text_on_dark")
	local KILLER = active:GetColor("neutral")
	local VICTIM = active:GetColor("negative")
	local font, weight = active:GetTextStyle("body")
	local y = MARGIN

	for _, entry in ipairs(entries) do
		local alpha = math.min((entry.time + killfeed.Duration + FADE_TIME - now) / FADE_TIME, 1)
		local parts = parts_scratch

		if entry.killer == "" then
			parts[1], parts[2], parts[3], parts[4], parts[5], parts[6] = entry.victim, VICTIM, " died", TEXT, nil, nil
		else
			parts[1], parts[2], parts[3], parts[4], parts[5], parts[6] = entry.killer, KILLER, " killed ", TEXT, entry.victim, VICTIM
		end

		local width = PADDING * 2

		for i = 1, 5, 2 do
			if parts[i] then
				width = width + render2d.GetTextSize(parts[i], font, FONT_SIZE, weight)
			end
		end

		local x = screen_w - MARGIN - width
		active:DrawHudPanel(x, y, width, ROW_HEIGHT, {alpha = alpha})
		x = x + PADDING

		for i = 1, 5, 2 do
			if parts[i] then
				render2d.DrawText{
					text = parts[i],
					font = font,
					weight = weight,
					x = x,
					y = y + (ROW_HEIGHT - FONT_SIZE) / 2 - 2,
					size = FONT_SIZE,
					foreground_color = parts[i + 1],
					alpha = alpha,
				}
				x = x + render2d.GetTextSize(parts[i], font, FONT_SIZE, weight)
			end
		end

		y = y + ROW_HEIGHT + ROW_GAP
	end
end)
