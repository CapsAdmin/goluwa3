local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local new_event = import("goluwa/network/replicated_event.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local actors = import("lua/jrpg/actors.lua")
local effects = {}
local visual = RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
effects.Visual = visual

local function enabled()
	return visual
end

local fire_impact = new_event(
	"jrpg_impact",
	function(position, normal, type_name, strength, slash, direction)
		effects.ShowImpact(position, normal, type_name, strength, slash, direction)
	end,
	enabled
)

function effects.Impact(position, normal, type_name, strength, slash, direction)
	fire_impact(position, normal, type_name, strength, slash == true, direction or normal)
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
effects.vfx = vfx
local sprites = import("goluwa/render3d/sprites.lua")
local hitmarkers = import("lua/hitmarkers.lua")
local screen_shake = import("lua/screen_shake.lua")
local sounds = import("lua/sounds.lua")
local StatusEffects = import("lua/components/status_effects.lua")
local Health = import("lua/components/health.lua")
local WHITE = Color(1, 1, 1, 1)
local BLACK = Color(0, 0, 0, 1)
local batches

local function get_batches()
	if batches then return batches end

	batches = {
		core = sprites.GetBatch(),
		halo = sprites.GetBatch(nil, {IgnoreZ = true, OcclusionRadius = 0.3, OcclusionSoftness = 0.25}),
		flare = sprites.GetBatch(vfx.GetTexture("flare")),
		glow = sprites.GetBatch(vfx.GetTexture("glow")),
		ring = sprites.GetBatch(vfx.GetTexture("ring")),
	}
	return batches
end

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
	local LENS = {
		Additive = false,
		Translucent = true,
		Roughness = 0.02,
		Metallic = 0,
		Refraction = 1,
		IndexOfRefraction = 1.5,
		AbbeNumber = 4,
		RefractionThickness = 0.3,
		NormalMapMultiplier = 6,
	}
	local ORB = {}
	ORB.__index = ORB

	function effects.AcquireOrb(color, lens_scale)
		LENS.NormalTexture = LENS.NormalTexture or vfx.GetTexture("lens")
		return setmetatable(
			{
				core = WHITE:GetLerped(0.4, color),
				color = color,
				lens = sprites.GetBatch(vfx.GetTexture("lens_mask"), LENS, WHITE:GetLerped(0.85, color)),
				lens_scale = lens_scale,
			},
			ORB
		)
	end

	function ORB:Draw(position, size, alpha, flicker)
		if alpha <= 0.002 or size <= 0 then return end

		local x, y, z = position.x, position.y, position.z
		local b = get_batches()
		local core, color = self.core, self.color
		b.core:Add(x, y, z, size * 0.7, core.r * 8, core.g * 8, core.b * 8, alpha * alpha)
		b.halo:Add(
			x,
			y,
			z,
			size * (2.2 + math.sin(system.GetElapsedTime() * 9) * 0.2),
			color.r * 2,
			color.g * 2,
			color.b * 2,
			0.6 * flicker * alpha
		)
		b.flare:Add(
			x,
			y,
			z,
			size * 1.6 * flicker,
			color.r * 5,
			color.g * 5,
			color.b * 5,
			0.64 * alpha * alpha
		)
		self.lens:Add(x, y, z, size * 2 * self.lens_scale * alpha, 1, 1, 1, 1)
	end
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
		local key = type_name .. (speed_scale and "_fast" or "") .. (spread and "_cone" or "")

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

do
	local META = {}
	META.__index = META
	local DARK_MATERIAL = {Additive = false, Translucent = true}
	local TRAIL_LINGER = 1 / 0.6
	local TRAIL_STEP_ANGLE = 0.04
	local TRAIL_POINTS = 140

	function META:Update(f, dt)
		local entity = self.entity
		local center = self.position
		local body = center

		if entity:IsValid() then
			center = entity.transform:GetPosition()
			body = actors.GetCenter(entity)
		end

		local cx, cy, cz = center.x, center.y, center.z
		local by = body.y
		local time = f * self.duration
		local main = math.min(f * TRAIL_LINGER, 1)
		local grow = 1 - (1 - math.min(main * 4, 1)) ^ 3
		local fade = math.sin(main * math.pi) ^ 3
		local trail_fade = (math.sin(f * math.pi) ^ 3) * 0.5
		local spin = time * 0.8
		local size = self.size * 2 * grow
		local outer = self.outer.transform
		outer:SetPosition(Vec3(cx, cy + 0.03, cz))
		outer:SetRotation(Quat():Identity():RotateYaw(self.spin + spin))
		outer:SetScale(Vec3(size, 1, size))
		self.outer:SetAlpha(fade)
		local inner = self.inner.transform
		inner:SetPosition(Vec3(cx, cy + 0.035, cz))
		inner:SetRotation(Quat():Identity():RotateYaw(self.spin - spin * 1.6))
		inner:SetScale(Vec3(size, 1, size))
		self.inner:SetAlpha(fade)
		local k = self.glow_strength
		get_batches().glow:AddFlat(
			cx,
			cy + 0.02,
			cz,
			0,
			1,
			0,
			self.size * 3.2,
			self.r * k,
			self.g * k,
			self.b * k,
			0.01 * fade * fade
		)

		for i, trail in ipairs(self.trails) do
			local orbit = self.orbits[i]
			local radius = self.size * orbit.radius * 2 * grow
			local steps = math.clamp(math.ceil(orbit.speed * dt / TRAIL_STEP_ANGLE), 1, 16)
			local drift = dt * 0.6 / steps

			for step = 1, steps do
				local t = time - dt * (steps - step) / steps
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
					by + (x2 * sz + y1 * cz2) * radius,
					cz + z2 * radius,
					drift
				)
			end

			trail:SetAlpha(trail_fade)
			trail:Rebuild()
		end

		if self.pillar then
			local height = 3 * grow
			local points = self.pillar_points
			points[1]:Set(cx, cy, cz)
			points[2]:Set(cx, cy + height, cz)
			self.pillar.beam:SetRadius(self.size * 0.35 * (1 - main * 0.5))
			self.pillar.beam:SetRadiusEnd(nil)
			self.pillar:SetAlpha(fade * 0.4)
			self.pillar:SetPoints(points)
		end

		return true
	end

	function META:Remove()
		self.outer:Release()
		self.inner:Release()

		for _, trail in ipairs(self.trails) do
			trail:Release()
		end

		if self.pillar then self.pillar:Release() end
	end

	function effects.ShowMagicCircle(entity, color, size, duration, strength, pillar)
		local effect = setmetatable(
			{
				entity = entity,
				position = entity.transform:GetPosition():Copy(),
				outer = vfx.AcquireQuad(BLACK, 0, vfx.GetTexture("magic_outer"), DARK_MATERIAL),
				inner = vfx.AcquireQuad(BLACK, 0, vfx.GetTexture("magic_inner"), DARK_MATERIAL),
				trails = {},
				orbits = {},
				r = color.r,
				g = color.g,
				b = color.b,
				glow_strength = strength * 60,
				size = size,
				duration = duration * TRAIL_LINGER,
				spin = math.random() * math.pi * 2,
			},
			META
		)

		for i = 1, 3 do
			local phase = i / 8 * math.pi * 2
			local x = math.sin(phase + math.randomf(-1, 1))
			local y = math.cos(phase + math.randomf(-1, 1))
			local z = math.sin(-phase + math.randomf(-1, 1))
			local length = math.sqrt(x * x + y * y + z * z)
			local speed = math.randomf(3, 7.5)
			effect.trails[i] = vfx.AcquireTrail(color, strength * 150, TRAIL_POINTS, 0.05, vfx.GetTexture("orbit_trail"))
			effect.orbits[i] = {
				x = x / length,
				y = y / length,
				z = z / length,
				speed = speed,
				rate_x = speed * math.randomf(0.3, 1) * (math.random() < 0.5 and -1 or 1),
				rate_y = speed * math.randomf(0.3, 1) * (math.random() < 0.5 and -1 or 1),
				rate_z = speed * math.randomf(0.3, 1) * (math.random() < 0.5 and -1 or 1),
				radius = math.randomf(0.45, 0.75),
			}
		end

		if pillar then
			effect.pillar = vfx.AcquireTrail(color, strength * 30, 2, 1, vfx.GetTexture("beam"))
			effect.pillar_points = Beam.NewPoints(2)
		end

		vfx.Flash(effect.position + Vec3(0, 0.5, 0), color, 15 * strength, duration * 0.5)
		return vfx.AddTimed(effect)
	end
end

do
	local META = {}
	META.__index = META

	function META:Update(f)
		local b = get_batches()
		local grow = 1 - (1 - f) ^ 3
		local ring = self.size * (0.3 + grow * 1.7)
		local px, py, pz = self.position.x, self.position.y, self.position.z
		local r, g, bl = self.r, self.g, self.b
		local fade = (1 - f) ^ 2
		b.ring:AddFlat(
			self.ring_x,
			self.ring_y,
			self.ring_z,
			self.nx,
			self.ny,
			self.nz,
			ring,
			r * 1.5,
			g * 1.5,
			bl * 1.5,
			fade * fade
		)
		b.flare:Add(px, py, pz, self.size * 0.8 * (1 - f) ^ 0.5, r * 3, g * 3, bl * 3, fade * fade)
		b.glow:Add(px, py, pz, self.size * 0.9 * (0.5 + f), r * 0.8, g * 0.8, bl * 0.8, (1 - f) ^ 6)
		return true
	end

	function META:Remove() end

	local IMPACT_SPREAD = 55
	local SLASH_SOUNDS = {
		"weapons/blade_slice_2.wav",
		"weapons/blade_slice_3.wav",
		"weapons/blade_slice_4.wav",
	}

	function effects.ShowImpact(position, normal, type_name, strength, slash, direction)
		local definition = damage_types.Get(type_name)
		local color = definition.Color
		local tint = WHITE:GetLerped(0.4, color)
		strength = math.clamp(strength or 1, 0.3, 2)
		local count = math.floor(40 + 60 * strength)
		effects.BurstType(type_name, position, direction, count, nil, IMPACT_SPREAD)
		effects.BurstType(type_name, position, direction, math.floor(count * 0.6), 2.5, IMPACT_SPREAD)

		if definition.Debris then
			effects.BurstDebris(type_name, position, direction, math.floor(definition.Debris.Count * strength))
		end

		vfx.Flash(position + normal * 0.2, color, 30 * strength * definition.Light, 0.35)
		vfx.AddTimed(
			setmetatable(
				{
					position = position:Copy(),
					ring_x = position.x + normal.x * 0.02,
					ring_y = position.y + normal.y * 0.02,
					ring_z = position.z + normal.z * 0.02,
					nx = normal.x,
					ny = normal.y,
					nz = normal.z,
					r = tint.r,
					g = tint.g,
					b = tint.b,
					size = 0.35 * strength * definition.Glow,
					duration = 0.45,
				},
				META
			)
		)

		if slash then
			sounds.PlayRandom(SLASH_SOUNDS, position, 0.9, math.randomf(0.9, 1.2))

			if type_name == "generic" then return end
		end

		sounds.PlayRandom(definition.HitSounds, position, 0.8, 1)
	end
end

local overlays = {}

local function collect_visuals(entity, out)
	if entity.weapon then return end

	if entity.visual then out[#out + 1] = entity.visual end

	for _, child in ipairs(entity:GetChildren()) do
		collect_visuals(child, out)
	end
end

local function get_overlay(entity)
	local record = overlays[entity]

	if record then return record end

	record = {
		entity = entity,
		material = effects.AcquireOverlayMaterial(),
		rim = Color(0, 0, 0, 0),
		fill = Color(0, 0, 0, 0),
		flashes = {},
		visuals = {},
	}
	overlays[entity] = record
	return record
end

function effects.FlashOverlay(entity, color, intensity, duration)
	local flashes = get_overlay(entity).flashes
	flashes[#flashes + 1] = {color = color, intensity = intensity, duration = duration, time = 0}
end

local function set_overlay(record, material)
	for _, visual in ipairs(record.visuals) do
		if visual:IsValid() and visual.OverlayMaterial ~= material then
			visual:SetOverlayMaterial(material)
		end
	end
end

local LOW_HEALTH = 0.25
local LOW_HEALTH_COLOR = Color(1, 0.1, 0.05, 1)

local function accumulate(record, color, amount, fill)
	record.r = record.r + color.r * amount
	record.g = record.g + color.g * amount
	record.b = record.b + color.b * amount
	record.strength = record.strength + amount
	record.fill_amount = math.max(record.fill_amount, fill or 0)
end

event.AddListener("Update", "jrpg_overlays", function(dt)
	local now = system.GetElapsedTime()
	local rpg = actors.IsLocalRPG()

	for _, component in ipairs(StatusEffects.Instances) do
		if next(component.amounts) and not overlays[component.Owner] then
			get_overlay(component.Owner)
		end
	end

	if rpg then
		for _, health in ipairs(Health.Instances) do
			if
				health.Health > 0 and
				health:GetFraction() < LOW_HEALTH and
				not overlays[health.Owner]
			then
				get_overlay(health.Owner)
			end
		end
	end

	for entity, record in pairs(overlays) do
		if not entity:IsValid() then
			effects.ReleaseOverlayMaterial(record.material)
			overlays[entity] = nil
		else
			record.r, record.g, record.b, record.strength, record.fill_amount = 0, 0, 0, 0, 0

			for i = #record.flashes, 1, -1 do
				local flash = record.flashes[i]
				flash.time = flash.time + dt

				if flash.time >= flash.duration then
					table.remove(record.flashes, i)
				else
					local f = 1 - flash.time / flash.duration
					accumulate(record, flash.color, flash.intensity * f * f, flash.fill and flash.fill * f or 0)
				end
			end

			local statuses = entity.status_effects

			if statuses then
				for name, amount in pairs(statuses.amounts) do
					local definition = status_effects.Registered[name]
					local pulse = definition.Fill and 1 or 0.6 + 0.4 * math.sin(now * 6)

					if definition.Flicker then pulse = math.random() ^ 3 * 2 end

					accumulate(
						record,
						definition.Color,
						math.min(amount, 1) * pulse * 1.5,
						definition.Fill and definition.Fill * math.min(amount * 1.5, 1)
					)
				end
			end

			local health = entity.health

			if rpg and health and health.Health > 0 and health:GetFraction() < LOW_HEALTH then
				local f = health:GetFraction() / LOW_HEALTH
				local rate = (1 - f) * 10 + 1
				local t = 1 - (now * rate) % 1
				accumulate(record, LOW_HEALTH_COLOR, t ^ 0.5 * 1.2)
			end

			if record.strength < 0.01 then
				if record.applied then
					set_overlay(record, nil)
					record.applied = false
				end

				if not record.flashes[1] then
					effects.ReleaseOverlayMaterial(record.material)
					overlays[entity] = nil
				end
			else
				local strength = record.strength
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
			end
		end
	end
end)

function effects.ShowDamage(entity, type_name, amount, max_health)
	if not entity:IsValid() then return end

	if not actors.IsLocalRPG() then return end

	local definition = damage_types.Get(type_name)
	local fraction = math.abs(amount) / math.max(max_health, 1)
	effects.FlashOverlay(
		entity,
		definition.Color,
		0.6 + math.min(fraction * 6, 1.5),
		math.clamp(math.abs(amount) / 50, 0.35, 1.5)
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

	local function get_record(component)
		local record = records[component]

		if record then return record end

		record = {emitters = {}}
		records[component] = record
		return record
	end

	local function remove_emitter(record, name)
		local emitter = record.emitters[name]
		emitter.particle_emitter_gpu:SetPlaying(false)
		vfx.RemoveDelayed(emitter, 2)
		record.emitters[name] = nil
		emitter_count = emitter_count - 1
	end

	event.AddListener("Update", "jrpg_status_visuals", function(dt)
		local now = system.GetElapsedTime()

		for component, record in pairs(records) do
			if not component:IsValid() then
				for name in pairs(record.emitters) do
					remove_emitter(record, name)
				end

				records[component] = nil
			end
		end

		for _, component in ipairs(StatusEffects.Instances) do
			local entity = component.Owner
			local record = get_record(component)
			local center = actors.GetCenter(entity)
			local pose = entity.character_pose
			local animation_speed = 1

			for name, amount in pairs(component.amounts) do
				local definition = status_effects.Registered[name]

				if definition.AnimationSpeed then
					animation_speed = math.min(animation_speed, definition.AnimationSpeed(amount))
				end

				if definition.Particles then
					local emitter = record.emitters[name]

					if not emitter and emitter_count < EMITTER_BUDGET then
						emitter_count = emitter_count + 1
						local properties = effects.GetParticleProperties(definition, {Shape = "sphere", ShapeSize = Vec3(0.3, 0.6, 0.3)})
						properties.Playing = true
						properties.MaxParticles = 256
						emitter = vfx.CreateEmitter("jrpg_status_" .. name, properties)
						record.emitters[name] = emitter
					end

					if emitter then
						emitter.transform:SetPosition(center:Copy())
						local rate = SPAWN_RATE * math.min(amount, 1)

						if definition.Flicker then rate = rate * (math.random() > 0.6 and 3 or 0) end

						emitter.particle_emitter_gpu:SetRate(rate)
					end
				end
			end

			if pose then pose.animation_speed = animation_speed end

			for name in pairs(record.emitters) do
				if not component.amounts[name] then remove_emitter(record, name) end
			end

			local confused = component.amounts.confused

			if confused then
				local color = status_effects.Registered.confused.Color
				local top_y = center.y + (
						entity.character_movement and
						entity.character_movement:GetHeight() or
						1.6
					) * 0.55
				local alpha = math.min(confused * 2, 1)
				local flare = get_batches().flare

				for i = 1, 3 do
					local angle = now * 4 + i * math.pi * 2 / 3
					flare:Add(
						center.x + math.cos(angle) * 0.25,
						top_y + math.sin(now * 3 + i) * 0.04,
						center.z + math.sin(angle) * 0.25,
						0.06,
						color.r * 3,
						color.g * 3,
						color.b * 3,
						alpha * alpha
					)
				end
			end
		end
	end)
end

return effects
