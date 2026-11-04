local players = import("lua/players.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local new_event = import("goluwa/network/replicated_event.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local actors = import("lua/actors.lua")
local data_files = import("goluwa/data_files.lua")
local effects = {}
local visual = RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
effects.Visual = visual

local function enabled()
	return visual
end

local fire_impact = new_event(
	"jrpg_impact",
	function(position, normal, type_name, strength, cut, direction, damage)
		effects.ShowImpact(position, normal, type_name, strength, cut, direction, damage)
	end,
	enabled
)

function effects.Impact(position, normal, type_name, strength, cut, direction, damage)
	fire_impact(
		position,
		normal,
		type_name,
		strength,
		cut or false,
		direction or normal,
		damage or false
	)
end

effects.HitOverlay = new_event(
	"jrpg_hit_overlay",
	function(entity, type_name)
		effects.ShowHitOverlay(entity, type_name)
	end,
	enabled
)
effects.Damage = new_event(
	"jrpg_damage",
	function(entity, type_name, amount, max_health, raw_amount, position)
		effects.ShowDamage(entity, type_name, amount, max_health, raw_amount, position)
	end,
	enabled
)
effects.Text = new_event(
	"jrpg_text",
	function(entity, text, color)
		effects.ShowText(entity, text, color)
	end,
	enabled
)
effects.Block = new_event(
	"jrpg_block",
	function(entity, position, normal, broken)
		effects.ShowBlock(entity, position, normal, broken)
	end,
	enabled
)
effects.LevelUp = new_event(
	"jrpg_level_up",
	function(entity, level)
		effects.ShowLevelUp(entity, level)
	end,
	enabled
)
effects.Stagger = new_event(
	"jrpg_stagger",
	function(victim, attacker, hitstop, direction)
		effects.ShowStagger(victim, attacker, hitstop, direction)
	end,
	enabled
)

if not visual then return effects end

local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Beam = import("goluwa/render3d/beam.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local clips = import("goluwa/render3d/clips.lua")
local screen_fields = import("goluwa/render3d/screen_fields.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
effects.vfx = vfx
vfx.ClearBursts("jrpg_")
local sprites = import("goluwa/render3d/sprites.lua")
local hitmarkers = import("lua/hitmarkers.lua")
local particle_shader_library = import("lua/particle_shader_library.lua")
local emitters = import("lua/emitters.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
particle_shader_library.Init()
local screen_shake = import("lua/screen_shake.lua")
local sounds = import("lua/sounds.lua")
local StatusEffects = import("lua/components/status_effects.lua")
local Health = import("lua/components/health.lua")
local Rpg = import("lua/components/rpg.lua")
local WHITE = Color(1, 1, 1, 1)
local effect_exposure = import("lua/jrpg/effect_exposure.lua")

for category, amount in pairs(effect_exposure) do
	vfx.SetExposureCompensation(category, amount)
end

do
	local overlay_materials = {}

	function effects.AcquireOverlayMaterial()
		return table.remove(overlay_materials) or
			Material.New{
				Translucent = true,
				ColorMultiplier = Color(0, 0, 0, 0),
				RimColor = Color(0, 0, 0, 0),
				RimPower = 2.6,
				OcclusionRadius = 0.2,
				OcclusionSoftness = 0.1,
			}
	end

	function effects.ReleaseOverlayMaterial(material)
		overlay_materials[#overlay_materials + 1] = material
	end
end

do
	function effects.GetParticles(definition)
		local particles = table.shallow_copy(definition.ParticleBase or {})

		if definition.Particles.Emitter then
			table.merge(particles, emitters.Get(definition.Particles.Emitter))
		end

		table.merge(particles, definition.Particles)
		particles.Emitter = nil
		return particles
	end

	function effects.GetParticleProperties(definition, overrides)
		local properties = {
			MaxParticles = 512,
			Playing = false,
			Rate = 0,
			Lit = false,
			Collision = "none",
			Emissive = 2.5e5,
			SaturationJitter = 0.35,
			Color = {
				Keys = {
					{0, Color(definition.Color.r, definition.Color.g, definition.Color.b, 1)},
					{
						1,
						Color(
							(definition.EndColor or definition.Color).r,
							(definition.EndColor or definition.Color).g,
							(definition.EndColor or definition.Color).b,
							0
						),
					},
				},
			},
		}

		for key, value in pairs(effects.GetParticles(definition)) do
			properties[key] = value
		end

		for key, value in pairs(overrides or {}) do
			properties[key] = value
		end

		return properties
	end

	local DEFAULT_SHADER_PREVIEW = {Emitter = "shader_preview", Offset = {0, 1, 0}}

	function effects.PlayParticleShader(position, name, preview)
		preview = table.merge(table.copy(DEFAULT_SHADER_PREVIEW), preview or {})
		local properties = emitters.Get(preview.Emitter)
		properties.Shader = name
		properties.ShaderParams = table.merge(table.copy(particle_shader_library.GetDefaults(name)), preview.ShaderParams or {})
		local emitter = vfx.CreateEmitter("jrpg_shader_" .. name, properties)
		emitter.transform:SetPosition(position + Vec3(unpack(preview.Offset)))

		timer.Delay(preview.Duration or 3, function()
			if emitter:IsValid() then
				emitter.particle_emitter_gpu:SetPlaying(false)
				vfx.RemoveDelayed(emitter, 4)
			end
		end)

		return emitter
	end

	local SPARK_SIZE = 0.012
	local SPARK_GRAVITY = 0.3
	local CUT_DRAG = 4
	local CUT_FIZZLE = 1
	local CUT_FIZZLE_START = 0.55
	local CUT_LIFETIME_SCALE = 4
	local CUT_GRAVITY = 0.03
	local CUT_FLOW = 0.5
	local CUT_FLOW_SCALE = 1
	local debris_emitters = {}
	local debris_materials = {}

	function effects.CreateDebrisEmitter(type_name, settings)
		local definition = damage_types.Get(type_name)

		if not debris_materials[type_name] then
			local config = table.merge({Color = definition.Color}, definition.Debris.Material)

			if type(config.AlbedoTexture) == "string" then
				config.AlbedoTexture = vfx.GetTexture(config.AlbedoTexture)
			end

			debris_materials[type_name] = Material.New(config)
		end

		local entity = Entity.New{
			Name = "jrpg_debris_" .. type_name,
			transform = {},
			particle_emitter_cpu = table.merge(
				{
					Material = debris_materials[type_name],
					Playing = false,
					Rate = 0,
					MaxParticles = 128,
					Shape = "point",
				},
				settings
			),
		}
		entity:SetTransient(true)
		return entity
	end

	function effects.BurstDebris(type_name, position, direction, count)
		local entity = debris_emitters[type_name]

		if not entity or not entity:IsValid() then
			entity = effects.CreateDebrisEmitter(type_name, damage_types.Get(type_name).Debris.Emitter)
			debris_emitters[type_name] = entity
		end

		entity.particle_emitter_cpu:BurstAt(count, position, direction)
	end

	function effects.ResetType(type_name)
		vfx.ClearBursts("jrpg_" .. type_name)
		local emitter = debris_emitters[type_name]

		if emitter and emitter:IsValid() then emitter:Remove() end

		debris_emitters[type_name] = nil
		debris_materials[type_name] = nil
	end

	function effects.BurstType(type_name, position, direction, count, speed_scale, spread, cut, cut_scale)
		local key = "jrpg_" .. type_name .. (
				speed_scale and
				"_fast" or
				""
			) .. (
				spread and
				"_cone" .. spread or
				""
			) .. (
				cut and
				"_cut" or
				""
			) .. (
				cut_scale and
				"_s" .. cut_scale or
				""
			)

		if not vfx.HasBurst(key) then
			local definition = damage_types.Get(type_name)
			local color = definition.Color
			local overrides = {
				Spread = spread,
				Size = {Keys = {{0, SPARK_SIZE}, {1, 0}}},
				Sparkle = 1,
				GravityScale = SPARK_GRAVITY,
				Color = {
					Keys = {{0, WHITE:GetLerped(0.4, color)}, {1, Color(color.r, color.g, color.b, 0)}},
				},
			}
			local speed = (speed_scale or 1) * (cut_scale or 1)
			local particles = effects.GetParticles(definition)

			if speed ~= 1 then
				overrides.Speed = particle_emitter.ScaleRange(particles.Speed, speed)
			end

			if cut then
				overrides.MaxParticles = 1024
				overrides.GravityScale = CUT_GRAVITY
				overrides.Flow = CUT_FLOW * (cut_scale or 1)
				overrides.FlowScale = CUT_FLOW_SCALE
				overrides.Drag = CUT_DRAG
				overrides.Fizzle = CUT_FIZZLE
				overrides.FizzleStart = CUT_FIZZLE_START
				overrides.Lifetime = particle_emitter.ScaleRange(particles.Lifetime, CUT_LIFETIME_SCALE * (cut_scale or 1))
			end

			vfx.DefineBurst(key, effects.GetParticleProperties(definition, overrides))
		end

		vfx.Burst(key, position, direction, count)
	end
end

local TRAIL_LINGER = 1 / 0.6
local TRAIL_STEP_ANGLE = 0.04
clips.RegisterScript(
	"jrpg_magic_circle",
	{
		Follow = function(p)
			clips.FollowEntity(p)
			p.body_y = p.entity:IsValid() and actors.GetCenter(p.entity).y or p.position.y
		end,
	}
)
clips.RegisterScript(
	"jrpg_magic_orbits",
	{
		Init = function(p, i)
			local phase = i / 8 * math.pi * 2
			local x = math.sin(phase + math.randomf(-1, 1))
			local y = math.cos(phase + math.randomf(-1, 1))
			local z = math.sin(-phase + math.randomf(-1, 1))
			local length = math.sqrt(x * x + y * y + z * z)
			local speed = math.randomf(3, 7.5)
			return {
				x = x / length,
				y = y / length,
				z = z / length,
				speed = speed,
				rate_x = speed * math.randomf(0.3, 1) * (math.random() < 0.5 and -1 or 1),
				rate_y = speed * math.randomf(0.3, 1) * (math.random() < 0.5 and -1 or 1),
				rate_z = speed * math.randomf(0.3, 1) * (math.random() < 0.5 and -1 or 1),
				radius = math.randomf(0.45, 0.75),
			}
		end,
		Push = function(p, v, trail, orbit, dt)
			local position = p.position
			local cx, cz = position.x, position.z
			local radius = p.size * orbit.radius * v.diameter
			local steps = math.clamp(math.ceil(orbit.speed * dt / TRAIL_STEP_ANGLE), 1, 16)

			for step = 1, steps do
				local t = v.time - dt * (steps - step) / steps
				local ax, ay, az = t * orbit.rate_x, t * orbit.rate_y, t * orbit.rate_z
				local sx, cx2, sy, cy2, sz, cz2 = math.sin(ax),
				math.cos(ax),
				math.sin(ay),
				math.cos(ay),
				math.sin(az),
				math.cos(az)
				local y1 = orbit.y * cx2 - orbit.z * sx
				local z1 = orbit.y * sx + orbit.z * cx2
				local x2 = orbit.x * cy2 + z1 * sy
				local z2 = -orbit.x * sy + z1 * cy2
				trail:ShiftXYZ(
					cx + (x2 * cz2 - y1 * sz) * radius,
					p.body_y + (x2 * sz + y1 * cz2) * radius,
					cz + z2 * radius
				)
			end
		end,
	}
)
clips.RegisterScript(
	"jrpg_magic_pillar",
	{
		Setup = function(p, state)
			state.pillar = vfx.AcquireBeam(p.color, p.strength * 30, 1, vfx.GetTexture("beam"))
			state.points = Beam.NewPoints(2)
		end,
		Update = function(p, v, state)
			local position = p.position
			state.points[1]:Set(position.x, position.y, position.z)
			state.points[2]:Set(position.x, position.y + 1.5 * v.diameter, position.z)
			state.pillar:SetRadius(p.size * 0.35 * (1 - v.main * 0.5))
			state.pillar:SetAlpha(v.fade * 0.4)
			state.pillar:SetPoints(state.points)
		end,
		Remove = function(p, state)
			state.pillar:Release()
		end,
	}
)

function effects.ShowMagicCircle(entity, color, size, duration, strength, pillar)
	return clips.Play(
		"jrpg_magic_circle",
		{
			entity = entity,
			position = entity.transform:GetPosition():Copy(),
			color = color,
			size = size,
			strength = strength,
			pillar = pillar,
			cast_time = duration,
			duration = duration * TRAIL_LINGER,
			spin = math.random() * math.pi * 2,
		}
	)
end

local IMPACT_SPREAD = 55
local SLASH_SPREAD = 2
local SLASH_DAMAGE = 40
local SLASH_MIN_SCALE = 0.025
local SLASH_MAX_SCALE = 2
local SLASH_SOUNDS = {
	"weapons/blade_slice_2.wav",
	"weapons/blade_slice_3.wav",
	"weapons/blade_slice_4.wav",
}
clips.RegisterScript(
	"jrpg_impact_bursts",
	{
		Event = function(p)
			local spread = p.cut and SLASH_SPREAD or IMPACT_SPREAD
			local sides = p.cut and 2 or 1

			for side = 1, sides do
				local direction = side == 1 and p.direction or p.direction * -1
				effects.BurstType(
					p.type_name,
					p.position,
					direction,
					math.floor(p.count / sides),
					nil,
					spread,
					p.cut,
					p.cut_bucket
				)
				effects.BurstType(
					p.type_name,
					p.position,
					direction,
					math.floor(p.count * 0.6 / sides),
					2.5,
					spread,
					p.cut,
					p.cut_bucket
				)
			end

			if p.debris then
				effects.BurstDebris(p.type_name, p.position, p.direction, p.debris)
			end
		end,
	}
)

do
	local files = data_files.New(
		"lua/jrpg/clips/",
		{"Duration", "Loop", "Follow", "Tracks", "Events", "Layers", "Type", "Preview"}
	)
	effects.ClipFiles = files
	effects.ClipNames = {"orb", "projectile", "impact", "magic_circle", "blade_trail"}

	function effects.UpdateClip(name, data)
		files:Remember(name, data)
		clips.Define("jrpg_" .. name, data)
	end

	function effects.ReloadClip(name)
		effects.UpdateClip(name, files:Read(name))
	end

	function effects.SaveClip(name)
		return files:Save(name)
	end

	for _, name in ipairs(effects.ClipNames) do
		effects.UpdateClip(name, import("lua/jrpg/clips/" .. name .. ".lua"))
	end
end

function effects.ShowImpact(position, normal, type_name, strength, cut, direction, damage)
	local definition = damage_types.Get(type_name)
	local cut_scale = math.clamp((damage or SLASH_DAMAGE) / SLASH_DAMAGE, SLASH_MIN_SCALE, SLASH_MAX_SCALE)
	strength = math.clamp(strength or 1, 0.3, 2)
	clips.Play(
		"jrpg_impact",
		{
			position = position:Copy(),
			normal = normal,
			direction = direction,
			cut = cut or nil,
			cut_bucket = cut and
				2 ^ math.floor(math.log(math.max(cut_scale, 0.125)) / math.log(2) + 0.5)
				or
				nil,
			type_name = type_name,
			color = definition.Color,
			size = 0.35 * strength * definition.Glow,
			count = math.floor(40 + 60 * strength),
			debris = definition.Debris and math.floor(definition.Debris.Count * strength),
			lumen = 30 * strength * definition.Light,
		}
	)

	if cut then
		sounds.PlayRandom(SLASH_SOUNDS, position, 0.9, math.randomf(0.9, 1.2))

		if definition.Physical or type_name == "generic" then return end
	end

	sounds.PlayRandom(definition.HitSounds, position, 0.8, 1)
end

local overlays = {}

local function collect_visuals(entity, out)
	if entity.weapon then return end

	if entity.visual then out[#out + 1] = entity.visual end

	for _, child in ipairs(entity:GetChildren()) do
		collect_visuals(child, out)
	end
end

local HIT_OVERLAY = {Duration = 0.35, FadeIn = 0.05, FadeOut = 0.5, Intensity = 0.8}

function effects.ShowHitOverlay(entity, type_name)
	if not entity:IsValid() then return end

	local definition = damage_types.Get(type_name)
	local config = HIT_OVERLAY

	if not definition.Physical then
		config = table.shallow_copy(HIT_OVERLAY)
		config.ColorA = definition.Color
	end

	local visuals = {}
	collect_visuals(entity, visuals)

	for _, visual in ipairs(visuals) do
		surface_overlays.Add(visual, definition.Overlay, config)
	end
end

function effects.PlayOverlay(entity, kind, config)
	local visuals = {}
	local handles = {}
	collect_visuals(entity, visuals)

	for _, visual in ipairs(visuals) do
		handles[#handles + 1] = surface_overlays.Add(visual, kind, config)
	end

	return handles
end

local function set_overlay(record, material)
	for _, visual in ipairs(record.visuals) do
		if visual:IsValid() and visual.OverlayMaterial ~= material then
			visual:SetOverlayMaterial(material)
		end
	end
end

function effects.AddOverlay(entity, color, amount, fill)
	local record = overlays[entity]

	if not record then
		record = {
			entity = entity,
			material = effects.AcquireOverlayMaterial(),
			rim = Color(0, 0, 0, 0),
			fill = Color(0, 0, 0, 0),
			visuals = {},
			r = 0,
			g = 0,
			b = 0,
			strength = 0,
			fill_amount = 0,
		}
		overlays[entity] = record
	end

	record.r = record.r + color.r * amount
	record.g = record.g + color.g * amount
	record.b = record.b + color.b * amount
	record.strength = record.strength + amount
	record.fill_amount = math.max(record.fill_amount, fill)
end

event.AddListener("LateUpdate", "jrpg_overlays", function()
	for entity, record in pairs(overlays) do
		local strength = record.strength

		if not entity:IsValid() or strength < 0.01 then
			if record.applied and entity:IsValid() then set_overlay(record, nil) end

			effects.ReleaseOverlayMaterial(record.material)
			overlays[entity] = nil
		else
			local inverse = 1 / strength
			record.rim:Set(
				record.r * inverse * 3,
				record.g * inverse * 3,
				record.b * inverse * 3,
				math.min(strength, 1) * 0.85
			)
			record.fill:Set(record.r * inverse, record.g * inverse, record.b * inverse, record.fill_amount)
			record.material:SetRimColor(record.rim)
			record.material:SetColorMultiplier(record.fill)
			record.material:Touch()
			local children = entity:GetChildrenList()

			if record.source ~= children then
				record.source = children
				table.clear(record.visuals)
				collect_visuals(entity, record.visuals)
				record.applied = false
			end

			if not record.applied then
				set_overlay(record, record.material)
				record.applied = true
			end

			record.r, record.g, record.b, record.strength, record.fill_amount = 0, 0, 0, 0, 0
		end
	end
end)

clips.RegisterScript(
	"jrpg_flash",
	{
		Update = function(p, v)
			effects.AddOverlay(p.entity, p.color, p.intensity * v.decay, 0)
		end,
	}
)
effects.ClipNames[#effects.ClipNames + 1] = "flash"
effects.UpdateClip("flash", import("lua/jrpg/clips/flash.lua"))

do
	local LOW_HEALTH = 0.25
	local LOW_HEALTH_COLOR = Color(1, 0.1, 0.05, 1)
	local low_health_clips = {}
	clips.RegisterScript(
		"jrpg_low_health",
		{
			Update = function(p)
				local f = p.health:GetFraction() / LOW_HEALTH
				local rate = (1 - f) * 10 + 1
				local t = 1 - (system.GetElapsedTime() * rate) % 1
				effects.AddOverlay(p.entity, LOW_HEALTH_COLOR, t ^ 0.5 * 1.2, 0)
			end,
		}
	)
	effects.ClipNames[#effects.ClipNames + 1] = "low_health"
	effects.UpdateClip("low_health", import("lua/jrpg/clips/low_health.lua"))

	event.AddListener("Update", "jrpg_low_health", function()
		local rpg = Rpg.IsLocal()

		for health, clip in pairs(low_health_clips) do
			if not health:IsValid() then
				clip:Stop()
				low_health_clips[health] = nil
			end
		end

		for _, health in ipairs(Health.Instances) do
			local low = rpg and health.Health > 0 and health:GetFraction() < LOW_HEALTH
			local clip = low_health_clips[health]

			if low and not clip then
				low_health_clips[health] = clips.Play("jrpg_low_health", {entity = health.Owner, health = health})
			elseif clip and not low then
				clip:Stop()
				low_health_clips[health] = nil
			end
		end
	end)
end

function effects.ShowDamage(entity, type_name, amount, max_health, raw_amount, position)
	if not entity:IsValid() then return end

	local definition = damage_types.Get(type_name)
	local fraction = math.abs(amount) / math.max(max_health, 1)

	if Rpg.IsLocal() then
		clips.Play(
			"jrpg_flash",
			{
				entity = entity,
				color = definition.Color,
				intensity = 0.6 + math.min(fraction * 6, 1.5),
				duration = math.clamp(math.abs(amount) / 50, 0.35, 1.5),
			}
		)

		if players.IsLocal(entity) and amount > 0 then
			screen_shake.Add(math.min(fraction * 0.6, 0.12), 1, 0.4)
		end
	end

	hitmarkers.Add(
		entity,
		raw_amount,
		max_health,
		system.GetElapsedTime(),
		position,
		definition.Color
	)
end

function effects.ShowText(entity, text, color)
	if entity:IsValid() then
		hitmarkers.AddText(entity, text, color, system.GetElapsedTime())
	end
end

function effects.ShowBlock(entity, position, normal, broken)
	local key = broken and "jrpg_shield_break" or "jrpg_block"

	if not vfx.HasBurst(key) then
		vfx.DefineBurst(
			key,
			{
				MaxParticles = 256,
				Lit = false,
				Spread = 50,
				Speed = {1, broken and 6 or 4},
				Lifetime = {0.15, 0.5},
				Size = {Keys = {{0, 0.02}, {1, 0}}},
				Drag = 1.5,
				GravityScale = 0.8,
				Emissive = 4e5,
				Color = {Keys = {{0, Color(1, 0.95, 0.8, 1)}, {1, Color(1, 0.6, 0.2, 0)}}},
			}
		)
	end

	vfx.Burst(key, position, normal, broken and 80 or 30)
	vfx.Flash(position + normal * 0.2, Color(1, 0.9, 0.7, 1), broken and 40 or 15, 0.2)
	sounds.Play(
		broken and
			"physics/glass/glass_largesheet_break3.wav" or
			"physics/metal/metal_solid_impact_bullet" .. math.random(1, 4) .. ".wav",
		position,
		0.8,
		broken and 1 or math.randomf(0.9, 1.2)
	)

	if broken then
		effects.ShowText(entity, "GUARD BREAK", Color(1, 0.4, 0.3, 1))
	end
end

local PUNCH_DISTANCE = 6
local PUNCH_ZOOM = 0.07
local PUNCH_BLUR = 45
local PUNCH_ABERRATION = 8

function effects.ShowStagger(victim, attacker, hitstop, direction)
	if not victim:IsValid() then return end

	local center = actors.GetCenter(victim)
	vfx.Flash(center, Color(1, 0.95, 0.85, 1), 25, 0.15)
	sounds.Play(
		"physics/body/body_medium_impact_hard" .. math.random(1, 6) .. ".wav",
		center,
		0.9,
		math.randomf(0.8, 1)
	)
	local rig = players.GetLocal()

	if rig and (rig == victim or rig == attacker) then
		local camera = render3d.GetCamera()
		local amplitude = 0.06 + hitstop * 0.4

		if rig == victim then
			screen_shake.Add(amplitude, 1.4, 0.3)
		else
			local local_direction = camera:GetRotation():GetConjugated():VecMul(direction)
			local length = math.sqrt(local_direction.x ^ 2 + local_direction.y ^ 2)

			if length > 1e-3 then
				screen_shake.Add(amplitude, 1.4, 0.3, local_direction.x / length, local_direction.y / length)
			end
		end

		local strength = math.clamp(hitstop / 0.16, 0.5, 1)
		screen_fields.Add{
			Position = rig == victim and
				camera:GetPosition() + camera:GetRotation():GetForward() * PUNCH_DISTANCE or
				center,
			Duration = 0.4,
			Attack = 0.2,
			Radius = 200,
			Expand = false,
			Thickness = 1,
			Zoom = PUNCH_ZOOM * strength,
			Blur = PUNCH_BLUR * strength,
			Aberration = PUNCH_ABERRATION * strength,
		}
	end
end

function effects.ShowLevelUp(entity, level)
	if not entity:IsValid() then return end

	local gold = Color(1, 0.8, 0.35, 1)
	effects.ShowMagicCircle(entity, gold, 1.1, 2.5, 1.6, true)
	effects.ShowText(entity, "LEVEL UP", gold)
	sounds.Play(
		"garrysmod/save_load" .. math.random(1, 4) .. ".wav",
		entity.transform:GetPosition(),
		1,
		1
	)
end

do
	local records = {}
	local SPAWN_RATE = 70
	local EMITTER_BUDGET = 16
	local emitter_count = 0

	local function release_status_overlays(state)
		for _, handle in ipairs(state.handles) do
			handle:Remove()
		end

		table.clear(state.handles)
		table.clear(state.visuals)
	end

	local layers = {
		{
			Update = function(p, v, state)
				local children = p.entity:GetChildrenList()

				if state.source ~= children then
					state.source = children
					release_status_overlays(state)
					collect_visuals(p.entity, state.visuals)

					for _, visual in ipairs(state.visuals) do
						state.handles[#state.handles + 1] = surface_overlays.Add(visual, p.definition.Overlay, {ColorA = p.color, Intensity = state.intensity})
					end
				end

				local intensity = math.min(p.amount, 1)

				if math.abs(intensity - state.intensity) > 0.01 then
					state.intensity = intensity

					for _, handle in ipairs(state.handles) do
						handle:SetIntensity(intensity)
					end
				end
			end,
			Remove = function(p, state)
				release_status_overlays(state)
			end,
			Setup = function(p, state)
				state.handles = {}
				state.visuals = {}
				state.intensity = math.min(p.amount, 1)
			end,
		},
		{
			When = "particles",
			Update = function(p, v, state)
				local definition = p.definition
				local emitter = state.emitter

				if emitter and state.emitter_definition ~= definition then
					emitter.particle_emitter_gpu:SetPlaying(false)
					vfx.RemoveDelayed(emitter, 2)
					emitter_count = emitter_count - 1
					emitter = nil
					state.emitter = nil
				end

				if not emitter and emitter_count < EMITTER_BUDGET then
					emitter_count = emitter_count + 1
					local shape = {
						Shape = "sphere",
						ShapeSize = p.entity.ragdoll and Vec3(0.12, 0.12, 0.12) or Vec3(0.3, 0.6, 0.3),
					}

					for key in pairs(effects.GetParticles(definition)) do
						shape[key] = nil
					end

					local properties = effects.GetParticleProperties(definition, shape)
					properties.Playing = true
					properties.MaxParticles = 256
					emitter = vfx.CreateEmitter("jrpg_status_" .. definition.Name, properties)
					state.emitter = emitter
					state.emitter_definition = definition
				end

				if emitter then
					local parts = p.entity.ragdoll and p.entity.ragdoll.parts
					emitter.transform:SetPosition(
						parts and
							parts[1] and
							table.random(parts).body:GetPosition() or
							p.position:Copy()
					)
					local rate = SPAWN_RATE * math.min(p.amount, 1)

					if definition.Flicker then rate = rate * (math.random() > 0.6 and 3 or 0) end

					emitter.particle_emitter_gpu:SetRate(rate)
				end
			end,
			Remove = function(p, state)
				if state.emitter then
					state.emitter.particle_emitter_gpu:SetPlaying(false)
					vfx.RemoveDelayed(state.emitter, 2)
					emitter_count = emitter_count - 1
				end
			end,
		},
	}

	for i = 1, 3 do
		layers[#layers + 1] = {
			Type = "sprite",
			Texture = "flare",
			When = "orbit",
			Radius = 0.06,
			Brightness = 3,
			Alpha = function(p)
				local alpha = math.min(p.amount * 2, 1)
				return alpha * alpha
			end,
			Offset = function(p, v)
				local angle = v.time * 4 + i * math.pi * 2 / 3
				return math.cos(angle) * 0.25,
				p.height * 0.55 + math.sin(v.time * 3 + i) * 0.04,
				math.sin(angle) * 0.25
			end,
		}
	end

	clips.Define(
		"jrpg_status",
		{
			Duration = math.huge,
			EndWithEntity = true,
			Follow = function(p)
				local center = actors.GetCenter(p.entity)
				p.position:Set(center.x, center.y, center.z)
				p.height = p.entity.character_movement and p.entity.character_movement:GetHeight() or 1.6
			end,
			Layers = layers,
		}
	)

	event.AddListener("Update", "jrpg_status_visuals", function()
		for component, record in pairs(records) do
			if not component:IsValid() then records[component] = nil end
		end

		for _, component in ipairs(StatusEffects.Instances) do
			local entity = component.Owner
			local record = records[component]

			if not record then
				record = {}
				records[component] = record
			end

			local pose = entity.character_pose
			local animation_speed = 1

			for name, amount in pairs(component.amounts) do
				local definition = status_effects.Registered[name]

				if definition.AnimationSpeed then
					animation_speed = math.min(animation_speed, definition.AnimationSpeed(amount))
				end

				local clip = record[name]

				if not clip then
					clip = clips.Play(
						"jrpg_status",
						{
							entity = entity,
							definition = definition,
							color = definition.Color,
							amount = amount,
							particles = definition.Particles,
							orbit = definition.Orbit,
							position = Vec3(),
						}
					)
					record[name] = clip
				end

				clip.params.amount = amount
			end

			if pose then pose.animation_speed = animation_speed end

			for name, clip in pairs(record) do
				if not component.amounts[name] then
					clip:Stop()
					record[name] = nil
				end
			end
		end
	end)
end

return effects
