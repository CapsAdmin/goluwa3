local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local third_person = import("lua/third_person.lua")
local Health = import("lua/components/health.lua")
local PLAYER_WIDTH = 260
local PLAYER_HEIGHT = 18
local PLAYER_MARGIN = 28
local DEATH_SIZE = 32
local NPC_WIDTH = 80
local NPC_HEIGHT = 7
local NPC_LIFT = 0.25
local VISIBLE_TIME = 3
local FADE_TIME = 0.5
local TEXT = Color(0.95, 0.95, 0.95, 1)
local seen = table.weak("k")

local function draw_bar(x, y, w, h, fraction, alpha)
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.7 * alpha)
	render2d.DrawRoundedRect(x - 2, y - 2, w + 4, h + 4, h / 2 + 2)
	render2d.SetColor(1 - fraction, fraction * 0.8 + 0.1, 0.15, alpha)
	render2d.DrawRoundedRect(x, y, math.max(w * fraction, h), h, h / 2)
end

event.AddListener("DrawHUD", "health_hud", function()
	local rig = _G.PLAYER_RIG

	if not (rig and rig:IsValid()) or third_person.IsHudHidden() then return end

	local now = system.GetElapsedTime()
	local screen_w, screen_h = render2d.GetSize()
	local camera = render3d.GetMainCamera()

	for _, health in ipairs(Health.Instances) do
		local owner = health.Owner
		local record = seen[health]

		if not record then
			record = {health = health.Health, time = -math.huge, amount = 0}
			seen[health] = record
		end

		if health.Health < record.health then
			record.time = now
			record.amount = record.amount + record.health - health.Health
		elseif now - record.time > VISIBLE_TIME then
			record.amount = 0
		end

		record.health = health.Health

		if owner == rig then
			local x = (screen_w - PLAYER_WIDTH) / 2
			local y = screen_h - PLAYER_MARGIN - PLAYER_HEIGHT - 48
			draw_bar(x, y, PLAYER_WIDTH, PLAYER_HEIGHT, health:GetFraction(), 1)

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
			render2d.DrawText{
				text = math.ceil(health.Health) .. " / " .. health.MaxHealth,
				x = x + 10,
				y = y + 1,
				size = 14,
				foreground_color = TEXT,
			}
		else
			local alpha = math.min((record.time + VISIBLE_TIME + FADE_TIME - now) / FADE_TIME, 1)

			if alpha > 0 and owner.transform then
				local height = owner.player_movement and owner.player_movement:GetHeight() or 2
				local screen = camera:WorldPositionToScreen(
					owner.transform:GetPosition() + Vec3(0, height + NPC_LIFT, 0),
					screen_w,
					screen_h
				)

				if screen then
					local x = screen.x - NPC_WIDTH / 2
					draw_bar(x, screen.y, NPC_WIDTH, NPC_HEIGHT, health:GetFraction(), alpha)
					render2d.DrawText{
						text = tostring(-math.ceil(record.amount)),
						x = x,
						y = screen.y - 22,
						size = 16,
						foreground_color = Color(1, 0.85, 0.4, 1),
						alpha = alpha,
					}
				end
			end
		end
	end
end)
