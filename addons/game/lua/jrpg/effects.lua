local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local NetworkComponent = import("goluwa/entities/components/network.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local actors = import("lua/jrpg/actors.lua")
local effects = {}
local visual = RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
effects.Visual = visual

local function to_id(entity)
	return entity.network and entity.network:GetNetworkId() or -1
end

local function from_id(id)
	local component = NetworkComponent.GetByNetworkId(id)
	return component and component.Owner
end

local function broadcasting()
	return SERVER and network.IsStarted()
end

function effects.Impact(position, normal, type_name, strength, slash, direction)
	direction = direction or normal

	if broadcasting() then
		message.Broadcast(
			"jrpg_impact",
			position.x,
			position.y,
			position.z,
			normal.x,
			normal.y,
			normal.z,
			type_name,
			strength,
			slash == true,
			direction.x,
			direction.y,
			direction.z
		)
	elseif visual then
		effects.ShowImpact(position, normal, type_name, strength, slash, direction)
	end
end

function effects.Damage(entity, type_name, amount, max_health)
	if broadcasting() then
		message.Broadcast("jrpg_damage", to_id(entity), type_name, amount, max_health)
	elseif visual then
		effects.ShowDamage(entity, type_name, amount, max_health)
	end
end

function effects.Text(entity, text, color)
	if broadcasting() then
		message.Broadcast("jrpg_text", to_id(entity), text, color.r, color.g, color.b)
	elseif visual then
		effects.ShowText(entity, text, color)
	end
end

function effects.Block(entity, position, normal, broken)
	if broadcasting() then
		message.Broadcast(
			"jrpg_block",
			to_id(entity),
			position.x,
			position.y,
			position.z,
			normal.x,
			normal.y,
			normal.z,
			broken
		)
	elseif visual then
		effects.ShowBlock(entity, position, normal, broken)
	end
end

function effects.LevelUp(entity, level)
	if broadcasting() then
		message.Broadcast("jrpg_level_up", to_id(entity), level)
	elseif visual then
		effects.ShowLevelUp(entity, level)
	end
end

if CLIENT and not SERVER then
	message.AddListener("jrpg_impact", function(px, py, pz, nx, ny, nz, type_name, strength, slash, dx, dy, dz)
		effects.ShowImpact(Vec3(px, py, pz), Vec3(nx, ny, nz), type_name, strength, slash, Vec3(dx, dy, dz))
	end)

	message.AddListener("jrpg_damage", function(id, type_name, amount, max_health)
		local entity = from_id(id)

		if entity then effects.ShowDamage(entity, type_name, amount, max_health) end
	end)

	message.AddListener("jrpg_text", function(id, text, r, g, b)
		local entity = from_id(id)

		if entity then effects.ShowText(entity, text, Color(r, g, b, 1)) end
	end)

	message.AddListener("jrpg_block", function(id, px, py, pz, nx, ny, nz, broken)
		local entity = from_id(id)

		if entity then
			effects.ShowBlock(entity, Vec3(px, py, pz), Vec3(nx, ny, nz), broken)
		end
	end)

	message.AddListener("jrpg_level_up", function(id, level)
		local entity = from_id(id)

		if entity then effects.ShowLevelUp(entity, level) end
	end)
end

if not visual then return effects end

local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Beam = import("goluwa/render3d/beam.lua")
local hitmarkers = import("lua/hitmarkers.lua")
local screen_shake = import("lua/screen_shake.lua")
local sounds = import("lua/sounds.lua")
local StatusEffects = import("lua/components/status_effects.lua")
local Health = import("lua/components/health.lua")
local UP = Vec3(0, 1, 0)
local WHITE = Color(1, 1, 1, 1)

do
	local textures = {}
	local MAGIC_COMMON = [[
		float line(float d, float w) {
			return 1.0 - smoothstep(0.0, w, abs(d));
		}

		float hash(float n) {
			return fract(sin(n * 12.9898) * 43758.5453);
		}
	]]
	local GLSL = {
		magic_outer = MAGIC_COMMON .. [[
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
		]],
		magic_inner = MAGIC_COMMON .. [[
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
		]],
		glow = [[
			float r = length(uv * 2.0 - 1.0);
			float v = exp(-r * r * 5.0) * (1.0 - smoothstep(0.75, 1.0, r));
			return vec4(vec3(v), v);
		]],
		ring = [[
			float r = length(uv * 2.0 - 1.0);
			float v = smoothstep(0.55, 0.92, r) * (1.0 - smoothstep(0.92, 1.0, r));
			return vec4(vec3(v), v);
		]],
		lens = [[
			vec2 p = uv * 2.0 - 1.0;
			float r = length(p);
			vec3 n = normalize(vec3(p * (0.6 + 2.0 * r * r), 0.6));
			return vec4(n * 0.5 + 0.5, 1.0 - smoothstep(0.85, 1.0, r));
		]],
		lens_mask = [[
			float r = length(uv * 2.0 - 1.0);
			return vec4(1.0, 1.0, 1.0, 1.0 - smoothstep(0.85, 1.0, r));
		]],
		flare = [[
			vec2 p = abs(uv * 2.0 - 1.0);
			float v = exp(-p.x * 30.0) * (1.0 - p.y) + exp(-p.y * 30.0) * (1.0 - p.x);
			v = clamp(v * 0.7 + exp(-dot(p, p) * 10.0), 0.0, 1.0);
			return vec4(vec3(v), v);
		]],
		orbit_trail = [[
			float d = abs(uv.x * 2.0 - 1.0);
			float edge = max(step(d, 1.0 / 256.0), exp(-d * 14.0) * (1.0 - d));
			float y = clamp(uv.y, 0.0, 1.0);
			float v = edge * pow(y, 1.5) * (1.0 - smoothstep(0.8, 1.0, y));
			return vec4(vec3(v), v);
		]],
		trail = [[
			float edge = 1.0 - abs(uv.x * 2.0 - 1.0);
			edge = edge * edge * (3.0 - 2.0 * edge);
			float v = edge * pow(clamp(uv.y, 0.0, 1.0), 1.5);
			return vec4(vec3(v), v);
		]],
		slash = [[
			float along = clamp(uv.y, 0.0, 1.0);
			float v = pow(uv.x, 1.5) * (1.0 - smoothstep(0.9, 1.0, uv.x)) * along * along;
			return vec4(vec3(v), v);
		]],
		beam = [[
			float edge = 1.0 - abs(uv.x * 2.0 - 1.0);
			float v = edge * edge * (1.0 - smoothstep(0.6, 1.0, uv.y)) * smoothstep(0.0, 0.05, uv.y);
			return vec4(vec3(v), v);
		]],
	}

	function effects.GetTexture(name)
		if textures[name] then return textures[name] end

		local texture = Texture.New{
			width = 256,
			height = 256,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			image = {
				usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
		texture:Shade(GLSL[name])
		textures[name] = texture
		return texture
	end
end

do
	local pools = {}

	local function acquire(key)
		local pool = pools[key]
		return pool and table.remove(pool)
	end

	local function release(key, object)
		local pool = pools[key]

		if not pool then
			pool = {}
			pools[key] = pool
		end

		pool[#pool + 1] = object
	end

	local function set_color(object, color, alpha)
		object.color:Set(color.r, color.g, color.b, alpha)
		object.emissive.a = object.strength
		object.material:SetEmissiveMultiplier(object.emissive)
		object.material:SetColorMultiplier(object.color)
		object.material:Touch()
	end

	local function set_emission(object, alpha)
		if math.abs(alpha - object.alpha) < 0.002 then return end

		object.alpha = alpha
		object.color.a = alpha
		object.material:SetColorMultiplier(object.color)
		object.material:Touch()
	end

	local function new_material(color, texture, extra)
		return Beam.CreateRibbonMaterial(color, 1, texture, extra)
	end

	do
		local quad

		local function get_quad()
			if quad then return quad end

			quad = Polygon3D.New()
			shapes.BuildPlane(quad, Vec3(), UP, 1, 1)
			quad:BuildBoundingBox()
			quad:Upload()
			return quad
		end

		local META = {}
		META.__index = META

		function effects.AcquireQuad(color, strength, texture, extra)
			local object = acquire(texture)

			if not object then
				local material = new_material(color, texture, extra)
				local entity = Entity.New{Name = "jrpg_quad"}
				entity:SetTransient(true)
				entity:AddComponent("transform")
				entity:AddComponent("visual")
				local visual = entity.visual
				visual:SetCastShadows(false)
				visual:SetInSceneBVH(false)
				visual:SetRaycast(false)
				visual:SetUseOcclusionCulling(false)
				visual:SetReceivesDecals(false)
				visual:CreatePrimitiveEntity(get_quad(), material, "jrpg_quad_primitive")
				visual:BuildAABB()
				object = setmetatable(
					{
						key = texture,
						entity = entity,
						material = material,
						emissive = Color(1, 1, 1, 1),
						color = Color(1, 1, 1, 1),
					},
					META
				)
			end

			object.strength = strength
			object.alpha = -1
			object.transform = object.entity.transform
			set_color(object, color, 0)
			object.entity.visual:SetVisible(true)
			return object
		end

		function META:SetAlpha(alpha)
			set_emission(self, alpha)
		end

		function META:Release()
			self.entity.visual:SetVisible(false)
			release(self.key, self)
		end
	end

	do
		local META = {}
		META.__index = META
		local points = Beam.NewPoints(2)

		function effects.AcquireSprite(color, strength, texture, extra)
			texture = texture or Beam.GetGlowTexture()
			local key = extra or texture
			local object = acquire(key)

			if not object then
				local material = new_material(color, texture, extra)
				object = setmetatable(
					{
						key = key,
						material = material,
						beam = Beam.New{Points = 2, Ribbon = true, Radius = 0.1, Material = material},
						emissive = Color(1, 1, 1, 1),
						color = Color(1, 1, 1, 1),
					},
					META
				)
			end

			object.strength = strength
			object.alpha = -1
			set_color(object, color, 0)
			return object
		end

		function META:SetColor(color)
			set_color(self, color, self.color.a)
		end

		function META:Draw(position, radius, alpha)
			local visible = alpha > 0.002 and radius > 0

			if self.beam.Visible ~= visible then self.beam:SetVisible(visible) end

			if not visible then return end

			local up = render3d.GetCamera():GetRotation():GetUp()
			points[1]:Set(
				position.x - up.x * radius,
				position.y - up.y * radius,
				position.z - up.z * radius
			)
			points[2]:Set(
				position.x + up.x * radius,
				position.y + up.y * radius,
				position.z + up.z * radius
			)
			self.beam:SetRadius(radius)
			self.beam:SetRibbonPoints(points, 0, 1)
			set_emission(self, alpha)
		end

		function META:Release()
			self.beam:SetVisible(false)
			release(self.key, self)
		end
	end

	do
		local META = {}
		META.__index = META
		local WHITE = Color(1, 1, 1, 1)
		local SOFT_HALO = {IgnoreZ = true, OcclusionRadius = 0.3, OcclusionSoftness = 0.25}
		local LENS

		function effects.AcquireOrb(color, lens_scale)
			LENS = LENS or
				{
					Additive = false,
					Translucent = true,
					Roughness = 0.02,
					Metallic = 0,
					Refraction = 1,
					IndexOfRefraction = 1.5,
					AbbeNumber = 4,
					RefractionThickness = 0.3,
					NormalTexture = effects.GetTexture("lens"),
					NormalMapMultiplier = 6,
				}
			return setmetatable(
				{
					core = effects.AcquireSprite(WHITE:GetLerped(0.4, color), 8),
					halo = effects.AcquireSprite(color, 2, nil, SOFT_HALO),
					flare = effects.AcquireSprite(color, 5, effects.GetTexture("flare")),
					lens = effects.AcquireSprite(WHITE:GetLerped(0.85, color), 0, effects.GetTexture("lens_mask"), LENS),
					lens_scale = lens_scale,
				},
				META
			)
		end

		function META:Draw(position, size, alpha, flicker)
			self.core:Draw(position, size * 0.7, alpha)
			self.halo:Draw(
				position,
				size * (2.2 + math.sin(system.GetElapsedTime() * 9) * 0.2),
				0.6 * flicker * alpha
			)
			self.flare:Draw(position, size * 1.6 * flicker, 0.8 * alpha)
			self.lens:Draw(position, size * 2 * self.lens_scale, alpha)
		end

		function META:Release()
			self.core:Release()
			self.halo:Release()
			self.flare:Release()
			self.lens:Release()
		end
	end

	local function smooth_pass(from, to, count)
		to[1]:CopyFrom(from[1])
		to[count]:CopyFrom(from[count])

		for i = 2, count - 1 do
			local a, b, c = from[i - 1], from[i], from[i + 1]
			to[i]:Set(
				(a.x + b.x * 2 + c.x) * 0.25,
				(a.y + b.y * 2 + c.y) * 0.25,
				(a.z + b.z * 2 + c.z) * 0.25
			)
		end
	end

	local function shift(points, count, position)
		local oldest = points[1]

		for i = 1, count - 1 do
			points[i] = points[i + 1]
		end

		oldest:CopyFrom(position)
		points[count] = oldest
	end

	do
		local META = {}
		META.__index = META

		function effects.AcquireTrail(color, strength, count, radius, texture)
			texture = texture or effects.GetTexture("trail")
			local key = tostring(texture) .. count
			local object = acquire(key)

			if not object then
				local material = new_material(color, texture)
				object = setmetatable(
					{
						key = key,
						material = material,
						beam = Beam.New{Points = count, Ribbon = true, Radius = 0, Material = material},
						points = Beam.NewPoints(count),
						smooth_a = Beam.NewPoints(count),
						smooth_b = Beam.NewPoints(count),
						count = count,
						emissive = Color(1, 1, 1, 1),
						color = Color(1, 1, 1, 1),
					},
					META
				)
			end

			object.strength = strength
			object.alpha = -1
			object.primed = false
			object.beam:SetRadius(0)
			object.beam:SetRadiusEnd(radius)
			set_color(object, color, 0)
			set_emission(object, 1)
			return object
		end

		function META:Shift(position, drift_dt)
			if not self.primed then
				for i = 1, self.count do
					self.points[i]:CopyFrom(position)
				end

				self.primed = true
				self.beam:SetVisible(true)
			end

			shift(self.points, self.count, position)

			if drift_dt then
				local points = self.points
				local count = self.count
				local cx, cy, cz = 0, 0, 0

				for i = 1, count do
					local point = points[i]
					cx = cx + point.x
					cy = cy + point.y
					cz = cz + point.z
				end

				cx, cy, cz = cx / count, cy / count, cz / count

				for i = 1, count do
					local point = points[i]
					point:Set(
						point.x + (point.x - cx) * drift_dt,
						point.y + (point.y - cy) * drift_dt,
						point.z + (point.z - cz) * drift_dt
					)
				end
			end
		end

		function META:Rebuild()
			smooth_pass(self.points, self.smooth_a, self.count)
			smooth_pass(self.smooth_a, self.smooth_b, self.count)
			smooth_pass(self.smooth_b, self.smooth_a, self.count)
			self.beam:SetRibbonPoints(self.smooth_a, 0, 1)
		end

		function META:Push(position, drift_dt)
			self:Shift(position, drift_dt)
			self:Rebuild()
		end

		function META:SetPoints(points)
			self.beam:SetVisible(true)
			self.beam:SetRibbonPoints(points, 0, 1)
		end

		function META:SetAlpha(alpha)
			set_emission(self, alpha)
		end

		function META:Release()
			self.beam:SetVisible(false)
			release(self.key, self)
		end
	end

	do
		local META = {}
		META.__index = META

		function effects.AcquireSlashTrail(color, strength, count)
			local key = "slash" .. count
			local object = acquire(key)

			if not object then
				local material = new_material(color, effects.GetTexture("slash"))
				object = setmetatable(
					{
						key = key,
						material = material,
						beam = Beam.New{Points = count, Ribbon = true, Material = material},
						left = Beam.NewPoints(count),
						right = Beam.NewPoints(count),
						count = count,
						emissive = Color(1, 1, 1, 1),
						color = Color(1, 1, 1, 1),
					},
					META
				)
			end

			object.strength = strength
			object.alpha = -1
			object.primed = false
			set_color(object, color, 0)
			set_emission(object, 1)
			return object
		end

		function META:Push(base, tip)
			if not self.primed then
				for i = 1, self.count do
					self.left[i]:CopyFrom(base)
					self.right[i]:CopyFrom(tip)
				end

				self.primed = true
				self.beam:SetVisible(true)
			end

			shift(self.left, self.count, base)
			shift(self.right, self.count, tip)
			self.beam:SetStripPoints(self.left, self.right, 0, 1)
		end

		function META:SetAlpha(alpha)
			set_emission(self, alpha)
		end

		function META:Release()
			self.beam:SetVisible(false)
			release(self.key, self)
		end
	end

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
	local emitters = {}

	local function create_emitter(name, properties)
		local entity = Entity.New{Name = name, transform = {}, particle_emitter_gpu = properties}
		entity:SetTransient(true)
		return entity
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

	function effects.CreateEmitter(name, properties)
		return create_emitter(name, properties)
	end

	local function aim(direction)
		if direction.y < -0.9999 then return Quat(1, 0, 0, 0) end

		local axis = UP:GetCross(direction)
		return Quat(axis.x, axis.y, axis.z, 1 + direction.y):Normalize()
	end

	effects.AimRotation = aim

	function effects.Burst(key, properties, position, direction, count)
		local entity = emitters[key]

		if not entity or not entity:IsValid() then
			entity = create_emitter("jrpg_burst_" .. key, properties)
			emitters[key] = entity
		end

		entity.transform:SetPosition(position:Copy())
		entity.transform:SetRotation(aim(direction))
		entity.particle_emitter_gpu:Burst(count)
	end

	local SPARK_SIZE = 0.012
	local SPARK_GRAVITY = 0.3

	function effects.BurstType(type_name, position, direction, count, speed_scale, spread)
		local definition = damage_types.Get(type_name)
		local color = definition.Color
		local key = type_name .. (speed_scale and "_fast" or "") .. (spread and "_cone" or "")
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

		effects.Burst(
			key,
			effects.GetParticleProperties(definition, overrides),
			position,
			direction,
			count
		)
	end
end

do
	local LIGHT_COUNT = 6
	local lights = {}

	function effects.Flash(position, color, lumen, duration)
		local pick

		for i = 1, LIGHT_COUNT do
			local light = lights[i]

			if not light then
				local entity = Entity.New{
					Name = "jrpg_flash",
					transform = {},
					light_point = {Range = 12, OcclusionMap = false, Lumen = 0},
				}
				entity:SetTransient(true)
				light = {entity = entity, time = 0, duration = 0, lumen = 0}
				lights[i] = light
			end

			if not pick or light.duration - light.time < pick.duration - pick.time then
				pick = light
			end
		end

		pick.entity.transform:SetPosition(position:Copy())
		pick.entity.light_point:SetColor(Color(color.r, color.g, color.b, 1))
		pick.time = 0
		pick.duration = duration
		pick.lumen = lumen
	end

	event.AddListener("Update", "jrpg_flash_lights", function(dt)
		for _, light in ipairs(lights) do
			if light.time < light.duration then
				light.time = light.time + dt
				local f = math.max(1 - light.time / light.duration, 0)
				light.entity.light_point:SetLumen(light.lumen * f * f)
			end
		end
	end)
end

local timed = {}

function effects.AddTimed(effect)
	effect.time = 0
	timed[#timed + 1] = effect
	return effect
end

do
	local META = {}
	META.__index = META

	function META:Update()
		return true
	end

	function META:Remove()
		self.entity:Remove()
	end

	function effects.RemoveDelayed(entity, delay)
		effects.AddTimed(setmetatable({entity = entity, duration = delay}, META))
	end
end

event.AddListener("Update", "jrpg_timed_effects", function(dt)
	for i = #timed, 1, -1 do
		local effect = timed[i]
		effect.time = effect.time + dt

		if
			effect.time >= effect.duration or
			not effect:Update(effect.time / effect.duration, dt)
		then
			effect:Remove()
			table.remove(timed, i)
		end
	end
end)

do
	local META = {}
	META.__index = META
	local BLACK = Color(0, 0, 0, 1)
	local DARK_MATERIAL = {Additive = false, Translucent = true}
	local TRAIL_LINGER = 1 / 0.6
	local TRAIL_STEP_ANGLE = 0.04
	local TRAIL_POINTS = 140

	function META:Update(f, dt)
		local center = self.position

		if self.entity and self.entity:IsValid() then
			center = self.entity.transform:GetPosition()
		end

		local time = f * self.duration
		local main = math.min(f * TRAIL_LINGER, 1)
		local grow = 1 - (1 - math.min(main * 4, 1)) ^ 3
		local fade = math.sin(main * math.pi) ^ 3
		local trail_fade = (math.sin(f * math.pi) ^ 3) * 0.5
		local spin = time * 0.8
		local size = self.size * 2 * grow
		local outer = self.outer.transform
		outer:SetPosition(Vec3(center.x, center.y + 0.03, center.z))
		outer:SetRotation(Quat():Identity():RotateYaw(self.spin + spin))
		outer:SetScale(Vec3(size, 1, size))
		self.outer:SetAlpha(fade)
		local inner = self.inner.transform
		inner:SetPosition(Vec3(center.x, center.y + 0.035, center.z))
		inner:SetRotation(Quat():Identity():RotateYaw(self.spin - spin * 1.6))
		inner:SetScale(Vec3(size, 1, size))
		self.inner:SetAlpha(fade)
		local glow_size = self.size * 3.2
		self.glow.transform:SetPosition(Vec3(center.x, center.y + 0.02, center.z))
		self.glow.transform:SetScale(Vec3(glow_size, 1, glow_size))
		self.glow:SetAlpha(0.1 * fade)
		local body = actors.GetCenter(self.entity)

		for i, trail in ipairs(self.trails) do
			local orbit = self.orbits[i]
			local radius = self.size * orbit.radius * 2 * grow
			local steps = math.clamp(math.ceil(orbit.speed * dt / TRAIL_STEP_ANGLE), 1, 16)

			for step = 1, steps do
				local t = time - dt * (steps - step) / steps
				local ax, ay, az = t * orbit.rate_x, t * orbit.rate_y, t * orbit.rate_z
				local sx, cx, sy, cy, sz, cz = math.sin(ax),
				math.cos(ax),
				math.sin(ay),
				math.cos(ay),
				math.sin(az),
				math.cos(az)
				local y1 = orbit.y * cx - orbit.z * sx
				local z1 = orbit.y * sx + orbit.z * cx
				local x2 = orbit.x * cy + z1 * sy
				local z2 = -orbit.x * sy + z1 * cy
				trail:Shift(
					Vec3(
						center.x + (x2 * cz - y1 * sz) * radius,
						body.y + (x2 * sz + y1 * cz) * radius,
						center.z + z2 * radius
					),
					dt * 0.6 / steps
				)
			end

			trail:Rebuild()
			trail:SetAlpha(trail_fade)
		end

		if self.pillar then
			local height = 3 * grow
			self.pillar_points[1]:Set(center.x, center.y, center.z)
			self.pillar_points[2]:Set(center.x, center.y + height, center.z)
			self.pillar.beam:SetRadius(self.size * 0.35 * (1 - main * 0.5))
			self.pillar.beam:SetRadiusEnd(nil)
			self.pillar:SetPoints(self.pillar_points)
			self.pillar:SetAlpha(fade * 0.4)
		end

		return true
	end

	function META:Remove()
		self.outer:Release()
		self.inner:Release()
		self.glow:Release()

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
				outer = effects.AcquireQuad(BLACK, 0, effects.GetTexture("magic_outer"), DARK_MATERIAL),
				inner = effects.AcquireQuad(BLACK, 0, effects.GetTexture("magic_inner"), DARK_MATERIAL),
				trails = {},
				orbits = {},
				glow = effects.AcquireQuad(color, strength * 60, effects.GetTexture("glow")),
				size = size,
				duration = duration * TRAIL_LINGER,
				spin = math.random() * math.pi * 2,
			},
			META
		)
		effect.glow.transform:SetRotation(Quat():Identity())

		for i = 1, 3 do
			local phase = i / 8 * math.pi * 2
			local x = math.sin(phase + math.randomf(-1, 1))
			local y = math.cos(phase + math.randomf(-1, 1))
			local z = math.sin(-phase + math.randomf(-1, 1))
			local length = math.sqrt(x * x + y * y + z * z)
			local speed = math.randomf(3, 7.5)
			effect.trails[i] = effects.AcquireTrail(color, strength * 150, TRAIL_POINTS, 0.05, effects.GetTexture("orbit_trail"))
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
			effect.pillar = effects.AcquireTrail(color, strength * 30, 2, 1, effects.GetTexture("beam"))
			effect.pillar_points = Beam.NewPoints(2)
		end

		effects.Flash(effect.position + Vec3(0, 0.5, 0), color, 15 * strength, duration * 0.5)
		return effects.AddTimed(effect)
	end
end

do
	local META = {}
	META.__index = META

	function META:Update(f)
		local grow = 1 - (1 - f) ^ 3
		local size = self.size * (0.3 + grow * 1.7)
		self.ring.transform:SetScale(Vec3(size, 1, size))
		self.ring:SetAlpha((1 - f) ^ 2)
		self.flare:Draw(self.position, self.size * 0.8 * (1 - f) ^ 0.5, (1 - f) ^ 2)
		self.glow:Draw(self.position, self.size * 0.9 * (0.5 + f), (1 - f) ^ 3)
		return true
	end

	function META:Remove()
		self.ring:Release()
		self.flare:Release()
		self.glow:Release()
	end

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
		effects.Flash(position + normal * 0.2, color, 30 * strength * definition.Light, 0.35)
		local ring = effects.AcquireQuad(tint, 1.5, effects.GetTexture("ring"))
		ring.transform:SetPosition(position + normal * 0.02)
		ring.transform:SetRotation(effects.AimRotation(normal))
		effects.AddTimed(
			setmetatable(
				{
					position = position:Copy(),
					ring = ring,
					flare = effects.AcquireSprite(tint, 3, effects.GetTexture("flare")),
					glow = effects.AcquireSprite(tint, 0.8),
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
				set_overlay(record, nil)
				table.clear(record.visuals)

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
				table.clear(record.visuals)
				collect_visuals(entity, record.visuals)
				set_overlay(record, record.material)
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
	effects.Burst(
		broken and "shield_break" or "block",
		{
			MaxParticles = 256,
			Playing = false,
			Rate = 0,
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
		},
		position,
		normal,
		broken and 80 or 30
	)
	effects.Flash(position + normal * 0.2, Color(1, 0.9, 0.7, 1), broken and 40 or 15, 0.2)
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

	local function get_record(component)
		local record = records[component]

		if record then return record end

		record = {emitters = {}, orbit = nil}
		records[component] = record
		return record
	end

	local function remove_emitter(record, name)
		local emitter = record.emitters[name]
		emitter.particle_emitter_gpu:SetPlaying(false)
		effects.RemoveDelayed(emitter, 2)
		record.emitters[name] = nil
	end

	event.AddListener("Update", "jrpg_status_visuals", function(dt)
		local now = system.GetElapsedTime()

		for component, record in pairs(records) do
			if not component:IsValid() then
				for name in pairs(record.emitters) do
					remove_emitter(record, name)
				end

				if record.orbit then
					for _, sprite in ipairs(record.orbit) do
						sprite:Release()
					end
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

					if not emitter then
						local properties = effects.GetParticleProperties(definition, {Shape = "sphere", ShapeSize = Vec3(0.3, 0.6, 0.3)})
						properties.Playing = true
						properties.MaxParticles = 256
						emitter = effects.CreateEmitter("jrpg_status_" .. name, properties)
						record.emitters[name] = emitter
					end

					emitter.transform:SetPosition(center:Copy())
					local rate = SPAWN_RATE * math.min(amount, 1)

					if definition.Flicker then rate = rate * (math.random() > 0.6 and 3 or 0) end

					emitter.particle_emitter_gpu:SetRate(rate)
				end
			end

			if pose then pose.animation_speed = animation_speed end

			for name in pairs(record.emitters) do
				if not component.amounts[name] then remove_emitter(record, name) end
			end

			local confused = component.amounts.confused

			if confused then
				if not record.orbit then
					record.orbit = {}

					for i = 1, 3 do
						record.orbit[i] = effects.AcquireSprite(status_effects.Registered.confused.Color, 3, effects.GetTexture("flare"))
					end
				end

				local top = center + Vec3(
						0,
						(
								entity.character_movement and
								entity.character_movement:GetHeight() or
								1.6
							) * 0.55,
						0
					)

				for i, sprite in ipairs(record.orbit) do
					local angle = now * 4 + i * math.pi * 2 / 3
					sprite:Draw(
						top + Vec3(math.cos(angle) * 0.25, math.sin(now * 3 + i) * 0.04, math.sin(angle) * 0.25),
						0.06,
						math.min(confused * 2, 1)
					)
				end
			elseif record.orbit then
				for _, sprite in ipairs(record.orbit) do
					sprite:Release()
				end

				record.orbit = nil
			end
		end
	end)
end

return effects
