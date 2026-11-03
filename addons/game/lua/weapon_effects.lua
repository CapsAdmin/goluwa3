local new_event = import("goluwa/network/replicated_event.lua")
local Color = import("goluwa/structs/color.lua")
local clients = import("goluwa/network/clients.lua")
local data_files = import("goluwa/data_files.lua")
local weapon_effects = {}
local FLASH_LUMEN = 40
local FLASH_TIME = 0.06
local FORCE_SPEED_SCALE = 0.3
local FLASH_COLOR = Color(1, 0.65, 0.3, 1)
local TOOL_COLOR = Color(0.3, 0.7, 1, 1)
local TOOL_TRACE_TIME = 0.15
local TOOL_TRACE_RADIUS = 0.012
local PISTOL_SOUNDS = {"weapons/pistol/pistol_fire2.wav", "weapons/pistol/pistol_fire3.wav"}
local PISTOL_SPL = 140
local PISTOL_KEEP = 0.12
local vfx
local clips
local sounds
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

weapon_effects.BurstFiles = data_files.New("lua/effect_data/")
weapon_effects.BurstFiles:Remember("weapon_bursts", import("lua/effect_data/weapon_bursts.lua"))
weapon_effects.BurstNames = {"tool_hit", "muzzle_flash", "hit_position", "hit_normal"}

function weapon_effects.UpdateBursts(data)
	vfx = vfx or import("goluwa/render3d/vfx.lua")
	weapon_effects.BurstFiles:Remember("weapon_bursts", data)

	for _, name in ipairs(weapon_effects.BurstNames) do
		vfx.DefineBurst(name, burst(data_files.Realize(table.copy(data[name]))))
	end
end

function weapon_effects.ReloadBursts()
	weapon_effects.UpdateBursts(weapon_effects.BurstFiles:Read("weapon_bursts"))
end

function weapon_effects.SaveBursts()
	return weapon_effects.BurstFiles:Save("weapon_bursts")
end

local function init()
	if clips then return end

	vfx = import("goluwa/render3d/vfx.lua")
	clips = import("goluwa/render3d/clips.lua")
	Beam = import("goluwa/render3d/beam.lua")
	weapon_effects.UpdateBursts(weapon_effects.BurstFiles.Source.weapon_bursts)
	clips.Define(
		"weapon_hit",
		{
			Duration = 0,
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

weapon_effects.Init = init
weapon_effects.MuzzleFlash = new_event(
	"weapon_muzzle_flash",
	function(weapon, direction)
		init()
		local position = weapon.weapon:GetMuzzle().transform:GetWorldPosition()
		vfx.Burst("muzzle_flash", position, direction, 18)
		vfx.Flash(position, FLASH_COLOR, FLASH_LUMEN, FLASH_TIME)
		sounds = sounds or import("lua/sounds.lua")
		sounds.Play(
			PISTOL_SOUNDS[math.random(#PISTOL_SOUNDS)],
			position,
			sounds.SPLToVolume(PISTOL_SPL),
			math.randomf(0.97, 1.03),
			nil,
			nil,
			nil,
			PISTOL_KEEP
		)
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

do
	local SIGNALS = {
		clap = {build = "Clap", gain = 10 ^ (-6 / 20)},
		boom = {build = "Boom", gain = 10 ^ (6 / 20)},
	}
	local SAMPLE_RATE = 48000
	local signals

	local function audio_enabled()
		return AUDIO and CLIENT
	end

	weapon_effects.TestSound = new_event(
		"weapon_test_sound",
		function(weapon, kind)
			local signal = SIGNALS[kind]

			if not signal.registered then
				sounds = sounds or import("lua/sounds.lua")
				signals = signals or import("goluwa/audio/signals.lua")
				local data, frames = signals[signal.build](SAMPLE_RATE)
				sounds.Register("signal/" .. kind, data, frames, SAMPLE_RATE)
				signal.registered = true
			end

			sounds.Play(
				"signal/" .. kind,
				weapon.weapon:GetMuzzle().transform:GetWorldPosition(),
				signal.gain
			)
		end,
		audio_enabled,
		get_owner_client
	)
end

return weapon_effects
