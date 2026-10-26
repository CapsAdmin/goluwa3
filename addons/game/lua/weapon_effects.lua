local new_event = import("goluwa/network/replicated_event.lua")
local Color = import("goluwa/structs/color.lua")
local clients = import("goluwa/network/clients.lua")
local weapon_effects = {}
local FLASH_LUMEN = 40
local FLASH_TIME = 0.06
local FORCE_SPEED_SCALE = 0.3
local FLASH_COLOR = Color(1, 0.65, 0.3, 1)
local TOOL_COLOR = Color(0.3, 0.7, 1, 1)
local TOOL_TRACE_TIME = 0.15
local TOOL_TRACE_RADIUS = 0.012
local vfx
local clips
local Beam

local function burst(properties)
	properties.Lit = false
	properties.Collision = "none"
	properties.GravityScale = 0
	properties.MaxParticles = 256
	return properties
end

local function get_owner_client(weapon)
	return weapon.network and
		clients.GetByUniqueID(weapon.network:GetNetworkOwner()) or
		NULL
end

local function enabled()
	return RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
end

local function init()
	if clips then return end

	vfx = import("goluwa/render3d/vfx.lua")
	clips = import("goluwa/render3d/clips.lua")
	Beam = import("goluwa/render3d/beam.lua")
	vfx.DefineBurst(
		"tool_hit",
		burst{
			Spread = 50,
			SpeedMin = 0.5,
			SpeedMax = 2.5,
			LifetimeMin = 0.15,
			LifetimeMax = 0.35,
			SizeStart = 0.02,
			SizeEnd = 0,
			Drag = 3,
			Emissive = 2e5,
			ColorStart = Color(0.5, 0.85, 1, 1),
			ColorEnd = Color(0.2, 0.5, 1, 0),
		}
	)
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
	enabled,
	get_owner_client
)
weapon_effects.Hit = new_event(
	"weapon_hit",
	function(weapon, position, normal, force)
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
	enabled,
	get_owner_client
)

do
	local pool = {}
	local Trace = {}
	Trace.__index = Trace

	function Trace:Update(f)
		self.beam:SetRadius(TOOL_TRACE_RADIUS * (1 - f))
		self.beam:SetPoints(self.points)
		return true
	end

	function Trace:Remove()
		self.beam:SetVisible(false)
		pool[#pool + 1] = self
	end

	weapon_effects.ToolTrace = new_event(
		"weapon_tool_trace",
		function(weapon, position, normal)
			init()
			local trace = table.remove(pool) or
				setmetatable(
					{
						beam = Beam.New{
							Points = 2,
							Radius = TOOL_TRACE_RADIUS,
							Material = Beam.CreateMaterial(TOOL_COLOR, 40),
						},
						points = Beam.NewPoints(2),
					},
					Trace
				)
			Beam.Line(weapon.weapon:GetMuzzle().transform:GetWorldPosition(), position, trace.points)
			trace.duration = TOOL_TRACE_TIME
			trace.beam:SetVisible(true)
			vfx.AddTimed(trace)
			vfx.Burst("tool_hit", position, normal, 14)
		end,
		enabled,
		get_owner_client
	)
end

return weapon_effects
