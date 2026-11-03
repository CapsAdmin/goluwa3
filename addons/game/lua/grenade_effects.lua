local event = import("goluwa/event.lua")
local new_event = import("goluwa/network/replicated_event.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local data_files = import("goluwa/data_files.lua")
local grenade_effects = {}
local FIRE = Color(1, 0.55, 0.15, 1)
local EMBER = Color(0.55, 0.08, 0.02, 1)
local FUSE = Color(1, 0.12, 0.06, 1)
local FLASH_HOT = Color(1, 0.85, 0.55, 1)
local FLASH_COOL = Color(1, 0.3, 0.08, 1)
local UP = Vec3(0, 1, 0)
local TRAIL_COUNT = 10
local GRAVITY = 9.8
local PUFF_EMISSIVE = 14000
local ARM_DRAG = 6
local ARM_SPEED_PER_REACH = 6.4
local ARM_STRETCH = 0.04
local EXPLOSION_SPL = 150
local EXPLOSION_KEEP = 0.35
local SOUNDS = {"weapons/explode3.wav", "weapons/explode4.wav", "weapons/explode5.wav"}
local clips, vfx, screen_shake, sounds, render3d, screen_fields, raycast

local function enabled()
	return RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
end

grenade_effects.IsVisual = enabled

local function burst(properties)
	properties.Lit = false
	properties.Collision = "none"
	properties.MaxParticles = 512
	return properties
end

grenade_effects.PuffFiles = data_files.New("lua/effect_data/")
local puff_styles

function grenade_effects.UpdatePuffs(data)
	grenade_effects.PuffFiles:Remember("grenade_puffs", data)
	puff_styles = table.copy(data.Styles)
end

function grenade_effects.ReloadPuffs()
	grenade_effects.UpdatePuffs(grenade_effects.PuffFiles:Read("grenade_puffs"))
end

function grenade_effects.SavePuffs()
	return grenade_effects.PuffFiles:Save("grenade_puffs")
end

grenade_effects.UpdatePuffs(import("lua/effect_data/grenade_puffs.lua"))
local TRACE_COUNT = 24
local TRACE_DIRECTIONS = {}
local trace_fractions = {}

for i = 1, TRACE_COUNT do
	local y = 1 - (i - 0.5) * 2 / TRACE_COUNT
	local ring = math.sqrt(1 - y * y)
	local phi = i * 2.399963
	TRACE_DIRECTIONS[i] = {ring * math.cos(phi), y, ring * math.sin(phi)}
end

local function trace_blast(position, normal, length)
	local origin = position + normal * 0.3
	local ax, ay, az = 0, 0, 0

	for i = 1, TRACE_COUNT do
		local d = TRACE_DIRECTIONS[i]
		local hit = raycast.CastClosestSolid(origin, Vec3(d[1], d[2], d[3]), length)
		local fraction = hit and math.min(hit.distance / length, 1) or 1
		trace_fractions[i] = fraction
		ax, ay, az = ax + d[1] * fraction, ay + d[2] * fraction, az + d[3] * fraction
	end

	local size = math.sqrt(ax * ax + ay * ay + az * az)

	if size < 2 then return normal.x, normal.y, normal.z end

	return ax / size, ay / size, az / size
end

local function openness_at(dx, dy, dz)
	local best, fraction = -2, 1

	for i = 1, TRACE_COUNT do
		local d = TRACE_DIRECTIONS[i]
		local dot = d[1] * dx + d[2] * dy + d[3] * dz

		if dot > best then best, fraction = dot, trace_fractions[i] end
	end

	return fraction
end

local function random_direction(nx, ny, nz)
	local cos_t = math.randomf(-1, 1)
	local sin_t = math.sqrt(1 - cos_t * cos_t)
	local phi = math.randomf(0, math.pi * 2)
	local dx, dy, dz = sin_t * math.cos(phi), cos_t, sin_t * math.sin(phi)
	local along = dx * nx + dy * ny + dz * nz

	if along < 0 then
		dx, dy, dz = dx - 2 * along * nx, dy - 2 * along * ny, dz - 2 * along * nz
	end

	return dx, dy, dz
end

local function pick_open_direction(ax, ay, az, minimum)
	local dx, dy, dz, fraction

	for _ = 1, 8 do
		dx, dy, dz = random_direction(ax, ay, az)
		fraction = openness_at(dx, dy, dz)

		if fraction >= minimum then break end
	end

	return dx, dy, dz, fraction
end

local streamers = {}
local streamer_position = Vec3()

local function update_streamers(dt)
	for i = #streamers, 1, -1 do
		local streamer = streamers[i]
		streamer.age = streamer.age + dt

		if streamer.age >= streamer.life or (streamer.floor and streamer.y < streamer.floor) then
			streamer.trail.particle_emitter_gpu:SetPlaying(false)
			vfx.RemoveDelayed(streamer.trail, streamer.linger)

			if streamer.head then
				streamer.head.particle_emitter_gpu:SetPlaying(false)
				vfx.RemoveDelayed(streamer.head, 1)
			end

			table.remove(streamers, i)
		elseif streamer.age > 0 then
			local drag = math.max(1 - streamer.drag * dt, 0)
			streamer.vx = streamer.vx * drag
			streamer.vy = streamer.vy * drag - streamer.gravity * dt
			streamer.vz = streamer.vz * drag
			streamer.x = streamer.x + streamer.vx * dt
			streamer.y = streamer.y + streamer.vy * dt
			streamer.z = streamer.z + streamer.vz * dt
			streamer_position.x, streamer_position.y, streamer_position.z = streamer.x, streamer.y, streamer.z
			streamer.trail.transform:SetPosition(streamer_position)

			if streamer.head then streamer.head.transform:SetPosition(streamer_position) end
		end
	end
end

local function spawn_streamer(streamer, trail, head_radius)
	streamer.age = -streamer.delay
	streamer.linger = trail.LifetimeMax + 0.5
	streamer.trail = vfx.CreateEmitter("grenade_streamer", trail)
	streamer_position.x, streamer_position.y, streamer_position.z = streamer.x, streamer.y, streamer.z
	streamer.trail.transform:SetPosition(streamer_position)

	if head_radius > 0 then
		streamer.head = vfx.CreateEmitter(
			"grenade_streamer_head",
			{
				Style = "puff",
				StyleParams = {Sprite = "fire", Grow = 1, ColorCurve = 1, FadeIn = 0.1, FadeStart = 0.6},
				MaxParticles = 16,
				Rate = 60,
				Shape = "point",
				Spread = 180,
				SpeedMin = 0,
				SpeedMax = 0,
				Drag = 0,
				GravityScale = 0,
				LifetimeMin = 0.08,
				LifetimeMax = 0.08,
				SizeStart = head_radius * 2,
				SizeEnd = head_radius * 2,
				ColorStart = Color(1, 0.4, 0.1, 1),
				ColorEnd = Color(1, 0.4, 0.1, 1),
				Lit = false,
				Emissive = 3 * PUFF_EMISSIVE,
				FlipbookFps = 14,
				FlipbookRandomStart = true,
				Collision = "none",
			}
		)
		streamer.head.transform:SetPosition(streamer_position)
	end

	streamers[#streamers + 1] = streamer
end

local function smoke_trail(rate, jitter, drag, buoyancy, life, radius_start, radius_end, grow, from, to, fade_in, fade_start, spin)
	return {
		Style = "puff",
		StyleParams = {Sprite = "smoke", Grow = grow, ColorCurve = 1, FadeIn = fade_in, FadeStart = fade_start},
		MaxParticles = 256,
		Rate = rate,
		Shape = "point",
		Spread = 180,
		SpeedMin = 0,
		SpeedMax = jitter * 1.7,
		Drag = drag,
		GravityScale = -buoyancy / GRAVITY,
		LifetimeMin = life * 0.85,
		LifetimeMax = life,
		SizeStart = radius_start * 1.9,
		SizeEnd = radius_end * 1.9,
		ColorStart = from,
		ColorEnd = to,
		Lit = true,
		Emissive = 0,
		FlipbookFps = 14,
		FlipbookRandomStart = true,
		SpinMin = -spin,
		SpinMax = spin,
		Collision = "none",
	}
end

local function spawn_arms_and_trails(position, ax, ay, az, k, floor)
	local ox, oy, oz = position.x + ax * 0.4 * k, position.y + ay * 0.4 * k, position.z + az * 0.4 * k
	local origin = Vec3(ox, oy, oz)

	for i = 1, 10 do
		local dx, dy, dz, open = pick_open_direction(ax, ay, az, 0.3)
		local reach_scale = math.floor(math.min(open * 1.3, 1) * 10 + 0.5) / 10
		local key = ("grenade_arm_%.2f_%.1f"):format(k, reach_scale)

		if not vfx.HasBurst(key) then
			local speed = k * reach_scale * ARM_SPEED_PER_REACH
			vfx.DefineBurst(
				key,
				{
					Style = "puff",
					StyleParams = {Sprite = "fire", Grow = 1, ColorCurve = 0.7, FadeIn = 0.05, FadeStart = 0.4},
					MaxParticles = 64,
					Shape = "point",
					Spread = 0,
					SpeedMin = 5 * speed,
					SpeedMax = 9 * speed,
					LifetimeMin = 0.35,
					LifetimeMax = 0.6,
					Drag = ARM_DRAG,
					GravityScale = -1.2 * k / GRAVITY,
					SizeStart = 0.26 * k,
					SizeEnd = 0.12 * k,
					Stretch = ARM_STRETCH,
					ColorStart = Color(1, 0.5, 0.15, 1),
					ColorEnd = Color(1, 0.18, 0.03, 1),
					Lit = false,
					Emissive = 2.6 * PUFF_EMISSIVE,
					FlipbookFps = 16,
					FlipbookRandomStart = true,
					Collision = "none",
				}
			)
		end

		vfx.Burst(key, origin, Vec3(dx, dy, dz), 1)
	end

	for i = 1, 6 do
		local dx, dy, dz, open = pick_open_direction(ax, ay, az, 0.4)
		dx, dy, dz = dx + ax * 0.6, dy + ay * 0.6, dz + az * 0.6
		local length = math.sqrt(dx * dx + dy * dy + dz * dz)
		local speed = math.randomf(7, 12) * k * (0.4 + 0.6 * open)
		spawn_streamer(
			{
				x = ox,
				y = oy,
				z = oz,
				vx = dx / length * speed,
				vy = dy / length * speed,
				vz = dz / length * speed,
				drag = 0.4,
				gravity = GRAVITY,
				floor = floor,
				delay = 0,
				life = math.randomf(0.8, 1.7),
			},
			smoke_trail(
				1 / 0.018,
				0.4 * k,
				1.5,
				0.8 * k,
				math.randomf(1.8, 3),
				0.18 * k,
				0.5 * k,
				1.3,
				Color(0.245, 0.223, 0.2, 1),
				Color(0.223, 0.223, 0.223, 1),
				0.1,
				0.3,
				34
			),
			0.28 * k
		)
	end
end

local SMOKE_COLUMN_KINDS = {
	{
		lift = 1,
		sideways = 0.15,
		speed = {1, 1.7},
		gravity = -0.7,
		drag = 0.8,
		life = {1.4, 2.2},
		buoyancy = 1.2,
	},
	{
		lift = 0,
		sideways = 1,
		speed = {0.7, 1.4},
		gravity = 0,
		drag = 1.6,
		life = {1.6, 2.6},
		buoyancy = 0.15,
	},
	{
		lift = 0.4,
		sideways = 0.7,
		speed = {1.7, 2.7},
		gravity = 0,
		drag = 1.1,
		life = {1, 1.8},
		buoyancy = 0.5,
	},
}

local function spawn_smoke_columns(position, ax, ay, az, k)
	for _ = 1, math.random(1, 3) do
		local kind = SMOKE_COLUMN_KINDS[math.random(#SMOKE_COLUMN_KINDS)]
		local dx, dy, dz = random_direction(ax, ay, az)
		local along = dx * ax + dy * ay + dz * az
		local sx, sy, sz = dx - along * ax, dy - along * ay, dz - along * az
		local flat = math.sqrt(sx * sx + sy * sy + sz * sz)
		sx, sy, sz = sx / flat, sy / flat, sz / flat
		local open = openness_at(sx, sy, sz)
		local speed = math.randomf(kind.speed[1], kind.speed[2]) * k * (0.3 + 0.7 * open)
		local mx = sx * kind.sideways + ax * kind.lift
		local my = sy * kind.sideways + ay * kind.lift
		local mz = sz * kind.sideways + az * kind.lift
		local length = math.sqrt(mx * mx + my * my + mz * mz)
		spawn_streamer(
			{
				x = position.x + ax * 0.25 * k,
				y = position.y + ay * 0.25 * k,
				z = position.z + az * 0.25 * k,
				vx = mx / length * speed,
				vy = my / length * speed,
				vz = mz / length * speed,
				drag = kind.drag,
				gravity = kind.gravity * k,
				delay = math.randomf(0, 0.15),
				life = math.randomf(kind.life[1], kind.life[2]),
			},
			smoke_trail(
				10,
				0.4 * k,
				1.2,
				kind.buoyancy * k,
				math.randomf(2, 3.5),
				0.375 * k,
				math.randomf(0.875, 1.75) * k,
				1.2,
				Color(0.2, 0.185, 0.17, 1),
				Color(0.2, 0.2, 0.2, 1),
				0.15,
				0.4,
				29
			),
			0
		)
	end
end

local function spawn_fireball(position, normal, size)
	local k = size / 6 * 1.7
	local nx, ny, nz = normal.x, normal.y, normal.z
	local floor = ny > 0.7 and position.y + 0.1 or nil
	local ax, ay, az = trace_blast(position, normal, size * 1.5)
	local open = 0

	for i = 1, TRACE_COUNT do
		open = open + trace_fractions[i]
	end

	local open_scale = math.floor((0.35 + 0.65 * open / TRACE_COUNT) * 10 + 0.5) / 10
	local blast_axis = Vec3(ax, ay, az)

	for style_index, style in ipairs(puff_styles) do
		local lift = style.Lift * k
		local key = ("grenade_puff_%d_%.2f_%.1f"):format(style_index, k, open_scale)

		if not vfx.HasBurst(key) then
			local flipbook = vfx.GetFlipbook(style.Flipbook)
			local speed = k * open_scale
			vfx.DefineBurst(
				key,
				{
					Style = "puff",
					StyleParams = {
						Sprite = style.Flipbook,
						Grow = style.Grow,
						ColorCurve = style.ColorCurve,
						FadeIn = style.FadeIn,
						FadeStart = style.FadeStart,
					},
					MaxParticles = 128,
					Shape = "point",
					Spread = style.Flat and 180 or 90,
					Flatten = style.Flat and 1 or 0,
					SpeedMin = style.Speed[1] * speed,
					SpeedMax = style.Speed[2] * speed,
					LifetimeMin = style.Life[1],
					LifetimeMax = style.Life[2],
					Drag = style.Drag,
					GravityScale = -style.Buoyancy * k / GRAVITY,
					SizeStart = style.RadiusStart * k * 1.9,
					SizeEnd = style.RadiusEnd * k * 1.9,
					ColorStart = Color(style.From[1], style.From[2], style.From[3], 1),
					ColorEnd = Color(style.To[1], style.To[2], style.To[3], 1),
					Lit = flipbook.Normal ~= nil,
					Emissive = flipbook.Normal and 0 or style.Brightness * PUFF_EMISSIVE,
					FlipbookFps = 16,
					FlipbookRandomStart = true,
					SpinMin = -28,
					SpinMax = 28,
					Collision = "none",
				}
			)
		end

		vfx.Burst(
			key,
			Vec3(position.x + ax * lift, position.y + ay * lift, position.z + az * lift),
			style.Flat and normal or blast_axis,
			style.Count
		)
	end

	spawn_arms_and_trails(position, ax, ay, az, k, floor)
	spawn_smoke_columns(position, ax, ay, az, k)
end

local function init()
	if clips then return end

	clips = import("goluwa/render3d/clips.lua")
	screen_fields = import("goluwa/render3d/screen_fields.lua")
	vfx = import("goluwa/render3d/vfx.lua")
	screen_shake = import("lua/screen_shake.lua")
	sounds = import("lua/sounds.lua")
	render3d = import("goluwa/render3d/render3d.lua")
	raycast = import("goluwa/render3d/raycast.lua")
	event.AddListener("Update", "grenade_streamers", update_streamers)
	clips.Define(
		"grenade_fuse",
		{
			Duration = math.huge,
			Layers = {
				{Type = "orb", Size = "size", Alpha = "blink", Flicker = "blink", LensScale = 0},
				{
					Type = "gpu_trail",
					Points = 28,
					Texture = "orbit_trail",
					Strength = 8,
					Radius = 0.014,
					Drift = 0.3,
					Alpha = "fade",
				},
			},
		}
	)
	clips.Define(
		"grenade_explosion",
		{
			Duration = 1.8,
			Tracks = {
				flash = {{0, 1, "outQuart"}, {0.14, 0}},
				shock = {{0, 0.1, "outQuart"}, {0.4, 0.85}},
				shock_fade = {{0, 1, "outQuad"}, {0.4, 0}},
				ember = {{0, 0}, {0.04, 1, "outQuad"}, {1, 0}},
				trail_fade = {{0, 1, "outQuad"}, {0.75, 0}},
			},
			Bursts = {
				grenade_sparks = burst{
					Spread = 160,
					SpeedMin = 6,
					SpeedMax = 22,
					LifetimeMin = 0.4,
					LifetimeMax = 1.1,
					SizeStart = 0.025,
					SizeEnd = 0,
					Drag = 0.3,
					GravityScale = 1,
					Sparkle = 1,
					Emissive = 6e5,
					ColorStart = Color(1, 0.9, 0.55, 1),
					ColorEnd = Color(1, 0.3, 0.05, 0),
				},
				grenade_embers = burst{
					Spread = 180,
					SpeedMin = 1,
					SpeedMax = 5,
					LifetimeMin = 1.5,
					LifetimeMax = 3,
					SizeStart = 0.02,
					SizeEnd = 0,
					Drag = 1,
					GravityScale = -0.1,
					Sparkle = 1,
					Emissive = 3e5,
					ColorStart = Color(1, 0.55, 0.15, 1),
					ColorEnd = Color(0.6, 0.08, 0.02, 0),
				},
			},
			Debris = {
				grenade_shrapnel = {
					Material = {Color = Color(0.14, 0.13, 0.12, 1), Roughness = 0.35, Metallic = 0.9},
					Emitter = {
						Mesh = "shard",
						MaxParticles = 128,
						Spread = 90,
						SpeedMin = 4,
						SpeedMax = 14,
						LifetimeMin = 1.2,
						LifetimeMax = 2.2,
						SizeStart = 0.07,
						SizeEnd = 0.05,
						GravityScale = 1,
						Drag = 0.2,
						Spin = 500,
						Collision = "rays",
						OnHit = "bounce",
						Restitution = 0.35,
						Friction = 0.5,
					},
				},
				grenade_chunks = {
					Material = {Color = Color(0.22, 0.17, 0.12, 1), Roughness = 0.95, Metallic = 0},
					Emitter = {
						Mesh = "cube",
						MaxParticles = 64,
						Spread = 70,
						SpeedMin = 2,
						SpeedMax = 8,
						LifetimeMin = 1.5,
						LifetimeMax = 2.5,
						SizeStart = 0.11,
						SizeEnd = 0.09,
						GravityScale = 1,
						Drag = 0.3,
						Spin = 300,
						Collision = "rays",
						OnHit = "bounce",
						Restitution = 0.3,
						Friction = 0.7,
					},
				},
			},
			Events = {
				{0, Burst = "grenade_sparks", Count = 160, Direction = "normal"},
				{0, Burst = "grenade_embers", Count = 50, Direction = "normal"},
				{0, Debris = "grenade_shrapnel", Count = 40, Direction = "normal"},
				{0, Debris = "grenade_chunks", Count = 14, Direction = "normal"},
				{
					0,
					function(p)
						spawn_fireball(p.position, p.normal, p.size)
						screen_fields.Add{
							Position = p.position + p.normal * 0.6,
							Duration = 0.9,
							Radius = p.size * 1.6,
							Thickness = 0.3,
							Blur = 55,
							Ring = 0.04,
							Aberration = 8,
						}
						screen_fields.Add{
							Position = p.position + p.normal * p.size * 0.15,
							Duration = 2.4,
							Attack = 0.25,
							Radius = p.size * 0.6,
							Expand = false,
							Thickness = 0.5,
							Haze = 0.8,
							Ring = 0.01,
						}
						vfx.Flash(
							p.position + p.normal * 0.6,
							FLASH_HOT,
							60000 * p.size * p.size,
							0.45,
							{
								Range = p.size * 5,
								SourceRadius = p.size * 0.04,
								ColorEnd = FLASH_COOL,
								Attack = 0.03,
								Falloff = 4,
								Flicker = 0.15,
							}
						)
						vfx.Flash(
							p.position + p.normal * p.size * 0.3,
							FIRE,
							14000 * p.size * p.size,
							4.5,
							{
								Range = p.size * 5,
								SourceRadius = p.size * 0.05,
								SourceRadiusEnd = p.size * 1.6,
								ColorEnd = EMBER,
								Attack = 0.06,
								Falloff = 0.7,
								Sustain = 0.25 / 3,
								SustainTime = 0.12,
								Flicker = 0.3,
								Velocity = p.normal * p.size * 0.17,
							}
						)
						sounds.PlayRandom(
							SOUNDS,
							p.position,
							sounds.SPLToVolume(EXPLOSION_SPL),
							math.randomf(0.9, 1.1),
							EXPLOSION_KEEP
						)
						local distance = (render3d.GetCamera():GetPosition() - p.position):GetLength()
						local closeness = math.clamp(1 - distance / (p.size * 3), 0, 1)

						if closeness > 0 then
							screen_shake.Add(0.35 * closeness * closeness, 1.2, 0.8)
						end
					end,
				},
			},
			Layers = {
				{
					Type = "sprite",
					Texture = "flare",
					Lift = 0.3,
					Tint = 0.8,
					Radius = 0.45,
					ScaleBy = "size",
					Brightness = 12,
					Alpha = "flash",
				},
				{
					Type = "sprite",
					Texture = "ring",
					Flat = true,
					Lift = 0.05,
					Tint = 0.5,
					Radius = "shock",
					ScaleBy = "size",
					Brightness = 3,
					Alpha = "shock_fade",
				},
				{
					Type = "sprite",
					Texture = "glow",
					Flat = true,
					Lift = 0.03,
					Radius = 0.35,
					ScaleBy = "size",
					Brightness = 2,
					Alpha = function(p, v)
						return 0.35 * v.ember
					end,
				},
				{
					Type = "gpu_trail",
					Count = TRAIL_COUNT,
					Points = 48,
					Texture = "orbit_trail",
					Radius = 0.04,
					Drift = 0.3,
					Strength = 25,
					Alpha = "trail_fade",
					EndColor = function()
						return EMBER
					end,
					Init = function(p, i)
						local yaw = math.random() * math.pi * 2
						local pitch = math.randomf(0.3, 1.3)
						local speed = math.randomf(5, 12) * p.size / 6
						local flat = math.cos(pitch)
						return {
							x = p.position.x,
							y = p.position.y + 0.1,
							z = p.position.z,
							vx = math.cos(yaw) * flat * speed,
							vy = math.sin(pitch) * speed,
							vz = math.sin(yaw) * flat * speed,
						}
					end,
					Push = function(p, v, trail, d, dt)
						dt = math.min(dt, 0.05)
						local ground = p.position.y + 0.04

						if d.y > ground or d.vy > 0 then
							local drag = 1 - 0.5 * dt
							d.vy = d.vy - GRAVITY * dt
							d.vx, d.vy, d.vz = d.vx * drag, d.vy * drag, d.vz * drag
							d.x, d.y, d.z = d.x + d.vx * dt, d.y + d.vy * dt, d.z + d.vz * dt

							if d.y < ground then d.y, d.vx, d.vy, d.vz = ground, 0, 0, 0 end
						end

						trail:ShiftXYZ(d.x, d.y, d.z)
					end,
				},
			},
		}
	)
end

grenade_effects.Explode = new_event(
	"grenade_explode",
	function(position, normal, radius)
		init()
		clips.Play(
			"grenade_explosion",
			{position = position:Copy(), normal = normal, color = FIRE, size = radius}
		)
	end,
	enabled
)

function grenade_effects.StartFuse()
	init()
	return clips.Play(
		"grenade_fuse",
		{position = Vec3(), normal = UP, color = FUSE, size = 0.03, blink = 0, fade = 1},
		true
	)
end

return grenade_effects
