local new_event = import("goluwa/network/replicated_event.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local grenade_effects = {}
local FIRE = Color(1, 0.55, 0.15, 1)
local EMBER = Color(0.55, 0.08, 0.02, 1)
local FUSE = Color(1, 0.12, 0.06, 1)
local FLASH_HOT = Color(1, 0.85, 0.55, 1)
local FLASH_COOL = Color(1, 0.3, 0.08, 1)
local UP = Vec3(0, 1, 0)
local TRAIL_COUNT = 10
local GRAVITY = 9.8
local SOUNDS = {"weapons/explode3.wav", "weapons/explode4.wav", "weapons/explode5.wav"}
local clips, vfx, screen_shake, sounds, render3d, puffs, screen_fields, raycast

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

local PUFF_STYLES = {
	{
		Flipbook = "fire",
		Count = 12,
		Spawn = 0.25,
		Lift = 0.5,
		Speed = {1.5, 4},
		Drag = 3,
		Buoyancy = 1,
		Life = {0.45, 0.8},
		Delay = 0,
		RadiusStart = 0.5,
		RadiusEnd = 1.5,
		Grow = 2.2,
		From = {1, 0.9, 0.6},
		To = {1, 0.55, 0.2},
		ColorCurve = 0.7,
		Brightness = 9,
		FadeIn = 0.05,
		FadeStart = 0.25,
	},
	{
		Flipbook = "fire",
		Count = 34,
		Spawn = 0.5,
		Lift = 0.5,
		Speed = {3, 8},
		Drag = 2.6,
		Buoyancy = 2,
		Life = {0.8, 1.5},
		Delay = 0.03,
		RadiusStart = 0.8,
		RadiusEnd = 2.2,
		Grow = 2,
		From = {1, 0.5, 0.1},
		To = {0.45, 0.06, 0.01},
		ColorCurve = 0.6,
		Brightness = 4,
		FadeIn = 0.08,
		FadeStart = 0.4,
	},
	{
		Flipbook = "smoke",
		Count = 34,
		Spawn = 0.9,
		Lift = 1,
		Speed = {2, 5},
		Drag = 1.6,
		Buoyancy = 1.8,
		Life = {3.5, 5.5},
		Delay = 0.35,
		RadiusStart = 1,
		RadiusEnd = 3,
		Grow = 1.4,
		From = {0.045, 0.04, 0.036},
		To = {0.16, 0.156, 0.151},
		ColorCurve = 0.6,
		Brightness = 1,
		FadeIn = 0.1,
		FadeStart = 0.5,
	},
	{
		Flipbook = "smoke",
		Flat = true,
		Count = 22,
		Spawn = 0.3,
		Lift = 0.15,
		Speed = {5, 9},
		Drag = 3.5,
		Buoyancy = 0.2,
		Life = {1.2, 2},
		Delay = 0,
		RadiusStart = 0.5,
		RadiusEnd = 1.6,
		Grow = 1.6,
		From = {0.5, 0.43, 0.33},
		To = {0.55, 0.5, 0.42},
		ColorCurve = 1,
		Brightness = 1,
		FadeIn = 0.1,
		FadeStart = 0.45,
	},
}
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

local function spawn_arms_and_trails(position, ax, ay, az, k, floor)
	local ox, oy, oz = position.x + ax * 0.4 * k, position.y + ay * 0.4 * k, position.z + az * 0.4 * k

	for i = 1, 10 do
		local dx, dy, dz, open = pick_open_direction(ax, ay, az, 0.3)
		puffs.SpawnStreak{
			Flipbook = "fire",
			X = ox,
			Y = oy,
			Z = oz,
			DX = dx,
			DY = dy,
			DZ = dz,
			Delay = 0,
			Life = math.randomf(0.35, 0.6),
			Reach = math.randomf(5, 9) * k * math.min(open * 1.3, 1),
			Grow = 2.5,
			TailStart = 0.15,
			TailEnd = 0.9,
			Rise = 0.6 * k,
			WidthStart = 0.26 * k,
			WidthEnd = 0.12 * k,
			R0 = 1,
			G0 = 0.5,
			B0 = 0.15,
			R1 = 1,
			G1 = 0.18,
			B1 = 0.03,
			ColorCurve = 0.7,
			Brightness = 2.6,
			FadeIn = 0.05,
			FadeStart = 0.4,
			Fps = math.randomf(12, 20),
			Offset = math.random(0, 63),
		}
	end

	for i = 1, 6 do
		local dx, dy, dz, open = pick_open_direction(ax, ay, az, 0.4)
		dx, dy, dz = dx + ax * 0.6, dy + ay * 0.6, dz + az * 0.6
		local length = math.sqrt(dx * dx + dy * dy + dz * dz)
		local speed = math.randomf(7, 12) * k * (0.4 + 0.6 * open)
		puffs.SpawnStreamer{
			X = ox,
			Y = oy,
			Z = oz,
			VX = dx / length * speed,
			VY = dy / length * speed,
			VZ = dz / length * speed,
			Drag = 0.4,
			Gravity = GRAVITY,
			Floor = floor,
			Delay = 0,
			Life = math.randomf(0.8, 1.7),
			Interval = 0.018,
			Jitter = 0.4 * k,
			HeadRadius = 0.28 * k,
			HeadR = 3,
			HeadG = 1.2,
			HeadB = 0.3,
			Template = {
				Flipbook = "smoke",
				Drag = 1.5,
				Buoyancy = 0.8 * k,
				Floor = floor,
				Life = math.randomf(1.8, 3),
				RadiusStart = 0.18 * k,
				RadiusEnd = 0.5 * k,
				Grow = 1.3,
				R0 = 0.245,
				G0 = 0.223,
				B0 = 0.2,
				R1 = 0.223,
				G1 = 0.223,
				B1 = 0.223,
				ColorCurve = 1,
				Brightness = 1,
				FadeIn = 0.1,
				FadeStart = 0.3,
				Spin = math.randomf(-0.6, 0.6),
				Fps = 14,
			},
		}
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

local function spawn_smoke_columns(position, ax, ay, az, k, floor)
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
		local life = math.randomf(kind.life[1], kind.life[2])
		puffs.SpawnStreamer{
			X = position.x + ax * 0.25 * k,
			Y = position.y + ay * 0.25 * k,
			Z = position.z + az * 0.25 * k,
			VX = mx / length * speed,
			VY = my / length * speed,
			VZ = mz / length * speed,
			Drag = kind.drag,
			Gravity = kind.gravity * k,
			Floor = nil,
			Delay = math.randomf(0, 0.15),
			Life = life,
			Interval = 0.1,
			Jitter = 0.4 * k,
			HeadRadius = 0,
			HeadR = 0,
			HeadG = 0,
			HeadB = 0,
			Template = {
				Flipbook = "smoke",
				Drag = 1.2,
				Buoyancy = kind.buoyancy * k,
				Floor = floor,
				Life = math.randomf(2, 3.5),
				RadiusStart = 0.375 * k,
				RadiusEnd = math.randomf(0.875, 1.75) * k,
				Grow = 1.2,
				R0 = 0.2,
				G0 = 0.185,
				B0 = 0.17,
				R1 = 0.2,
				G1 = 0.2,
				B1 = 0.2,
				ColorCurve = 1,
				Brightness = 1,
				FadeIn = 0.15,
				FadeStart = 0.4,
				Spin = math.randomf(-0.5, 0.5),
				Fps = 14,
			},
		}
	end
end

local function spawn_fireball(position, normal, size)
	local k = size / 6 * 1.7
	local nx, ny, nz = normal.x, normal.y, normal.z
	local floor = ny > 0.7 and position.y + 0.1 or nil
	local ax, ay, az = trace_blast(position, normal, size * 1.5)

	for _, style in ipairs(PUFF_STYLES) do
		local lift = style.Lift * k

		for i = 1, style.Count do
			local dx, dy, dz = random_direction(ax, ay, az)

			if style.Flat then
				local along = dx * nx + dy * ny + dz * nz
				dx, dy, dz = dx - along * nx, dy - along * ny, dz - along * nz
				local length = math.sqrt(dx * dx + dy * dy + dz * dz)
				dx, dy, dz = dx / length, dy / length, dz / length
			end

			local reach = style.Spawn * k * math.random()
			local speed = math.randomf(style.Speed[1], style.Speed[2]) * k * (
					0.35 + 0.65 * openness_at(dx, dy, dz)
				)
			puffs.Spawn{
				Flipbook = style.Flipbook,
				X = position.x + ax * lift + dx * reach,
				Y = position.y + ay * lift + dy * reach,
				Z = position.z + az * lift + dz * reach,
				VX = dx * speed,
				VY = dy * speed,
				VZ = dz * speed,
				Drag = style.Drag,
				Buoyancy = style.Buoyancy * k,
				Floor = floor,
				Delay = math.randomf(0, style.Delay),
				Life = math.randomf(style.Life[1], style.Life[2]),
				RadiusStart = style.RadiusStart * k * math.randomf(0.75, 1.15),
				RadiusEnd = style.RadiusEnd * k * math.randomf(0.75, 1.15),
				Grow = style.Grow,
				R0 = style.From[1],
				G0 = style.From[2],
				B0 = style.From[3],
				R1 = style.To[1],
				G1 = style.To[2],
				B1 = style.To[3],
				ColorCurve = style.ColorCurve,
				Brightness = style.Brightness,
				FadeIn = style.FadeIn,
				FadeStart = style.FadeStart,
				Roll = math.randomf(0, math.pi * 2),
				Spin = math.randomf(-0.5, 0.5),
				Fps = math.randomf(12, 20),
				Offset = math.random(0, 63),
			}
		end
	end

	spawn_arms_and_trails(position, ax, ay, az, k, floor)
	spawn_smoke_columns(position, ax, ay, az, k, floor)
end

local function init()
	if clips then return end

	clips = import("goluwa/render3d/clips.lua")
	puffs = import("goluwa/render3d/puffs.lua")
	screen_fields = import("goluwa/render3d/screen_fields.lua")
	vfx = import("goluwa/render3d/vfx.lua")
	screen_shake = import("lua/screen_shake.lua")
	sounds = import("lua/sounds.lua")
	render3d = import("goluwa/render3d/render3d.lua")
	raycast = import("goluwa/render3d/raycast.lua")
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
						sounds.PlayRandom(SOUNDS, p.position, 1, math.randomf(0.9, 1.1))
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
