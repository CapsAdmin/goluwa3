local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local assets = import("goluwa/assets.lua")
local visual_bounds = import("lua/visual_bounds.lua")
local AABB = import("goluwa/structs/aabb.lua")
local hitmarkers = {}
hitmarkers.Font = "Orbitron"
hitmarkers.FontWeight = "Bold"
local bounds = AABB(0, 0, 0, 0, 0, 0)
local JITTER = 0.15
local marks = {}
local GRAVITY = 900
local COUNT_TIME = 0.4
local MAX_BOUNCES = 2
local REPLACE_FADE = 0.1
local TIERS = {
	{max = 0.25, size = 22, color = Color(0.92, 0.94, 1, 1)},
	{max = 0.5, size = 28, color = Color(1, 0.88, 0.45, 1)},
	{max = 1, size = 34, color = Color(1, 0.45, 0.35, 1)},
	{max = math.huge, size = 46, color = Color(1, 1, 1, 1), rainbow = true},
}
local HEAL = {size = 24, color = Color(0.55, 1, 0.6, 1)}
local TEXT = {size = 22}
local DAMAGE_LINE = Color(1, 0.35, 0.3, 1)
local HEAL_LINE = Color(0.4, 1, 0.5, 1)
local MISS = Color(0.9, 0.9, 0.95, 1)
local glow_line

local function get_center(owner)
	local box = visual_bounds.Get(owner, bounds) or
		(
			owner.rigid_body and
			owner.rigid_body:GetBroadphaseAABB(nil, nil, bounds)
		)

	if box then return box:GetCenter() end

	return owner.transform:GetPosition():Copy()
end

local function add(owner, now, position)
	local mark = {
		owner = owner,
		jitter = Vec3(
			math.randomf(-JITTER, JITTER),
			math.randomf(-JITTER, JITTER),
			math.randomf(-JITTER, JITTER)
		),
		last_position = position and position:Copy() or get_center(owner),
		time = now,
		life = 1.2 + math.random() * 0.5,
		x = 0,
		y = 0,
		vx = math.randomf(-60, 60),
		vy = math.randomf(-380, -260),
		bounces = 0,
	}
	marks[#marks + 1] = mark
	return mark
end

function hitmarkers.Add(owner, amount, max_health, now, position, line_color)
	local mark = add(owner, now, position)
	mark.amount = amount
	mark.fraction = math.abs(amount) / math.max(max_health, 1)
	mark.line_color = line_color or (amount < 0 and HEAL_LINE or DAMAGE_LINE)
end

function hitmarkers.AddText(owner, text, color, now)
	for _, other in ipairs(marks) do
		if other.owner == owner and other.text == text and not other.fading then
			other.fading = true
			other.life = now - other.time + REPLACE_FADE
		end
	end

	local mark = add(owner, now)
	mark.text = text
	mark.line_color = color
	mark.vy = mark.vy * 0.6
	mark.life = mark.life + 0.5
end

function hitmarkers.Clear()
	table.clear(marks)
end

local function get_glow_line()
	if not glow_line then
		glow_line = assets.GetTexture(
			"textures/render/glow_line.lua",
			{config = {core_thickness = 1, glow_radius = 9, glow_intensity = 0.2}}
		)
	end

	return glow_line
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
				local tier = TEXT
				local text = mark.text
				local color = mark.line_color

				if not text then
					local count = math.min(age / COUNT_TIME, 1)

					if mark.amount == 0 then
						text = "MISS"
						color = MISS
					elseif mark.amount < 0 then
						tier = HEAL
						text = "+" .. math.ceil(-mark.amount * count)
					else
						text = tostring(math.ceil(mark.amount * count))

						for _, candidate in ipairs(TIERS) do
							if mark.fraction <= candidate.max then
								tier = candidate

								break
							end
						end
					end
				end

				local alpha = math.min((mark.life - age) / (mark.fading and REPLACE_FADE or mark.life * 0.4), 1)
				local pop = age < 0.12 and 1 + (1 - age / 0.12) * 0.6 or 1
				local size = math.floor(tier.size * pop + 0.5)
				local w, h = render2d.GetTextSize(text, hitmarkers.Font, size, hitmarkers.FontWeight)
				local x = screen.x + mark.x
				local y = screen.y + mark.y
				local line_y = y + h * 0.45
				render2d.PushBlendPreset("additive")
				render2d.SetTexture(get_glow_line())
				render2d.SetColor(color.r, color.g, color.b, alpha * 0.9)
				render2d.DrawRect(x - w * 1.4, line_y - 9, w * 2.8, 18)
				render2d.PopBlendMode()
				render2d.SetTexture(nil)
				local foreground = tier.color or color
				local background = Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, 1)

				if tier.rainbow then
					background = Color.FromHSV((now * 1.5) % 1, 0.8, 1)
				end

				render2d.DrawText{
					text = text,
					x = x - w / 2,
					y = y - h / 2,
					font = hitmarkers.Font,
					weight = hitmarkers.FontWeight,
					size = size,
					foreground_color = foreground,
					background_color = background,
					softness = 6,
					alpha = alpha,
				}
			end
		end
	end
end

return hitmarkers
