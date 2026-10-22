local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local network = import("goluwa/network/network.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local third_person = import("lua/third_person.lua")
local hitmarkers = import("lua/hitmarkers.lua")
local targeting = import("lua/targeting.lua")
local visual_bounds = import("lua/visual_bounds.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Health = import("lua/components/health.lua")
local bounds = AABB(0, 0, 0, 0, 0, 0)
local PLAYER_WIDTH = 260
local PLAYER_HEIGHT = 18
local PLAYER_MARGIN = 28
local DEATH_SIZE = 32
local NPC_WIDTH = 90
local NPC_TARGET_WIDTH = 140
local NPC_HEIGHT = 8
local NPC_LIFT = 0.25
local VISIBLE_TIME = 6
local FADE_TIME = 0.5
local TRAIL_DELAY = 0.6
local TRAIL_SPEED = 0.8
local SMOOTH_SPEED = 8
local TEXT = Color(0.95, 0.95, 0.95, 1)
local seen = table.weak("k")
local tracked = {}
local KILL_WINDOW = 1
local LINGER_TIME = 3
local LINGER_FADE = 0.5

local function draw_fill(x, y, w, h, fraction)
	if fraction <= 0.001 then return end

	local width = math.max(w * fraction, 2)
	render2d.DrawRoundedRect(x, y, width, h, math.min(h / 2, width / 2))
end

local function draw_bar(x, y, w, h, fraction, trail, alpha)
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.7 * alpha)
	render2d.DrawRoundedRect(x - 2, y - 2, w + 4, h + 4, h / 2 + 2)

	if trail > fraction then
		render2d.SetColor(0.85, 0.7, 0.2, alpha)
		draw_fill(x, y, w, h, trail)
	end

	render2d.SetColor(1 - fraction, fraction * 0.8 + 0.1, 0.15, alpha)
	draw_fill(x, y, w, h, fraction)
end

local function draw_npc_bar(camera, record, width, alpha, screen_w, screen_h)
	local screen = camera:WorldPositionToScreen(record.anchor, screen_w, screen_h)

	if not screen then return end

	local x = screen.x - width / 2
	draw_bar(x, screen.y, width, NPC_HEIGHT, record.shown, record.trail, alpha)
	render2d.DrawText{
		text = record.name,
		x = x,
		y = screen.y - 22,
		size = 16,
		foreground_color = TEXT,
		alpha = alpha,
	}
end

event.AddListener("DrawHUD", "health_hud", function()
	local rig = _G.PLAYER_RIG

	if not (rig and rig:IsValid()) or third_person.IsHudHidden() then return end

	local now = system.GetElapsedTime()
	local dt = system.GetFrameTime()
	local screen_w, screen_h = render2d.GetSize()
	local camera = render3d.GetMainCamera()
	local target = targeting.Get()
	local target_owner = target and target.Owner

	for _, health in ipairs(Health.Instances) do
		local owner = health.Owner
		local record = seen[health]

		if not record then
			record = {
				health_component = health,
				health = health.Health,
				time = -math.huge,
				shown = health:GetFraction(),
				trail = health:GetFraction(),
				trail_time = 0,
				anchor = Vec3(),
				center = Vec3(),
				name = "",
				removed_time = nil,
				is_rig = owner == rig,
			}
			seen[health] = record
			tracked[#tracked + 1] = record
		end

		record.name = owner:GetName()
		local fraction = health:GetFraction()

		if not record.is_rig and owner.rigid_body then
			local box = visual_bounds.Get(owner, bounds) or owner.rigid_body:GetBroadphaseAABB(nil, nil, bounds)
			record.center:Set((box.min_x + box.max_x) * 0.5, (box.min_y + box.max_y) * 0.5, (box.min_z + box.max_z) * 0.5)
			record.anchor:Set(record.center.x, box.max_y + NPC_LIFT, record.center.z)
		end

		if health.Health ~= record.health then
			if not record.is_rig and owner.rigid_body and not network.HasAuthority() then
				hitmarkers.Add(owner, record.health - health.Health, health.MaxHealth, now)
			end

			if health.Health < record.health then
				record.time = now
				record.trail_time = now + TRAIL_DELAY
			end
		end

		record.health = health.Health
		record.shown = record.shown + (fraction - record.shown) * math.min(dt * SMOOTH_SPEED, 1)

		if now > record.trail_time then
			record.trail = math.max(record.trail - dt * TRAIL_SPEED, record.shown)
		end

		record.trail = math.max(record.trail, record.shown)

		if record.is_rig then
			local x = (screen_w - PLAYER_WIDTH) / 2
			local y = screen_h - PLAYER_MARGIN - PLAYER_HEIGHT - 48
			draw_bar(x, y, PLAYER_WIDTH, PLAYER_HEIGHT, record.shown, record.trail, 1)

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
		elseif owner.rigid_body then
			local is_target = owner == target_owner
			local alpha = is_target and 1 or
				math.min((record.time + VISIBLE_TIME + FADE_TIME - now) / FADE_TIME, 1)

			if alpha > 0 then
				draw_npc_bar(camera, record, is_target and NPC_TARGET_WIDTH or NPC_WIDTH, alpha, screen_w, screen_h)
			end
		end
	end

	for i = #tracked, 1, -1 do
		local record = tracked[i]

		if record.is_rig then
			if not record.health_component:IsValid() then table.remove(tracked, i) end
		elseif not record.health_component:IsValid() then
			if not record.removed_time then
				record.removed_time = now

				if now - record.time < KILL_WINDOW then record.shown = 0 end

				record.trail_time = now + TRAIL_DELAY
			end

			local age = now - record.removed_time
			local alpha = math.min((LINGER_TIME + LINGER_FADE - age) / LINGER_FADE, 1)

			if alpha <= 0 then
				table.remove(tracked, i)
			else
				record.trail = math.max(record.trail - dt * TRAIL_SPEED * (now > record.trail_time and 1 or 0), record.shown)
				draw_npc_bar(camera, record, NPC_WIDTH, alpha, screen_w, screen_h)
			end
		end
	end

	hitmarkers.Draw(camera, screen_w, screen_h, now, dt)
end)
