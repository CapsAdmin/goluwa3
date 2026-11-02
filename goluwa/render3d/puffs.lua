local event = import("goluwa/event.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local puffs = {}
local MAX_PUFFS = 1536
local MAX_STREAKS = 128
local MAX_STREAMERS = 64
local frame_batches = {}
local frame_counts = {}

local function new_pool(max)
	return {items = {}, count = 0, free = {}, max = max}
end

local function acquire(pool)
	if pool.count >= pool.max then return end

	local item = table.remove(pool.free) or {}
	pool.count = pool.count + 1
	pool.items[pool.count] = item
	return item
end

local function clear_pool(pool)
	for i = pool.count, 1, -1 do
		pool.free[#pool.free + 1] = pool.items[i]
		pool.items[i] = nil
	end

	pool.count = 0
end

local function update_pool(pool, dt, update)
	local items = pool.items
	local i = 1

	while i <= pool.count do
		local item = items[i]

		if update(item, dt) then
			pool.free[#pool.free + 1] = item
			items[i] = items[pool.count]
			items[pool.count] = nil
			pool.count = pool.count - 1
		else
			i = i + 1
		end
	end
end

local puff_pool = new_pool(MAX_PUFFS)
local streak_pool = new_pool(MAX_STREAKS)
local streamer_pool = new_pool(MAX_STREAMERS)

local function get_batch(flipbook)
	local batch = frame_batches[flipbook]

	if not batch then
		batch, frame_counts[flipbook] = vfx.GetFlipbookBatch(flipbook)
		frame_batches[flipbook] = batch
	end

	return batch
end

function puffs.Spawn(config)
	local puff = acquire(puff_pool)

	if not puff then return end

	puff.flipbook = config.Flipbook
	puff.x, puff.y, puff.z = config.X, config.Y, config.Z
	puff.vx, puff.vy, puff.vz = config.VX, config.VY, config.VZ
	puff.drag = config.Drag
	puff.buoyancy = config.Buoyancy
	puff.floor = config.Floor
	puff.age = -config.Delay
	puff.life = config.Life
	puff.radius_start, puff.radius_end = config.RadiusStart, config.RadiusEnd
	puff.grow = config.Grow
	puff.r0, puff.g0, puff.b0 = config.R0, config.G0, config.B0
	puff.r1, puff.g1, puff.b1 = config.R1, config.G1, config.B1
	puff.color_curve = config.ColorCurve
	puff.brightness = config.Brightness
	puff.fade_in = config.FadeIn
	puff.fade_start = config.FadeStart
	puff.roll = config.Roll
	puff.spin = config.Spin
	puff.fps = config.Fps
	puff.offset = config.Offset
end

function puffs.SpawnStreak(config)
	local streak = acquire(streak_pool)

	if not streak then return end

	streak.flipbook = config.Flipbook
	streak.x, streak.y, streak.z = config.X, config.Y, config.Z
	streak.dx, streak.dy, streak.dz = config.DX, config.DY, config.DZ
	streak.age = -config.Delay
	streak.life = config.Life
	streak.reach = config.Reach
	streak.grow = config.Grow
	streak.tail_start, streak.tail_end = config.TailStart, config.TailEnd
	streak.rise = config.Rise
	streak.width_start, streak.width_end = config.WidthStart, config.WidthEnd
	streak.r0, streak.g0, streak.b0 = config.R0, config.G0, config.B0
	streak.r1, streak.g1, streak.b1 = config.R1, config.G1, config.B1
	streak.color_curve = config.ColorCurve
	streak.brightness = config.Brightness
	streak.fade_in = config.FadeIn
	streak.fade_start = config.FadeStart
	streak.fps = config.Fps
	streak.offset = config.Offset
end

function puffs.SpawnStreamer(config)
	local streamer = acquire(streamer_pool)

	if not streamer then return end

	streamer.x, streamer.y, streamer.z = config.X, config.Y, config.Z
	streamer.vx, streamer.vy, streamer.vz = config.VX, config.VY, config.VZ
	streamer.drag = config.Drag
	streamer.gravity = config.Gravity
	streamer.floor = config.Floor
	streamer.age = -config.Delay
	streamer.life = config.Life
	streamer.interval = config.Interval
	streamer.jitter = config.Jitter
	streamer.template = config.Template
	streamer.head_radius = config.HeadRadius
	streamer.head_r, streamer.head_g, streamer.head_b = config.HeadR, config.HeadG, config.HeadB
	streamer.offset = math.random(0, 63)
	streamer.roll = math.randomf(0, math.pi * 2)
	streamer.accumulated = 0
end

function puffs.GetCount()
	return puff_pool.count
end

function puffs.Clear()
	clear_pool(puff_pool)
	clear_pool(streak_pool)
	clear_pool(streamer_pool)
end

local function update_puff(puff, dt)
	puff.age = puff.age + dt

	if puff.age >= puff.life then return true end

	if puff.age <= 0 then return end

	local t = puff.age / puff.life
	local drag = math.max(1 - puff.drag * dt, 0)
	local vx, vy, vz = puff.vx * drag, puff.vy * drag + puff.buoyancy * dt, puff.vz * drag
	puff.vx, puff.vy, puff.vz = vx, vy, vz
	local x, y, z = puff.x + vx * dt, puff.y + vy * dt, puff.z + vz * dt
	local floor = puff.floor

	if floor and y < floor then y, puff.vy = floor, 0 end

	puff.x, puff.y, puff.z = x, y, z
	local radius = puff.radius_start + (
			puff.radius_end - puff.radius_start
		) * (
			1 - (
				1 - t
			) ^ puff.grow
		)
	local k = t ^ puff.color_curve
	local brightness = puff.brightness
	local alpha = math.min(t / puff.fade_in, 1) * (1 - math.smoothstep(puff.fade_start, 1, t))
	local batch = get_batch(puff.flipbook)
	batch:Add(
		x,
		y,
		z,
		radius,
		(puff.r0 + (puff.r1 - puff.r0) * k) * brightness,
		(puff.g0 + (puff.g1 - puff.g0) * k) * brightness,
		(puff.b0 + (puff.b1 - puff.b0) * k) * brightness,
		alpha,
		(puff.offset + math.floor(puff.age * puff.fps)) % frame_counts[puff.flipbook],
		puff.roll + puff.spin * puff.age
	)
end

local function update_streak(streak, dt)
	streak.age = streak.age + dt

	if streak.age >= streak.life then return true end

	if streak.age <= 0 then return end

	local t = streak.age / streak.life
	local tip = streak.reach * (1 - (1 - t) ^ streak.grow)
	local tail = math.min(streak.reach * streak.tail_end * math.smoothstep(streak.tail_start, 1, t), tip)
	local middle = (tip + tail) * 0.5
	local rise = streak.rise * t * t
	local k = t ^ streak.color_curve
	local brightness = streak.brightness
	local alpha = math.min(t / streak.fade_in, 1) * (1 - math.smoothstep(streak.fade_start, 1, t))
	local batch = get_batch(streak.flipbook)
	batch:AddStreak(
		streak.x + streak.dx * middle,
		streak.y + streak.dy * middle + rise,
		streak.z + streak.dz * middle,
		streak.dx,
		streak.dy,
		streak.dz,
		(tip - tail) * 0.5,
		streak.width_start + (streak.width_end - streak.width_start) * t,
		(streak.r0 + (streak.r1 - streak.r0) * k) * brightness,
		(streak.g0 + (streak.g1 - streak.g0) * k) * brightness,
		(streak.b0 + (streak.b1 - streak.b0) * k) * brightness,
		alpha,
		(streak.offset + math.floor(streak.age * streak.fps)) % frame_counts[streak.flipbook]
	)
end

local emit = {}

local function update_streamer(streamer, dt)
	streamer.age = streamer.age + dt

	if streamer.age >= streamer.life then return true end

	if streamer.age <= 0 then return end

	local drag = math.max(1 - streamer.drag * dt, 0)
	local vx, vy, vz = streamer.vx * drag, streamer.vy * drag - streamer.gravity * dt, streamer.vz * drag
	streamer.vx, streamer.vy, streamer.vz = vx, vy, vz
	streamer.x, streamer.y, streamer.z = streamer.x + vx * dt, streamer.y + vy * dt, streamer.z + vz * dt

	if streamer.floor and streamer.y < streamer.floor then return true end

	if streamer.head_radius > 0 then
		local flicker = 0.8 + 0.2 * math.sin(streamer.age * 40 + streamer.offset)
		local fade = 1 - math.smoothstep(0.6, 1, streamer.age / streamer.life)
		local batch = get_batch("fire")
		batch:Add(
			streamer.x,
			streamer.y,
			streamer.z,
			streamer.head_radius * flicker,
			streamer.head_r * flicker,
			streamer.head_g * flicker,
			streamer.head_b * flicker,
			fade,
			(streamer.offset + math.floor(streamer.age * 14)) % frame_counts.fire,
			streamer.roll
		)
	end

	streamer.accumulated = streamer.accumulated + dt

	while streamer.accumulated >= streamer.interval do
		streamer.accumulated = streamer.accumulated - streamer.interval

		for key, value in pairs(streamer.template) do
			emit[key] = value
		end

		local jitter = streamer.jitter
		emit.X, emit.Y, emit.Z = streamer.x, streamer.y, streamer.z
		emit.VX, emit.VY, emit.VZ = math.randomf(-jitter, jitter),
		math.randomf(-jitter, jitter),
		math.randomf(-jitter, jitter)
		emit.Delay = 0
		emit.Roll = math.randomf(0, math.pi * 2)
		emit.Offset = math.random(0, 63)
		puffs.Spawn(emit)
	end
end

event.AddListener("Update", "puffs", function(dt)
	if puff_pool.count + streak_pool.count + streamer_pool.count == 0 then return end

	dt = math.min(dt, 0.05)
	table.clear(frame_batches)
	update_pool(streamer_pool, dt, update_streamer)
	update_pool(streak_pool, dt, update_streak)
	update_pool(puff_pool, dt, update_puff)
end)

return puffs
