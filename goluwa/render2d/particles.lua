local ffi = require("ffi")
local render2d = import("goluwa/render2d/render2d.lua")
local event = import("goluwa/event.lua")
local particles = library()
particles.pool = {}
particles.max_count = 500
particles.events_registered = false

function particles.Spawn(x, y, color, opts)
	opts = opts or {}
	local count = opts.count or 8
	local speed = opts.speed or 100
	local size = opts.size or 3
	local life = opts.life or 0.5
	local available = particles.max_count - #particles.pool
	count = math.min(count, available)

	if not particles.events_registered then
		event.AddListener("Update", "particles_update", particles.Update)
		event.AddListener("Draw2D", "particles_draw", particles.Draw)
		particles.events_registered = true
	end

	for i = 1, count do
		local angle = math.random() * math.pi * 2
		local spd = speed * (0.5 + math.random() * 0.5)
		table.insert(
			particles.pool,
			{
				x = x,
				y = y,
				vx = math.cos(angle) * spd,
				vy = math.sin(angle) * spd,
				life = life * (0.6 + math.random() * 0.8),
				max_life = life * (0.6 + math.random() * 0.8),
				color = color,
				size = size * (0.5 + math.random() * 0.5),
			}
		)
	end
end

local function check_cleanup()
	if not particles.events_registered then return end

	if particles.pool[1] then return end

	event.RemoveListener("Update", "particles_update")
	event.RemoveListener("Draw2D", "particles_draw")
	particles.events_registered = false
end

function particles.Update(dt)
	for i = #particles.pool, 1, -1 do
		local p = particles.pool[i]
		p.x = p.x + p.vx * dt
		p.y = p.y + p.vy * dt
		p.life = p.life - dt

		if p.life <= 0 then
			table.remove(particles.pool, i)
			check_cleanup()
		end
	end
end

function particles.Draw()
	render2d.PushBlendPreset("additive")

	for _, p in ipairs(particles.pool) do
		local alpha = p.life / p.max_life
		render2d.PushColor(p.color.r, p.color.g, p.color.b, alpha)
		render2d.DrawRect(p.x - p.size / 2, p.y - p.size / 2, p.size, p.size)
		render2d.PopColor()
	end

	render2d.PopBlendMode()
end

function particles.Clear()
	particles.pool = {}
	check_cleanup()
end

return particles
