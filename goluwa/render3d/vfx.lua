local ffi = require("ffi")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local Texture = import("goluwa/render/texture.lua")
local Beam = import("goluwa/render3d/beam.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local trails = import("goluwa/render3d/trails.lua")
local vfx = {}
local UP = Vec3(0, 1, 0)
local WHITE = Color(1, 1, 1, 1)
local TINTED = {VertexTint = true}

do
	local textures = {}
	local glsl = {
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

	function vfx.RegisterTexture(name, source)
		glsl[name] = source
	end

	function vfx.GetTexture(name)
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
		texture:Shade(glsl[name] or error("unknown vfx texture " .. tostring(name)))
		textures[name] = texture
		return texture
	end
end

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

local tint_materials = {}

local function get_tint_material(texture)
	local material = tint_materials[texture]

	if not material then
		material = Beam.CreateRibbonMaterial(WHITE, 1, texture, TINTED)
		tint_materials[texture] = material
	end

	return material
end

do
	local function smooth_pass(from, to, count)
		to[0], to[1], to[2] = from[0], from[1], from[2]
		local last = (count - 1) * 3
		to[last], to[last + 1], to[last + 2] = from[last], from[last + 1], from[last + 2]

		for o = 3, last - 3, 3 do
			to[o] = (from[o - 3] + from[o] * 2 + from[o + 3]) * 0.25
			to[o + 1] = (from[o - 2] + from[o + 1] * 2 + from[o + 4]) * 0.25
			to[o + 2] = (from[o - 1] + from[o + 2] * 2 + from[o + 5]) * 0.25
		end
	end

	local function unwrap(history, head, count, out)
		for i = 0, count - 1 do
			local source = ((head + i) % count) * 3
			local o = i * 3
			out[o], out[o + 1], out[o + 2] = history[source], history[source + 1], history[source + 2]
		end
	end

	local function fill(history, count, x, y, z)
		for i = 0, count - 1 do
			local o = i * 3
			history[o], history[o + 1], history[o + 2] = x, y, z
		end
	end

	local function set_tint(object, color, strength, alpha)
		object.color_r, object.color_g, object.color_b = color.r, color.g, color.b
		object.strength = strength
		object.alpha = alpha
		object.beam:SetTint(color.r * strength, color.g * strength, color.b * strength, alpha * alpha)
	end

	local tint_pending = {}

	local function refresh_tint(object, alpha)
		local strength = object.strength
		object.alpha = alpha
		object.beam:SetTint(
			object.color_r * strength,
			object.color_g * strength,
			object.color_b * strength,
			alpha * alpha
		)

		if not object.tint_listed then
			object.tint_listed = true
			tint_pending[#tint_pending + 1] = object
		end
	end

	event.AddListener("LateUpdate", "vfx_tints", function()
		for i = #tint_pending, 1, -1 do
			local object = tint_pending[i]
			object.tint_listed = false
			tint_pending[i] = nil

			if object.beam.tint_dirty then object.beam:ApplyTint() end
		end
	end)

	local double_array = ffi.typeof("double[?]")

	do
		local META = {}
		META.__index = META

		function vfx.AcquireTrail(color, strength, count, radius, texture)
			texture = texture or vfx.GetTexture("trail")
			local key = tostring(texture) .. count
			local object = acquire(key)

			if not object then
				object = setmetatable(
					{
						key = key,
						beam = Beam.New{
							Points = count,
							Ribbon = true,
							Radius = 0,
							Material = get_tint_material(texture),
						},
						history = double_array(count * 3),
						flat_a = double_array(count * 3),
						flat_b = double_array(count * 3),
						count = count,
					},
					META
				)
			end

			object.primed = false
			object.head = 0
			object.drift = 0
			object.beam:SetRadius(0)
			object.beam:SetRadiusEnd(radius)
			set_tint(object, color, strength, 1)
			return object
		end

		function META:ShiftXYZ(x, y, z, drift_dt)
			local count = self.count

			if not self.primed then
				fill(self.history, count, x, y, z)
				self.primed = true
				self.beam:SetVisible(true)
			end

			local o = self.head * 3
			self.history[o], self.history[o + 1], self.history[o + 2] = x, y, z
			self.head = (self.head + 1) % count

			if drift_dt then self.drift = self.drift + drift_dt end
		end

		function META:Shift(position, drift_dt)
			self:ShiftXYZ(position.x, position.y, position.z, drift_dt)
		end

		function META:Rebuild()
			local count = self.count
			local history = self.history

			if self.drift ~= 0 then
				local cx, cy, cz = 0, 0, 0

				for o = 0, count * 3 - 3, 3 do
					cx, cy, cz = cx + history[o], cy + history[o + 1], cz + history[o + 2]
				end

				cx, cy, cz = cx / count, cy / count, cz / count
				local drift = self.drift

				for o = 0, count * 3 - 3, 3 do
					history[o] = history[o] + (history[o] - cx) * drift
					history[o + 1] = history[o + 1] + (history[o + 1] - cy) * drift
					history[o + 2] = history[o + 2] + (history[o + 2] - cz) * drift
				end

				self.drift = 0
			end

			unwrap(history, self.head, count, self.flat_a)
			smooth_pass(self.flat_a, self.flat_b, count)
			smooth_pass(self.flat_b, self.flat_a, count)
			smooth_pass(self.flat_a, self.flat_b, count)
			self.beam:SetRibbonFlat(self.flat_b, 0, 1)
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
			if math.abs(alpha - self.alpha) < 0.002 then return end

			refresh_tint(self, alpha)
		end

		function META:Release()
			self.beam:SetVisible(false)
			release(self.key, self)
		end
	end

	do
		local META = {}
		META.__index = META

		function vfx.AcquireSlashTrail(color, strength, count)
			local key = "slash" .. count
			local object = acquire(key)

			if not object then
				object = setmetatable(
					{
						key = key,
						beam = Beam.New{
							Points = count,
							Ribbon = true,
							Material = get_tint_material(vfx.GetTexture("slash")),
						},
						left = double_array(count * 3),
						right = double_array(count * 3),
						flat_left = double_array(count * 3),
						flat_right = double_array(count * 3),
						count = count,
					},
					META
				)
			end

			object.primed = false
			object.head = 0
			set_tint(object, color, strength, 1)
			return object
		end

		function META:Push(base, tip)
			local count = self.count

			if not self.primed then
				fill(self.left, count, base.x, base.y, base.z)
				fill(self.right, count, tip.x, tip.y, tip.z)
				self.primed = true
				self.beam:SetVisible(true)
			end

			local o = self.head * 3
			self.left[o], self.left[o + 1], self.left[o + 2] = base.x, base.y, base.z
			self.right[o], self.right[o + 1], self.right[o + 2] = tip.x, tip.y, tip.z
			self.head = (self.head + 1) % count
			unwrap(self.left, self.head, count, self.flat_left)
			unwrap(self.right, self.head, count, self.flat_right)
			self.beam:SetStripFlat(self.flat_left, self.flat_right, 0, 1)
		end

		function META:SetAlpha(alpha)
			refresh_tint(self, alpha)
		end

		function META:Release()
			self.beam:SetVisible(false)
			release(self.key, self)
		end
	end
end

do
	local META = {}
	META.__index = META

	function vfx.AcquireGpuTrail(color, strength, count, radius, texture, drift, end_color, flicker)
		end_color = end_color or color
		return setmetatable(
			{
				trail = trails.Acquire{
					r = color.r * strength,
					g = color.g * strength,
					b = color.b * strength,
					alpha = 1,
					points = count,
					radius_start = 0,
					radius_end = radius,
					texture = texture,
					drift = drift,
					r_end = end_color.r * strength,
					g_end = end_color.g * strength,
					b_end = end_color.b * strength,
					flicker = flicker,
				},
				end_color = end_color,
				color_r = color.r,
				color_g = color.g,
				color_b = color.b,
				strength = strength,
			},
			META
		)
	end

	function META:ShiftXYZ(x, y, z)
		self.trail:Push(x, y, z)
	end

	function META:Rebuild() end

	function META:SetAlpha(alpha)
		local strength = self.strength
		local end_color = self.end_color
		self.trail:SetColor(
			self.color_r * strength,
			self.color_g * strength,
			self.color_b * strength,
			alpha * alpha,
			end_color.r * strength,
			end_color.g * strength,
			end_color.b * strength
		)
	end

	function META:Release()
		self.trail:Release()
	end
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

	function vfx.AcquireQuad(color, strength, texture, extra)
		local object = acquire(texture)

		if not object then
			local material = Beam.CreateRibbonMaterial(color, 1, texture, extra)
			local entity = Entity.New{Name = "vfx_quad"}
			entity:SetTransient(true)
			entity:AddComponent("transform")
			entity:AddComponent("visual")
			local visual = entity.visual
			visual:SetCastShadows(false)
			visual:SetInSceneBVH(false)
			visual:SetRaycast(false)
			visual:SetUseOcclusionCulling(false)
			visual:SetReceivesDecals(false)
			visual:CreatePrimitiveEntity(get_quad(), material, "vfx_quad_primitive")
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

		object.alpha = -1
		object.transform = object.entity.transform
		object.color:Set(color.r, color.g, color.b, 0)
		object.emissive.a = strength
		object.material:SetEmissiveMultiplier(object.emissive)
		object.material:SetColorMultiplier(object.color)
		object.material:Touch()
		object.entity.visual:SetVisible(true)
		return object
	end

	function META:SetAlpha(alpha)
		if math.abs(alpha - self.alpha) < 0.002 then return end

		self.alpha = alpha
		self.color.a = alpha
		self.material:SetColorMultiplier(self.color)
		self.material:Touch()
	end

	function META:Release()
		self.entity.visual:SetVisible(false)
		release(self.key, self)
	end
end

do
	local emitters = {}
	local definitions = {}

	function vfx.CreateEmitter(name, properties)
		local entity = Entity.New{Name = name, transform = {}, particle_emitter_gpu = properties}
		entity:SetTransient(true)
		return entity
	end

	function vfx.DefineBurst(key, properties)
		properties.Playing = false
		properties.Rate = 0
		definitions[key] = properties
	end

	function vfx.HasBurst(key)
		return definitions[key] ~= nil
	end

	function vfx.Burst(key, position, direction, count)
		local entity = emitters[key]

		if not entity or not entity:IsValid() then
			entity = vfx.CreateEmitter("vfx_burst_" .. key, definitions[key])
			emitters[key] = entity
		end

		entity.particle_emitter_gpu:BurstAt(count, position, direction)
	end
end

do
	local LIGHT_COUNT = 6
	local lights = {}

	function vfx.Flash(position, color, lumen, duration)
		local pick

		for i = 1, LIGHT_COUNT do
			local light = lights[i]

			if not light then
				local entity = Entity.New{
					Name = "vfx_flash",
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

	event.AddListener("Update", "vfx_flash_lights", function(dt)
		for _, light in ipairs(lights) do
			if light.time < light.duration then
				light.time = light.time + dt
				local f = math.max(1 - light.time / light.duration, 0)
				light.entity.light_point:SetLumen(light.lumen * f * f)
			end
		end
	end)
end

do
	local timed = {}

	function vfx.AddTimed(effect)
		effect.time = 0
		timed[#timed + 1] = effect
		return effect
	end

	local META = {}
	META.__index = META

	function META:Update()
		return true
	end

	function META:Remove()
		self.entity:Remove()
	end

	function vfx.RemoveDelayed(entity, delay)
		vfx.AddTimed(setmetatable({entity = entity, duration = delay}, META))
	end

	event.AddListener("Update", "vfx_timed", function(dt)
		for i = #timed, 1, -1 do
			local effect = timed[i]
			effect.time = effect.time + dt
			local done = effect.time >= effect.duration

			if not done then
				local ok, alive = pcall(effect.Update, effect, effect.time / effect.duration, dt)
				done = not ok or not alive

				if not ok then logn("vfx effect failed: ", alive) end
			end

			if done then
				effect:Remove()
				table.remove(timed, i)
			end
		end
	end)
end

return vfx
