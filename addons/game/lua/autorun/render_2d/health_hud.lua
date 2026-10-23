local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local third_person = import("lua/third_person.lua")
local PLAYER_WIDTH = 260
local PLAYER_HEIGHT = 18
local PLAYER_MARGIN = 28
local DEATH_SIZE = 32
local TRAIL_DELAY = 0.6
local TRAIL_SPEED = 0.8
local SMOOTH_SPEED = 8
local TEXT = Color(0.95, 0.95, 0.95, 1)
local state = {health = nil, shown = 1, trail = 1, trail_time = 0}

local function draw_fill(x, y, w, h, fraction)
	if fraction <= 0.001 then return end

	local width = math.max(w * fraction, 2)
	render2d.DrawRoundedRect(x, y, width, h, math.min(h / 2, width / 2))
end

event.AddListener("DrawHUD", "health_hud", function()
	local rig = _G.PLAYER_RIG

	if not (rig and rig:IsValid()) or third_person.IsDefaultHudReplaced(rig) or third_person.IsHudHidden() then
		return
	end

	local health = rig.health
	local now = system.GetElapsedTime()
	local dt = system.GetFrameTime()
	local fraction = health:GetFraction()

	if state.health and health.Health < state.health then
		state.trail_time = now + TRAIL_DELAY
	end

	state.health = health.Health
	state.shown = state.shown + (fraction - state.shown) * math.min(dt * SMOOTH_SPEED, 1)

	if now > state.trail_time then
		state.trail = math.max(state.trail - dt * TRAIL_SPEED, state.shown)
	end

	state.trail = math.max(state.trail, state.shown)
	local screen_w, screen_h = render2d.GetSize()
	local x = (screen_w - PLAYER_WIDTH) / 2
	local y = screen_h - PLAYER_MARGIN - PLAYER_HEIGHT - 48
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.7)
	render2d.DrawRoundedRect(x - 2, y - 2, PLAYER_WIDTH + 4, PLAYER_HEIGHT + 4, PLAYER_HEIGHT / 2 + 2)

	if state.trail > state.shown then
		render2d.SetColor(0.85, 0.7, 0.2, 1)
		draw_fill(x, y, PLAYER_WIDTH, PLAYER_HEIGHT, state.trail)
	end

	render2d.SetColor(1 - state.shown, state.shown * 0.8 + 0.1, 0.15, 1)
	draw_fill(x, y, PLAYER_WIDTH, PLAYER_HEIGHT, state.shown)
	render2d.DrawText{
		text = math.ceil(health.Health) .. " / " .. health.MaxHealth,
		x = x + 10,
		y = y + 1,
		size = 14,
		foreground_color = TEXT,
	}

	if health:IsDead() then
		local text = "you died, click to respawn"
		local w, h = render2d.GetTextSize(text, nil, DEATH_SIZE)
		render2d.DrawText{
			text = text,
			x = (screen_w - w) / 2,
			y = (screen_h - h) / 2,
			size = DEATH_SIZE,
			foreground_color = TEXT,
		}
	end
end)
