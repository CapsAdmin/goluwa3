local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local third_person = import("lua/third_person.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local progress_bar = import("goluwa/render2d/ui/elements/progress_bar.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local MARGIN_X = 48
local MARGIN_Y = 36
local BAR_HEIGHT = 15
local DEATH_SIZE = 32
local VISIBLE_TIME = 3
local FADE_TIME = 0.5
local tracker = progress_bar.NewTracker()
local state = {health = nil, change_time = -math.huge}

event.AddListener("DrawHUD", "health_hud", function()
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

	local health = rig.health
	local now = system.GetElapsedTime()
	local dt = system.GetFrameTime()
	local fraction = health:GetFraction()

	if state.health and health.Health ~= state.health then state.change_time = now end

	state.health = health.Health
	local shown, ghost = tracker:Update(fraction, dt, now)
	local active = theme.active
	local text_color = active:GetColor("text_on_dark")
	local screen_w, screen_h = render2d.GetSize()
	local alpha = health:IsDead() and
		1 or
		math.min((state.change_time + VISIBLE_TIME + FADE_TIME - now) / FADE_TIME, 1)

	if alpha > 0 then
		local S = screen_h / 1080
		local bar_h = BAR_HEIGHT * S
		local width = math.clamp(health.MaxHealth * 2, 120, screen_w / 3 / S) * S
		local color = active:GetColor("positive")

		if fraction < 0.25 then
			color = color:GetLerped(0.5 + 0.5 * math.sin(now * 10), active:GetColor("negative"))
		end

		render2d.PushMatrix()
		render2d.PushAlphaMultiplier(alpha)
		render2d.Translatef(MARGIN_X * S, MARGIN_Y * S)
		active:DrawProgressBar(Vec2(width, bar_h), {value = shown, ghost = ghost, ghost_color = "negative"}, color)
		render2d.PopAlphaMultiplier()
		render2d.PopMatrix()
		local size = math.floor(19 * S)
		local value = tostring(math.ceil(health.Health))
		local font, weight = active:GetTextStyle("body_strong")
		local _, text_h = render2d.GetTextSize(value, font, size, weight)
		render2d.DrawText{
			text = value,
			font = font,
			weight = weight,
			x = MARGIN_X * S + width + 14 * S,
			y = MARGIN_Y * S + (bar_h - text_h) / 2,
			size = size,
			foreground_color = text_color,
			background_color = true,
			alpha = alpha,
		}
	end

	if health:IsDead() then
		local text = "you died, left click to spawn, right click to revive here"
		local font, weight = active:GetTextStyle("body")
		local w, h = render2d.GetTextSize(text, font, DEATH_SIZE, weight)
		render2d.DrawText{
			text = text,
			font = font,
			weight = weight,
			x = (screen_w - w) / 2,
			y = (screen_h - h) / 2,
			size = DEATH_SIZE,
			foreground_color = text_color,
		}
	end
end)
