local new_event = import("goluwa/network/replicated_event.lua")
local Color = import("goluwa/structs/color.lua")
local clients = import("goluwa/network/clients.lua")
local emitters = import("lua/emitters.lua")
local impacts = import("lua/impacts.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local weapon_effects = {}
local FORCE_SPEED_SCALE = 0.3
local TOOL_COLOR = Color(0.3, 0.7, 1, 1)
local TOOL_TRACE_TIME = 0.15
local TOOL_TRACE_RADIUS = 0.012
local IMPACT_SPL = 105
local IMPACT_KEEP = 0.08
local vfx
local clips
local sounds
local sprites
local sound_profiles
local Beam
weapon_effects.Muzzles = {}

function weapon_effects.RegisterMuzzle(name, config)
	config.SPL = config.SPL or 140
	config.Keep = config.Keep or 0.12
	config.Size = config.Size or 1
	config.Lumen = config.Lumen or 40
	config.Color = config.Color or Color(1, 0.65, 0.3, 1)
	config.Pitch = config.Pitch or 0.03
	weapon_effects.Muzzles[name] = config
end

weapon_effects.RegisterMuzzle(
	"pistol",
	{
		Sounds = {"weapons/alyx_gun/alyx_gun_fire5.wav", "weapons/alyx_gun/alyx_gun_fire6.wav"},
	}
)

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
	sprites = import("goluwa/render3d/sprites.lua")
	sounds = import("lua/sounds.lua")
	sound_profiles = import("lua/sound_profiles.lua")
	Beam = import("goluwa/render3d/beam.lua")
	clips.Define(
		"weapon_hit",
		{
			Duration = 0,
			Events = {
				{0, Emitter = "hit_position", Count = 24, Direction = "normal"},
				{0, Emitter = "hit_normal", Count = 16, Direction = "normal"},
				{
					0,
					Emitter = "hit_force",
					Count = 16,
					Direction = "force_direction",
					When = "force_direction",
					Inputs = {Strength = "speed"},
				},
			},
		}
	)
	event.AddListener("Update", "weapon_effects", weapon_effects.Draw)
end

weapon_effects.Init = init
local MUZZLE_TIME = 0.05
local TRACER_SPEED = 220
local TRACER_LENGTH = 2.2
local TRACER_WIDTH = 0.014
local TRACER_BRIGHTNESS = 150
local MAX_HOLES = 256
local HOLE_RADIUS = 0.045
local HOLE_LIFT = 0.004
local HOLE_FADE = 2
local HOLE_LIFE = 120
local HOLE_MATERIAL = {
	Additive = false,
	Translucent = true,
	Unlit = false,
	VertexTint = true,
	SimpleLighting = true,
	Roughness = 1,
	Metallic = 0,
}
local muzzles = {}
local tracers = {}
local holes = {}
local hole_cursor = 0
local tracer_pool = {}

local function hole_is_live(hole, now)
	return hole.time + HOLE_LIFE > now and (not hole.entity or hole.entity:IsValid())
end

function weapon_effects.Draw(dt)
	local now = system.GetElapsedTime()
	local flash_batch = sprites.GetBatch(vfx.GetTexture("muzzle_flash"))
	local flame_batch = sprites.GetBatch(vfx.GetTexture("muzzle_flame"))
	local tracer_batch = sprites.GetBatch(vfx.GetTexture("tracer"))

	for i = #muzzles, 1, -1 do
		local m = muzzles[i]
		local age = now - m.time

		if age > MUZZLE_TIME or not m.node:IsValid() then
			table.remove(muzzles, i)
		else
			local f = 1 - age / MUZZLE_TIME
			local position = m.node.transform:GetWorldPosition()
			local d = m.direction
			local size = m.size
			local c = m.color
			local brightness = m.brightness * f
			flash_batch:Add(
				position.x + d.x * size * 0.03,
				position.y + d.y * size * 0.03,
				position.z + d.z * size * 0.03,
				size * 0.055,
				c.r * brightness,
				c.g * brightness,
				c.b * brightness,
				f,
				nil,
				m.roll
			)
			flame_batch:AddStreak(
				position.x + d.x * size * 0.08,
				position.y + d.y * size * 0.08,
				position.z + d.z * size * 0.08,
				d.x,
				d.y,
				d.z,
				size * 0.08,
				size * 0.03,
				c.r * brightness,
				c.g * brightness,
				c.b * brightness,
				f
			)
		end
	end

	for i = #tracers, 1, -1 do
		local t = tracers[i]
		t.age = t.age + dt
		local travelled = t.age * TRACER_SPEED
		local head = math.min(travelled, t.distance)
		local tail = math.max(travelled - TRACER_LENGTH, 0)

		if tail >= t.distance then
			tracers[i] = tracers[#tracers]
			tracers[#tracers] = nil
			tracer_pool[#tracer_pool + 1] = t
		else
			local middle = (head + tail) * 0.5
			local s, d = t.start, t.direction
			tracer_batch:AddStreak(
				s.x + d.x * middle,
				s.y + d.y * middle,
				s.z + d.z * middle,
				d.x,
				d.y,
				d.z,
				(head - tail) * 0.5,
				TRACER_WIDTH,
				TRACER_BRIGHTNESS,
				TRACER_BRIGHTNESS * 0.8,
				TRACER_BRIGHTNESS * 0.5,
				1
			)
		end
	end

	if hole_cursor == 0 and not holes[1] then return end

	local hole_batch = sprites.GetBatch(vfx.GetTexture("bullet_hole"), HOLE_MATERIAL)

	for i = 1, #holes do
		local h = holes[i]

		if h.time > 0 and hole_is_live(h, now) then
			local alpha = math.min((h.time + HOLE_LIFE - now) / HOLE_FADE, 1)
			local x, y, z, nx, ny, nz = h.x, h.y, h.z, h.nx, h.ny, h.nz
			local ux, uy, uz = h.ux, h.uy, h.uz

			if h.entity then
				local m = h.entity.transform:GetWorldMatrix()
				x, y, z = x * m.m00 + y * m.m10 + z * m.m20 + m.m30,
				x * m.m01 + y * m.m11 + z * m.m21 + m.m31,
				x * m.m02 + y * m.m12 + z * m.m22 + m.m32
				nx, ny, nz = nx * m.m00 + ny * m.m10 + nz * m.m20,
				nx * m.m01 + ny * m.m11 + nz * m.m21,
				nx * m.m02 + ny * m.m12 + nz * m.m22
				ux, uy, uz = ux * m.m00 + uy * m.m10 + uz * m.m20,
				ux * m.m01 + uy * m.m11 + uz * m.m21,
				ux * m.m02 + uy * m.m12 + uz * m.m22
				local length = math.sqrt(nx * nx + ny * ny + nz * nz)
				nx, ny, nz = nx / length, ny / length, nz / length
			end

			hole_batch:AddFlat(
				x + nx * HOLE_LIFT,
				y + ny * HOLE_LIFT,
				z + nz * HOLE_LIFT,
				nx,
				ny,
				nz,
				h.radius,
				1,
				1,
				1,
				alpha,
				ux,
				uy,
				uz
			)
		end
	end
end

local function add_hole(position, normal, target, size)
	hole_cursor = hole_cursor % MAX_HOLES + 1
	local h = holes[hole_cursor]

	if not h then
		h = {}
		holes[hole_cursor] = h
	end

	local angle = math.randomf(0, math.pi * 2)
	local ux, uy, uz = math.cos(angle), math.sin(angle), math.cos(angle * 3 + 1)
	h.x, h.y, h.z = position.x, position.y, position.z
	h.nx, h.ny, h.nz = normal.x, normal.y, normal.z
	h.ux, h.uy, h.uz = ux, uy, uz
	h.radius = HOLE_RADIUS * size * math.randomf(0.85, 1.15)
	h.time = system.GetElapsedTime()
	h.entity = nil
	local body = target:IsValid() and target.rigid_body

	if body and not body:IsStatic() then
		local m = target.transform:GetWorldMatrixInverse()
		h.entity = target
		h.x, h.y, h.z = m:TransformVectorUnpacked(position.x, position.y, position.z)
		h.nx, h.ny, h.nz = normal.x * m.m00 + normal.y * m.m10 + normal.z * m.m20,
		normal.x * m.m01 + normal.y * m.m11 + normal.z * m.m21,
		normal.x * m.m02 + normal.y * m.m12 + normal.z * m.m22
		h.ux, h.uy, h.uz = ux * m.m00 + uy * m.m10 + uz * m.m20,
		ux * m.m01 + uy * m.m11 + uz * m.m21,
		ux * m.m02 + uy * m.m12 + uz * m.m22
	end
end

local function add_tracer(start, finish)
	local t = table.remove(tracer_pool) or {start = Vec3(), direction = Vec3()}
	local dx, dy, dz = finish.x - start.x, finish.y - start.y, finish.z - start.z
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

	if distance < 0.5 then
		tracer_pool[#tracer_pool + 1] = t
		return
	end

	t.start:Set(start.x, start.y, start.z)
	t.direction:Set(dx / distance, dy / distance, dz / distance)
	t.distance = distance
	t.age = 0
	tracers[#tracers + 1] = t
end

function weapon_effects.GetSurface(hit)
	return hit.entity and hit.entity.rigid_body and impacts.GetSurface(hit) or "default"
end

weapon_effects.MuzzleFlash = new_event(
	"weapon_muzzle_flash",
	function(weapon, direction, kind)
		init()
		local config = weapon_effects.Muzzles[kind]
		local node = weapon.weapon:GetMuzzle()
		local position = node.transform:GetWorldPosition()
		emitters.Burst("muzzle_flash", position, direction, math.ceil(18 * config.Size))
		vfx.Flash(position, config.Color, config.Lumen * config.Size, 0.06)
		muzzles[#muzzles + 1] = {
			node = node,
			direction = direction:Copy(),
			time = system.GetElapsedTime(),
			size = config.Size * math.randomf(0.85, 1.15),
			color = config.Color,
			brightness = config.Brightness or 14,
			roll = math.randomf(0, math.pi * 2),
		}

		if config.Sounds then
			sounds.Play(
				config.Sounds[math.random(#config.Sounds)],
				position,
				sounds.SPLToVolume(config.SPL),
				math.randomf(1 - config.Pitch, 1 + config.Pitch),
				nil,
				nil,
				nil,
				config.Keep
			)
		end
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

local function bullet(weapon, position, normal, force, target, surface, size)
	init()
	add_tracer(weapon.weapon:GetMuzzle().transform:GetWorldPosition(), position)
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
	local paths = sound_profiles.Get().GetBulletImpact(surface)
	sounds.Play(
		paths[math.random(#paths)],
		position,
		sounds.SPLToVolume(IMPACT_SPL),
		math.randomf(0.95, 1.05),
		nil,
		nil,
		nil,
		IMPACT_KEEP
	)

	if not (target:IsValid() and (target.health or target.ragdoll_part)) then
		add_hole(position, normal, target, size)
	end
end

weapon_effects.Bullet = new_event("weapon_bullet", bullet, enabled, get_owner_client)
weapon_effects.Tracer = new_event(
	"weapon_tracer",
	function(weapon, position)
		init()
		add_tracer(weapon.weapon:GetMuzzle().transform:GetWorldPosition(), position)
	end,
	enabled,
	get_owner_client
)

function weapon_effects.CountHoles()
	return #holes
end

function weapon_effects.ClearHoles()
	for i = #holes, 1, -1 do
		holes[i] = nil
	end

	hole_cursor = 0
end

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
			emitters.Burst("tool_hit", position, normal, 14)
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

do
	local surface_conditions

	local function visual_enabled()
		return RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
	end

	function weapon_effects.GetSurfaceConditionNames()
		local names = {}

		if not visual_enabled() then return names end

		surface_conditions = surface_conditions or import("goluwa/render3d/surface_conditions.lua")

		for _, kind in ipairs(surface_conditions.kinds) do
			names[#names + 1] = kind.name
		end

		return names
	end

	weapon_effects.TestSurfaceCondition = new_event(
		"weapon_test_surface_condition",
		function(kind, position, normal, radius, amount)
			surface_conditions = surface_conditions or import("goluwa/render3d/surface_conditions.lua")
			surface_conditions.Apply(kind, position, radius, amount, normal)
		end,
		visual_enabled
	)
	weapon_effects.ClearSurfaceConditions = new_event(
		"weapon_clear_surface_conditions",
		function()
			surface_conditions = surface_conditions or import("goluwa/render3d/surface_conditions.lua")
			surface_conditions.Clear()
		end,
		visual_enabled
	)
end

return weapon_effects
