local new_event = import("goluwa/network/replicated_event.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local grenade_effects = {}
local FIRE = Color(1, 0.55, 0.15, 1)
local EMBER = Color(0.55, 0.08, 0.02, 1)
local FUSE = Color(1, 0.12, 0.06, 1)
local UP = Vec3(0, 1, 0)
local TRAIL_COUNT = 10
local GRAVITY = 9.8
local SOUNDS = {"weapons/explode3.wav", "weapons/explode4.wav", "weapons/explode5.wav"}
local SCORCH_RADIUS = 0.35
local SCORCH_AMOUNT = 0.35
local clips, vfx, screen_shake, sounds, render3d, surface_effects

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

local function init()
	if clips then return end

	clips = import("goluwa/render3d/clips.lua")
	vfx = import("goluwa/render3d/vfx.lua")
	screen_shake = import("lua/screen_shake.lua")
	sounds = import("lua/sounds.lua")
	render3d = import("goluwa/render3d/render3d.lua")
	surface_effects = import("goluwa/render3d/surface_effects.lua")
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
				fireball = {{0, 0.12, "outCubic"}, {0.12, 0.55}, {1, 0.75}},
				fireball_fade = {{0, 1}, {0.1, 1, "outQuad"}, {0.6, 0}},
				flash = {{0, 1, "outQuart"}, {0.14, 0}},
				shock = {{0, 0.1, "outQuart"}, {0.4, 0.85}},
				shock_fade = {{0, 1, "outQuad"}, {0.4, 0}},
				ember = {{0, 0}, {0.04, 1, "outQuad"}, {1, 0}},
				trail_fade = {{0, 1, "outQuad"}, {0.75, 0}},
			},
			Bursts = {
				grenade_fire = burst{
					Spread = 180,
					SpeedMin = 1,
					SpeedMax = 7,
					LifetimeMin = 0.25,
					LifetimeMax = 0.7,
					SizeStart = 0.18,
					SizeEnd = 0.5,
					Drag = 3,
					GravityScale = -0.5,
					Emissive = 4e5,
					SaturationJitter = 0.3,
					ColorStart = Color(1, 0.75, 0.3, 1),
					ColorEnd = Color(0.8, 0.12, 0.02, 0),
				},
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
				grenade_smoke = {
					Spread = 120,
					SpeedMin = 1.5,
					SpeedMax = 5,
					LifetimeMin = 2.5,
					LifetimeMax = 4.5,
					SizeStart = 0.5,
					SizeEnd = 2.2,
					Drag = 1.8,
					GravityScale = -0.12,
					Lit = true,
					Collision = "none",
					MaxParticles = 256,
					ColorStart = Color(0.16, 0.15, 0.14, 0.75),
					ColorEnd = Color(0.3, 0.3, 0.3, 0),
				},
				grenade_dust = {
					Spread = 85,
					SpeedMin = 4,
					SpeedMax = 9,
					LifetimeMin = 1,
					LifetimeMax = 2,
					SizeStart = 0.4,
					SizeEnd = 1.4,
					Drag = 3,
					GravityScale = 0,
					Lit = true,
					Collision = "none",
					MaxParticles = 256,
					ColorStart = Color(0.45, 0.4, 0.33, 0.5),
					ColorEnd = Color(0.5, 0.45, 0.4, 0),
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
				{0, Burst = "grenade_fire", Count = 120, Direction = "normal"},
				{0, Burst = "grenade_sparks", Count = 160, Direction = "normal"},
				{0, Burst = "grenade_embers", Count = 50, Direction = "normal"},
				{0, Burst = "grenade_smoke", Count = 36, Direction = "normal"},
				{0, Burst = "grenade_dust", Count = 40, Direction = "normal"},
				{0, Debris = "grenade_shrapnel", Count = 40, Direction = "normal"},
				{0, Debris = "grenade_chunks", Count = 14, Direction = "normal"},
				{
					0,
					function(p)
						vfx.Flash(p.position + p.normal * 0.6, FIRE, 40 * p.size * p.size, 0.6)
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
					Texture = "glow",
					Lift = 0.3,
					Tint = 0.3,
					Radius = "fireball",
					ScaleBy = "size",
					Brightness = 6,
					Alpha = "fireball_fade",
				},
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
		surface_effects.Apply("fire", position, radius * SCORCH_RADIUS, SCORCH_AMOUNT, normal)
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
