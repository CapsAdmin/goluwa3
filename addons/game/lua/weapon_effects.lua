local new_event = import("goluwa/network/replicated_event.lua")
local Color = import("goluwa/structs/color.lua")
local weapon_effects = {}
local FLASH_LUMEN = 40
local FLASH_TIME = 0.06
local FORCE_SPEED_SCALE = 0.3
local FLASH_COLOR = Color(1, 0.65, 0.3, 1)
local vfx
local clips

local function burst(properties)
	properties.Lit = false
	properties.Collision = "none"
	properties.GravityScale = 0
	properties.MaxParticles = 256
	return properties
end

local function enabled()
	return RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
end

local function init()
	if clips then return end

	vfx = import("goluwa/render3d/vfx.lua")
	clips = import("goluwa/render3d/clips.lua")
	vfx.DefineBurst(
		"muzzle_flash",
		burst{
			Spread = 14,
			SpeedMin = 3,
			SpeedMax = 9,
			LifetimeMin = 0.03,
			LifetimeMax = 0.08,
			SizeStart = 0.035,
			SizeEnd = 0,
			Drag = 2,
			Emissive = 3e5,
			ColorStart = Color(1, 0.8, 0.4, 1),
			ColorEnd = Color(1, 0.35, 0.1, 0),
		}
	)
	clips.Define(
		"weapon_hit",
		{
			Duration = 0,
			Bursts = {
				hit_position = burst{
					Spread = 180,
					SpeedMin = 0.2,
					SpeedMax = 1,
					LifetimeMin = 0.25,
					LifetimeMax = 0.5,
					SizeStart = 0.025,
					SizeEnd = 0,
					Drag = 4,
					Emissive = 2e5,
					ColorStart = Color(1, 1, 0.7, 1),
					ColorEnd = Color(1, 0.8, 0.2, 0),
				},
				hit_normal = burst{
					Spread = 0,
					SpeedMin = 0.1,
					SpeedMax = 0.9,
					LifetimeMin = 0.9,
					LifetimeMax = 0.9,
					SizeStart = 0.015,
					SizeEnd = 0.015,
					Drag = 0,
					Emissive = 2e5,
					ColorStart = Color(0.2, 0.9, 1, 1),
					ColorEnd = Color(0.2, 0.9, 1, 0),
				},
			},
			Events = {
				{0, Burst = "hit_position", Count = 24, Direction = "normal"},
				{0, Burst = "hit_normal", Count = 16, Direction = "normal"},
				{
					0,
					function(p)
						if not p.force_direction then return end

						local key = "hit_force_" .. p.speed

						if not vfx.HasBurst(key) then
							vfx.DefineBurst(
								key,
								burst{
									Spread = 0,
									SpeedMin = 0.1,
									SpeedMax = p.speed,
									LifetimeMin = 0.9,
									LifetimeMax = 0.9,
									SizeStart = 0.015,
									SizeEnd = 0.015,
									Drag = 0,
									Emissive = 2e5,
									ColorStart = Color(1, 0.3, 0.15, 1),
									ColorEnd = Color(1, 0.3, 0.15, 0),
								}
							)
						end

						vfx.Burst(key, p.position, p.force_direction, 16)
					end,
				},
			},
		}
	)
end

weapon_effects.MuzzleFlash = new_event(
	"weapon_muzzle_flash",
	function(weapon, direction)
		init()
		local position = weapon.weapon:GetMuzzle().transform:GetWorldPosition()
		vfx.Burst("muzzle_flash", position, direction, 18)
		vfx.Flash(position, FLASH_COLOR, FLASH_LUMEN, FLASH_TIME)
	end,
	enabled
)
weapon_effects.Hit = new_event(
	"weapon_hit",
	function(position, normal, force)
		init()
		local length = force:GetLength()
		clips.Play(
			"weapon_hit",
			{
				position = position,
				normal = normal,
				force_direction = length > 0 and force / length or nil,
				speed = math.ceil(length * FORCE_SPEED_SCALE * 4) / 4,
			}
		)
	end,
	enabled
)
return weapon_effects
