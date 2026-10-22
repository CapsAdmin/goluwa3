local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local visual_bounds = import("lua/visual_bounds.lua")
local AABB = import("goluwa/structs/aabb.lua")
local hitmarkers = {}
local bounds = AABB(0, 0, 0, 0, 0, 0)
local JITTER = 0.15
local marks = {}
local GRAVITY = 900
local COUNT_TIME = 0.4
local MAX_BOUNCES = 2
local TIERS = {
	{max = 0.25, size = 20, color = Color(0.85, 0.85, 0.85, 1), glow = Color(0, 0, 0, 1)},
	{max = 0.5, size = 28, color = Color(1, 0.9, 0.4, 1), glow = Color(0.4, 0.3, 0, 1)},
	{max = math.huge, size = 44, color = Color(1, 1, 1, 1), rainbow = true},
}
local HEAL = {size = 22, color = Color(0.5, 1, 0.5, 1), glow = Color(0, 0.3, 0, 1)}

local function get_center(owner)
	return (visual_bounds.Get(owner, bounds) or owner.rigid_body:GetBroadphaseAABB(nil, nil, bounds)):GetCenter()
end

function hitmarkers.Add(owner, amount, max_health, now, position)
	marks[#marks + 1] = {
		owner = owner,
		jitter = Vec3(math.randomf(-JITTER, JITTER), math.randomf(-JITTER, JITTER), math.randomf(-JITTER, JITTER)),
		last_position = position and position:Copy() or get_center(owner),
		amount = amount,
		fraction = math.abs(amount) / max_health,
		time = now,
		life = 1 + math.random() * 0.5,
		x = 0,
		y = 0,
		vx = math.randomf(-60, 60),
		vy = math.randomf(-380, -260),
		bounces = 0,
	}
end

function hitmarkers.Draw(camera, screen_w, screen_h, now, dt)
	for i = #marks, 1, -1 do
		local mark = marks[i]
		local age = now - mark.time

		if age > mark.life then
			table.remove(marks, i)
		else
			if mark.owner and mark.owner:IsValid() then
				mark.last_position = get_center(mark.owner) + mark.jitter
			end

			mark.vy = mark.vy + GRAVITY * dt
			mark.x = mark.x + mark.vx * dt
			mark.y = mark.y + mark.vy * dt

			if mark.y > 0 and mark.vy > 0 then
				if mark.bounces < MAX_BOUNCES then
					mark.y = 0
					mark.vy = -mark.vy * 0.5
					mark.bounces = mark.bounces + 1
				else
					mark.vy = 0
					mark.vx = mark.vx * 0.85
				end
			end

			local screen = camera:WorldPositionToScreen(mark.last_position, screen_w, screen_h)

			if screen then
				local count = math.min(age / COUNT_TIME, 1)
				local tier = HEAL
				local text = "+" .. math.ceil(-mark.amount * count)

				if mark.amount > 0 then
					text = tostring(math.ceil(mark.amount * count))

					for _, candidate in ipairs(TIERS) do
						if mark.fraction <= candidate.max then
							tier = candidate

							break
						end
					end
				end

				local alpha = math.min((mark.life - age) / (mark.life * 0.4), 1)
				local w, h = render2d.GetTextSize(text, nil, tier.size)
				render2d.DrawText{
					text = text,
					x = screen.x + mark.x - w / 2,
					y = screen.y + mark.y - h / 2,
					size = tier.size,
					foreground_color = tier.color,
					background_color = tier.rainbow and Color.FromHSV((now * 1.5) % 1, 0.8, 1) or tier.glow,
					softness = 4,
					alpha = alpha,
				}
			end
		end
	end
end

event.AddListener("HealthDamaged", "hitmarkers", function(owner, amount, max_health)
	if owner ~= _G.PLAYER_RIG and owner.rigid_body then
		hitmarkers.Add(owner, amount, max_health, system.GetElapsedTime())
	end
end)

return hitmarkers
