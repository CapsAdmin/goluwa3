local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local new_event = import("goluwa/network/replicated_event.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local actors = import("lua/actors.lua")
local surface_hazards = import("lua/jrpg/surface_hazards.lua")
local effects = {}
local visual = RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
effects.Visual = visual

local function enabled()
	return visual
end

local fire_impact = new_event(
	"jrpg_impact",
	function(position, normal, type_name, strength, cut, direction)
		effects.ShowImpact(position, normal, type_name, strength, cut, direction)
	end,
	enabled
)

function effects.Impact(position, normal, type_name, strength, cut, direction)
	fire_impact(position, normal, type_name, strength, cut or false, direction or normal)
	local surface = damage_types.Get(type_name).Surface

	if surface then
		surface_hazards.Apply(
			surface.Kind,
			position,
			surface.Radius * math.clamp(strength or 1, 0.3, 2),
			surface.Amount,
			normal
		)
	end
end

effects.Damage = new_event(
	"jrpg_damage",
	function(entity, type_name, amount, max_health)
		effects.ShowDamage(entity, type_name, amount, max_health)
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

if not visual then return effects end

local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Beam = import("goluwa/render3d/beam.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local clips = import("goluwa/render3d/clips.lua")
effects.vfx = vfx
local sprites = import("goluwa/render3d/sprites.lua")
local hitmarkers = import("lua/hitmarkers.lua")
local screen_shake = import("lua/screen_shake.lua")
local sounds = import("lua/sounds.lua")
local StatusEffects = import("lua/components/status_effects.lua")
local Health = import("lua/components/health.lua")
local Rpg = import("lua/components/rpg.lua")
local WHITE = Color(1, 1, 1, 1)

do
	local MAGIC_COMMON = [[
		float line(float d, float w) {
			return 1.0 - smoothstep(0.0, w, abs(d));
		}

		float hash(float n) {
			return fract(sin(n * 12.9898) * 43758.5453);
		}
	]]
	vfx.RegisterTexture(
		"magic_outer",
		MAGIC_COMMON .. [[
		vec4 shade(vec2 uv, vec3 _cube_dir) {
			vec2 p = uv * 2.0 - 1.0;
			float r = length(p);
			float a = atan(p.y, p.x) / 6.2831853 + 0.5;
			float v = line(r - 0.97, 0.014);
			v += line(r - 0.91, 0.008);
			v += line(r - 0.64, 0.008);
			v += step(0.91, r) * step(r, 0.97) * smoothstep(0.38, 0.48, abs(fract(a * 72.0) - 0.5));
			float fa = fract(a * 32.0);
			float fr = fract((r - 0.68) / 0.06);
			float lit = step(0.45, hash(floor(a * 32.0) * 7.0 + floor((r - 0.68) / 0.06) * 31.0));
			v += step(0.68, r) * step(r, 0.86) * lit * step(0.18, fa) * step(fa, 0.82) * step(0.2, fr) * step(fr, 0.8) * 0.85;
			v = clamp(v, 0.0, 1.0) * (1.0 - smoothstep(0.98, 1.0, r));
			return vec4(vec3(v), v);
		}
	]]
	)
	vfx.RegisterTexture(
		"magic_inner",
		MAGIC_COMMON .. [[
		vec4 shade(vec2 uv, vec3 _cube_dir) {
			vec2 p = uv * 2.0 - 1.0;
			float r = length(p);
			float v = line(r - 0.58, 0.006) * 0.8;
			v += line(r - 0.22, 0.006) * 0.7;

			for (int i = 0; i < 6; i++) {
				float a0 = float(i) * 1.0471976;
				float a1 = float(i + 2) * 1.0471976;
				vec2 s0 = vec2(cos(a0), sin(a0)) * 0.58;
				vec2 d = vec2(cos(a1), sin(a1)) * 0.58 - s0;
				float h = clamp(dot(p - s0, d) / dot(d, d), 0.0, 1.0);
				v += line(length(p - s0 - d * h), 0.008);
			}

			v += exp(-r * r * 10.0) * 0.35;
			v = clamp(v, 0.0, 1.0) * (1.0 - smoothstep(0.62, 0.66, r));
			return vec4(vec3(v), v);
		}
	]]
	)
	vfx.RegisterTexture(
		"feather",
		MAGIC_COMMON .. [[
		vec4 shade(vec2 uv, vec3 _cube_dir) {
			vec2 p = vec2(uv.x * 2.0 - 1.0, uv.y);
			float ax = abs(p.x);
			float width = pow(max(sin(3.14159 * pow(clamp(p.y, 0.0, 1.0), 0.7)), 0.0), 0.6) * 0.92;
			float ragged = width * (0.82 + 0.18 * hash(floor(p.y * 48.0) + (p.x > 0.0 ? 17.0 : 0.0)));
			float inside = step(ax, ragged);
			float spine = step(ax, 0.045);
			float barb = abs(fract(p.y * 30.0 - ax * 6.0) - 0.5) * 2.0;
			float shade = mix(0.78, 1.0, barb);
			return vec4(vec3(mix(shade, 1.0, spine)), inside);
		}
	]]
	)
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
	function effects.GetParticleProperties(definition, overrides)
		local properties = {
			MaxParticles = 512,
			Playing = false,
			Rate = 0,
			Lit = false,
			Collision = "none",
			Emissive = 2.5e5,
			SaturationJitter = 0.35,
			ColorStart = Color(definition.Color.r, definition.Color.g, definition.Color.b, 1),
			ColorEnd = Color(
				(definition.EndColor or definition.Color).r,
				(definition.EndColor or definition.Color).g,
				(definition.EndColor or definition.Color).b,
				0
			),
		}

		for key, value in pairs(definition.Particles) do
			properties[key] = value
		end

		for key, value in pairs(overrides or {}) do
			properties[key] = value
		end

		return properties
	end

	local SPARK_SIZE = 0.012
	local SPARK_GRAVITY = 0.3
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

	function effects.BurstType(type_name, position, direction, count, speed_scale, spread)
		local key = type_name .. (
				speed_scale and
				"_fast" or
				""
			) .. (
				spread and
				"_cone" .. spread or
				""
			)

		if not vfx.HasBurst(key) then
			local definition = damage_types.Get(type_name)
			local color = definition.Color
			local overrides = {
				Spread = spread,
				SizeStart = SPARK_SIZE,
				SizeEnd = 0,
				Sparkle = 1,
				GravityScale = SPARK_GRAVITY,
				ColorStart = WHITE:GetLerped(0.4, color),
				ColorEnd = Color(color.r, color.g, color.b, 0),
			}

			if speed_scale then
				overrides.SpeedMin = definition.Particles.SpeedMin * speed_scale
				overrides.SpeedMax = definition.Particles.SpeedMax * speed_scale
			end

			vfx.DefineBurst(key, effects.GetParticleProperties(definition, overrides))
		end

		vfx.Burst(key, position, direction, count)
	end
end

local TRAIL_LINGER = 1 / 0.6
local TRAIL_STEP_ANGLE = 0.04
local TRAIL_POINTS = 140
local DARK_MATERIAL = {Additive = false, Translucent = true}
clips.Define(
	"jrpg_orb",
	{
		Duration = math.huge,
		Layers = {
			{
				Type = "orb",
				Size = "size",
				Alpha = "alpha",
				Flicker = "flicker",
				LensScale = "lens_scale",
			},
		},
	}
)
clips.Define(
	"jrpg_projectile",
	{
		Duration = math.huge,
		Layers = {
			{
				Type = "orb",
				Size = "size",
				Alpha = "fade",
				Flicker = "flicker",
				LensScale = "lens_scale",
			},
			{
				Type = "gpu_trail",
				Points = 20,
				Texture = "orbit_trail",
				Strength = 20,
				Radius = function(p)
					return p.trail_radius
				end,
				Alpha = "fade",
			},
		},
	}
)
clips.Define(
	"jrpg_magic_circle",
	{
		Duration = 2,
		Follow = function(p)
			clips.FollowEntity(p)
			p.body_y = p.entity:IsValid() and actors.GetCenter(p.entity).y or p.position.y
		end,
		Tracks = {
			main = {{0, 0}, {0.6, 1}},
			diameter = {{0, 0, "outCubic"}, {0.15, 2}},
			fade = function(f)
				return math.sin(math.min(f * TRAIL_LINGER, 1) * math.pi) ^ 3
			end,
			trail_fade = function(f)
				return (math.sin(f * math.pi) ^ 3) * 0.5
			end,
		},
		Events = {
			{
				0,
				function(p)
					vfx.Flash(p.position + Vec3(0, 0.5, 0), p.color, 15 * p.strength, p.cast_time * 0.5)
				end,
			},
		},
		Layers = {
			{
				Type = "quad",
				Texture = "magic_outer",
				Material = DARK_MATERIAL,
				Lift = 0.03,
				Scale = "diameter",
				ScaleBy = "size",
				Yaw = function(p, v)
					return p.spin + v.time * 0.8
				end,
				Alpha = "fade",
			},
			{
				Type = "quad",
				Texture = "magic_inner",
				Material = DARK_MATERIAL,
				Lift = 0.035,
				Scale = "diameter",
				ScaleBy = "size",
				Yaw = function(p, v)
					return p.spin - v.time * 1.28
				end,
				Alpha = "fade",
			},
			{
				Type = "sprite",
				Texture = "glow",
				Flat = true,
				Lift = 0.02,
				Radius = 3.2,
				ScaleBy = "size",
				Brightness = function(p)
					return p.strength * 60
				end,
				Alpha = function(p, v)
					return 0.01 * v.fade * v.fade
				end,
			},
			{
				Type = "gpu_trail",
				Count = 3,
				Points = TRAIL_POINTS,
				Radius = 0.05,
				Texture = "orbit_trail",
				Drift = 0.6,
				Alpha = "trail_fade",
				Strength = function(p)
					return p.strength * 150
				end,
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
			},
			{
				When = "pillar",
				Setup = function(p, state)
					state.pillar = vfx.AcquireTrail(p.color, p.strength * 30, 2, 1, vfx.GetTexture("beam"))
					state.points = Beam.NewPoints(2)
				end,
				Update = function(p, v, state)
					local position = p.position
					state.points[1]:Set(position.x, position.y, position.z)
					state.points[2]:Set(position.x, position.y + 1.5 * v.diameter, position.z)
					state.pillar.beam:SetRadius(p.size * 0.35 * (1 - v.main * 0.5))
					state.pillar.beam:SetRadiusEnd(nil)
					state.pillar:SetAlpha(v.fade * 0.4)
					state.pillar:SetPoints(state.points)
				end,
				Remove = function(p, state)
					state.pillar:Release()
				end,
			},
		},
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
local SLASH_SPREAD = 6
local SLASH_RADIUS = 2.6
local SLASH_SOUNDS = {
	"weapons/blade_slice_2.wav",
	"weapons/blade_slice_3.wav",
	"weapons/blade_slice_4.wav",
}
vfx.RegisterTexture(
	"slash_arc",
	[[
	vec4 shade(vec2 uv, vec3 _cube_dir) {
		vec2 p = uv * 2.0 - 1.0;
		float x = p.x;
		float taper = pow(max(1.0 - x * x, 0.0), 1.3);
		float center = 0.32 * x * x - 0.16;
		float width = 0.1 * taper;
		float d = abs(p.y - center) / max(width, 0.0001);
		float body = 1.0 - smoothstep(0.55, 1.0, d);
		float core = (1.0 - smoothstep(0.0, 0.35, d)) * 0.8;
		float v = clamp(body * 0.7 + core, 0.0, 1.0) * step(abs(x), 1.0) * smoothstep(0.0, 0.04, taper);
		return vec4(vec3(v), v);
	}
]]
)
clips.Define(
	"jrpg_impact",
	{
		Duration = 0.45,
		Tracks = {
			ring = {{0, 0.3, "outCubic"}, {1, 2}},
			flare = {
				{
					0,
					0.8,
					function(f)
						return 1 - (1 - f) ^ 0.5
					end,
				},
				{1, 0},
			},
			glow = {{0, 0.45}, {1, 1.35}},
			fade = {{0, 1, "outQuart"}, {1, 0}},
			slash_fade = {{0, 1}, {0.25, 0.85}, {1, 0}},
			glow_fade = {
				{
					0,
					1,
					function(f)
						return 1 - (1 - f) ^ 6
					end,
				},
				{1, 0},
			},
		},
		Events = {
			{
				0,
				function(p)
					local spread = p.cut and SLASH_SPREAD or IMPACT_SPREAD
					effects.BurstType(p.type_name, p.position, p.direction, p.count, nil, spread)
					effects.BurstType(
						p.type_name,
						p.position,
						p.direction,
						math.floor(p.count * 0.6),
						2.5,
						spread
					)

					if p.debris then
						effects.BurstDebris(p.type_name, p.position, p.direction, p.debris)
					end

					vfx.Flash(p.position + p.normal * 0.2, p.color, p.lumen, 0.35)
				end,
			},
		},
		Layers = {
			{
				Type = "sprite",
				Texture = "ring",
				Flat = true,
				Lift = 0.02,
				Tint = 0.4,
				Radius = "ring",
				ScaleBy = "size",
				Brightness = 1.5,
				Alpha = function(p, v)
					return p.cut and 0 or v.fade
				end,
			},
			{
				Type = "sprite",
				Texture = "slash_arc",
				Flat = true,
				Axis = "cut",
				Lift = 0.03,
				Tint = 0.5,
				Radius = SLASH_RADIUS,
				ScaleBy = "size",
				Brightness = 2.5,
				Alpha = function(p, v)
					return p.cut and v.slash_fade or 0
				end,
			},
			{
				Type = "sprite",
				Texture = "flare",
				Tint = 0.4,
				Radius = "flare",
				ScaleBy = "size",
				Brightness = 3,
				Alpha = "fade",
			},
			{
				Type = "sprite",
				Texture = "glow",
				Tint = 0.4,
				Radius = "glow",
				ScaleBy = "size",
				Brightness = 0.8,
				Alpha = "glow_fade",
			},
		},
	}
)

function effects.ShowImpact(position, normal, type_name, strength, cut, direction)
	local definition = damage_types.Get(type_name)
	strength = math.clamp(strength or 1, 0.3, 2)
	clips.Play(
		"jrpg_impact",
		{
			position = position:Copy(),
			normal = normal,
			direction = direction,
			cut = cut or nil,
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

clips.Define(
	"jrpg_flash",
	{
		EndWithEntity = true,
		Tracks = {decay = {{0, 1, "outQuad"}, {1, 0}}},
		Layers = {
			{
				Update = function(p, v)
					effects.AddOverlay(p.entity, p.color, p.intensity * v.decay, 0)
				end,
			},
		},
	}
)

do
	local LOW_HEALTH = 0.25
	local LOW_HEALTH_COLOR = Color(1, 0.1, 0.05, 1)
	local low_health_clips = {}
	clips.Define(
		"jrpg_low_health",
		{
			Duration = math.huge,
			EndWithEntity = true,
			Layers = {
				{
					Update = function(p)
						local f = p.health:GetFraction() / LOW_HEALTH
						local rate = (1 - f) * 10 + 1
						local t = 1 - (system.GetElapsedTime() * rate) % 1
						effects.AddOverlay(p.entity, LOW_HEALTH_COLOR, t ^ 0.5 * 1.2, 0)
					end,
				},
			},
		}
	)

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

function effects.ShowDamage(entity, type_name, amount, max_health)
	if not entity:IsValid() then return end

	if not Rpg.IsLocal() then return end

	local definition = damage_types.Get(type_name)
	local fraction = math.abs(amount) / math.max(max_health, 1)
	clips.Play(
		"jrpg_flash",
		{
			entity = entity,
			color = definition.Color,
			intensity = 0.6 + math.min(fraction * 6, 1.5),
			duration = math.clamp(math.abs(amount) / 50, 0.35, 1.5),
		}
	)

	if entity == _G.PLAYER_RIG and amount > 0 then
		screen_shake.Add(math.min(fraction * 0.6, 0.12), 1, 0.4)
	end

	hitmarkers.Add(entity, amount, max_health, system.GetElapsedTime(), nil, definition.Color)
end

function effects.ShowText(entity, text, color)
	if entity:IsValid() then
		hitmarkers.AddText(entity, text, color, system.GetElapsedTime())
	end
end

function effects.ShowBlock(entity, position, normal, broken)
	local key = broken and "shield_break" or "block"

	if not vfx.HasBurst(key) then
		vfx.DefineBurst(
			key,
			{
				MaxParticles = 256,
				Lit = false,
				Spread = 50,
				SpeedMin = 1,
				SpeedMax = broken and 6 or 4,
				LifetimeMin = 0.15,
				LifetimeMax = 0.5,
				SizeStart = 0.02,
				SizeEnd = 0,
				Drag = 1.5,
				GravityScale = 0.8,
				Emissive = 4e5,
				ColorStart = Color(1, 0.95, 0.8, 1),
				ColorEnd = Color(1, 0.6, 0.2, 0),
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
	local layers = {
		{
			Update = function(p, v)
				local definition = p.definition
				local pulse = definition.Fill and 1 or 0.6 + 0.4 * math.sin(v.time * 6)

				if definition.Flicker then pulse = math.random() ^ 3 * 2 end

				effects.AddOverlay(
					p.entity,
					p.color,
					math.min(p.amount, 1) * pulse * 1.5,
					definition.Fill and definition.Fill * math.min(p.amount * 1.5, 1) or 0
				)
			end,
		},
		{
			When = "particles",
			Update = function(p, v, state)
				local definition = p.definition
				local emitter = state.emitter

				if not emitter and emitter_count < EMITTER_BUDGET then
					emitter_count = emitter_count + 1
					local properties = effects.GetParticleProperties(definition, {Shape = "sphere", ShapeSize = Vec3(0.3, 0.6, 0.3)})
					properties.Playing = true
					properties.MaxParticles = 256
					emitter = vfx.CreateEmitter("jrpg_status_" .. definition.Name, properties)
					state.emitter = emitter
				end

				if emitter then
					emitter.transform:SetPosition(p.position:Copy())
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
