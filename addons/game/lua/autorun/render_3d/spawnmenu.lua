local input = import("goluwa/input.lua")
local spawnmenu = import("lua/spawnmenu.lua")
input.Bind("q", "+spawnmenu", spawnmenu.Hold)
input.Bind("q", "-spawnmenu", spawnmenu.Release)
local game_history = import("lua/game_history.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local history = game_history.history
local NOTICE_TIME = 2
local NOTICE_FADE = 0.4
local notice = {text = "", time = -math.huge}

local function notify(prefix, entry)
	notice.text = prefix .. entry.Name
	notice.time = system.GetElapsedTime()
end

event.AddListener("KeyInput", "game_history", function(key, press)
	if not press or key ~= "z" or spawnmenu.IsEditing() then return end

	if input.IsControlDown() and input.IsShiftDown() then
		local entry = history:GetEntries()[history:GetIndex() + 1]

		if history:Redo() then notify("Redone ", entry) end

		return true
	end

	if not input.IsControlDown() and not input.IsShiftDown() then
		local entry = history:GetEntries()[history:GetIndex()]

		if history:Undo() then notify("Undone ", entry) end

		return true
	end
end)

event.AddListener("DrawHUD", "game_history", function()
	local age = system.GetElapsedTime() - notice.time

	if age > NOTICE_TIME then return end

	local alpha = math.min((NOTICE_TIME - age) / NOTICE_FADE, 1)
	local font = theme.active:GetFont("body", "M")
	local text_w, text_h = font:GetTextSize(notice.text)
	local w, h = render2d.GetSize()
	local x = w - text_w - 48
	local y = h - text_h - 120
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.7 * alpha)
	render2d.DrawRoundedRect(x - 14, y - 8, text_w + 28, text_h + 16, 6)
	render2d.SetColor(1, 1, 1, alpha)
	font:DrawText(notice.text, x, y, 0)
end)
