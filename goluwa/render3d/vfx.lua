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
local commands = import("goluwa/cli/commands.lua")
local sprites = import("goluwa/render3d/sprites.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local vfx = {}
local UP = Vec3(0, 1, 0)
local WHITE = Color(1, 1, 1, 1)
local SLASH_END_FADE = 0.15
vfx.exposure_compensation = {particles = 0, sprites = 0, trails = 0}

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
			float v = pow(uv.x, 2.5) * (1.0 - smoothstep(0.9, 1.0, uv.x)) * along * along;
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
local pane_material

local function get_pane_material()
	if not pane_material then
		pane_material = Material.New{
			Translucent = true,
			Unlit = true,
			DoubleSided = true,
			VertexTint = true,
			Color = Color(1, 1, 1, 0.06),
		}
	end

	return pane_material
end

local function get_tint_material(texture)
	local material = tint_materials[texture]

	if not material then
		material = Beam.CreateRibbonMaterial(
			WHITE,
			1,
			texture,
			{VertexTint = true, ExposureCompensation = vfx.exposure_compensation.trails}
		)
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

	local sqrt = math.sqrt

	local function subdivide(from, count, subdivisions, to)
		local o = 0

		for i = 0, count - 2 do
			local a = i * 3
			local b = a + 3
			local p1x, p1y, p1z = from[a], from[a + 1], from[a + 2]
			local p2x, p2y, p2z = from[b], from[b + 1], from[b + 2]
			local p0x, p0y, p0z, p3x, p3y, p3z

			if i > 0 then
				p0x, p0y, p0z = from[a - 3], from[a - 2], from[a - 1]
			else
				p0x, p0y, p0z = 2 * p1x - p2x, 2 * p1y - p2y, 2 * p1z - p2z
			end

			if i < count - 2 then
				p3x, p3y, p3z = from[b + 3], from[b + 4], from[b + 5]
			else
				p3x, p3y, p3z = 2 * p2x - p1x, 2 * p2y - p1y, 2 * p2z - p1z
			end

			local d01 = (p1x - p0x) ^ 2 + (p1y - p0y) ^ 2 + (p1z - p0z) ^ 2
			local d12 = (p2x - p1x) ^ 2 + (p2y - p1y) ^ 2 + (p2z - p1z) ^ 2
			local d23 = (p3x - p2x) ^ 2 + (p3y - p2y) ^ 2 + (p3z - p2z) ^ 2
			local t1 = math.max(sqrt(sqrt(d01)), 1e-3)
			local t2 = t1 + math.max(sqrt(sqrt(d12)), 1e-3)
			local t3 = t2 + math.max(sqrt(sqrt(d23)), 1e-3)

			for step = 0, subdivisions - 1 do
				local t = t1 + (t2 - t1) * step / subdivisions
				local a1 = (t1 - t) / t1
				local a1b = t / t1
				local a2 = (t2 - t) / (t2 - t1)
				local a2b = (t - t1) / (t2 - t1)
				local a3 = (t3 - t) / (t3 - t2)
				local a3b = (t - t2) / (t3 - t2)
				local b1 = (t2 - t) / t2
				local b1b = t / t2
				local b2 = (t3 - t) / (t3 - t1)
				local b2b = (t - t1) / (t3 - t1)
				local c1 = (t2 - t) / (t2 - t1)
				local c1b = (t - t1) / (t2 - t1)
				local a1x, a1y, a1z = p0x * a1 + p1x * a1b, p0y * a1 + p1y * a1b, p0z * a1 + p1z * a1b
				local a2x, a2y, a2z = p1x * a2 + p2x * a2b, p1y * a2 + p2y * a2b, p1z * a2 + p2z * a2b
				local a3x, a3y, a3z = p2x * a3 + p3x * a3b, p2y * a3 + p3y * a3b, p2z * a3 + p3z * a3b
				local b1x, b1y, b1z = a1x * b1 + a2x * b1b, a1y * b1 + a2y * b1b, a1z * b1 + a2z * b1b
				local b2x, b2y, b2z = a2x * b2 + a3x * b2b, a2y * b2 + a3y * b2b, a2z * b2 + a3z * b2b
				to[o], to[o + 1], to[o + 2] = b1x * c1 + b2x * c1b, b1y * c1 + b2y * c1b, b1z * c1 + b2z * c1b
				o = o + 3
			end
		end

		local last = (count - 1) * 3
		to[o], to[o + 1], to[o + 2] = from[last], from[last + 1], from[last + 2]
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

			if object.pane and object.pane.tint_dirty then object.pane:ApplyTint() end
		end
	end)

	local double_array = ffi.typeof("double[?]")

	do
		local META = {}
		META.__index = META

		function vfx.AcquireTrail(color, strength, count, radius, texture, subdivisions, end_taper)
			texture = texture or vfx.GetTexture("trail")
			subdivisions = subdivisions or 1
			local key = tostring(texture) .. count .. "x" .. subdivisions
			local rendered = (count - 1) * subdivisions + 1
			local object = acquire(key)

			if not object then
				object = setmetatable(
					{
						key = key,
						beam = Beam.New{
							Points = rendered,
							Ribbon = true,
							Radius = 0,
							Material = get_tint_material(texture),
						},
						history = double_array(count * 3),
						flat_a = double_array(count * 3),
						flat_b = double_array(count * 3),
						spline = double_array(rendered * 3),
						count = count,
						subdivisions = subdivisions,
					},
					META
				)
			end

			object.primed = false
			object.head = 0
			object.filled = 0
			object.drift = 0
			object.end_taper = end_taper or 0
			object.beam:SetEndTaper(object.end_taper)
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
			self.filled = math.min(self.filled + 1, count)

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

			if self.subdivisions == 1 then
				smooth_pass(self.flat_b, self.flat_a, count)
				smooth_pass(self.flat_a, self.flat_b, count)
				self.beam:SetRibbonFlat(self.flat_b, 0, 1)
			else
				subdivide(self.flat_b, count, self.subdivisions, self.spline)

				if self.end_taper > 0 then
					local span = math.max(self.filled - 1, 1) * self.subdivisions
					self.beam:SetRibbonFlat(
						self.spline,
						-(count - self.filled) * self.subdivisions / span,
						(count - 1) * self.subdivisions / span
					)
				else
					self.beam:SetRibbonFlat(self.spline, 0, 1)
				end
			end
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

		function vfx.AcquireSlashTrail(color, strength, count, overlay_kind, overlay_config)
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
						pane = Beam.New{
							Points = count,
							Ribbon = true,
							Material = get_pane_material(),
						},
						left = double_array(count * 3),
						right = double_array(count * 3),
						flat_left = double_array(count * 3),
						flat_right = double_array(count * 3),
						count = count,
					},
					META
				)
				object.beam:SetEndFade(SLASH_END_FADE)
				object.pane:SetEndFade(SLASH_END_FADE)
				object.beam:SetUVByLength(true)
				object.pane:SetUVByLength(true)
			end

			object.primed = false
			object.head = 0
			object.overlay_kind = overlay_kind
			object.overlay_config = overlay_config
			set_tint(object, color, strength, 1)
			object.pane:SetTint(1, 1, 1, 1)
			return object
		end

		function META:Push(base, tip)
			local count = self.count

			if not self.primed then
				fill(self.left, count, base.x, base.y, base.z)
				fill(self.right, count, tip.x, tip.y, tip.z)
				self.primed = true
				self.beam:SetVisible(true)
				self.pane:SetVisible(true)
				self.overlay = surface_overlays.Add(self.pane.entity.visual, self.overlay_kind, self.overlay_config)
			end

			local o = self.head * 3
			self.left[o], self.left[o + 1], self.left[o + 2] = base.x, base.y, base.z
			self.right[o], self.right[o + 1], self.right[o + 2] = tip.x, tip.y, tip.z
			self.head = (self.head + 1) % count
			unwrap(self.left, self.head, count, self.flat_left)
			unwrap(self.right, self.head, count, self.flat_right)
			self.beam:SetStripFlat(self.flat_left, self.flat_right, 0, 1)
			self.pane:SetStripFlat(self.flat_left, self.flat_right, 0, 1)
			local stretch = self.overlay_config.UVStretch

			if stretch then
				local right = self.flat_right
				local length = 0

				for i = 3, count * 3 - 3, 3 do
					local dx, dy, dz = right[i] - right[i - 3], right[i + 1] - right[i - 2], right[i + 2] - right[i - 1]
					length = length + math.sqrt(dx * dx + dy * dy + dz * dz)
				end

				local last = (count - 1) * 3
				local wx, wy, wz = right[last] - self.flat_left[last],
				right[last + 1] - self.flat_left[last + 1],
				right[last + 2] - self.flat_left[last + 2]
				self.overlay:SetUVScale(math.sqrt(wx * wx + wy * wy + wz * wz), math.max(length, 0.05) / stretch)
			end
		end

		function META:SetAlpha(alpha)
			refresh_tint(self, alpha)
			self.pane:SetTint(1, 1, 1, alpha * alpha)
		end

		function META:Release()
			self.beam:SetVisible(false)
			self.pane:SetVisible(false)
			surface_overlays.Clear(self.pane.entity.visual)
			release(self.key, self)
		end
	end
end

do
	local META = {}
	META.__index = META

	function vfx.AcquireGpuTrail(
		color,
		strength,
		count,
		radius,
		texture,
		drift,
		end_color,
		flicker,
		exposure_compensation
	)
		exposure_compensation = exposure_compensation or vfx.exposure_compensation.trails
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
					exposure_compensation = exposure_compensation,
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

local REDEFINE_LINGER = 3

do
	local emitters = {}
	local definitions = {}
	local live_emitters = setmetatable({}, {__mode = "k"})

	function vfx.CreateEmitter(name, properties)
		properties.ExposureCompensation = properties.ExposureCompensation or vfx.exposure_compensation.particles
		local entity = Entity.New{Name = name, transform = {}, particle_emitter_gpu = properties}
		entity:SetTransient(true)
		live_emitters[entity] = true
		return entity
	end

	function vfx.SetExposureCompensation(category, amount)
		assert(
			vfx.exposure_compensation[category] ~= nil,
			"unknown exposure compensation category " .. tostring(category)
		)
		vfx.exposure_compensation[category] = amount

		if category == "sprites" then
			sprites.SetExposureCompensation(amount)
		elseif category == "trails" then
			for _, material in pairs(tint_materials) do
				material:SetExposureCompensation(amount)
			end
		else
			for entity in pairs(live_emitters) do
				if entity:IsValid() then
					entity.particle_emitter_gpu:SetExposureCompensation(amount)
				end
			end
		end
	end

	local function drop_emitter(key)
		local entity = emitters[key]

		if entity then
			vfx.RemoveDelayed(entity, REDEFINE_LINGER)
			emitters[key] = nil
		end
	end

	function vfx.DefineBurst(key, properties)
		drop_emitter(key)
		properties.Playing = false
		properties.Rate = 0
		definitions[key] = properties
	end

	function vfx.ClearBursts(prefix)
		for key in pairs(definitions) do
			if key:starts_with(prefix) then
				drop_emitter(key)
				definitions[key] = nil
			end
		end
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
	local emitters = {}
	local definitions = {}

	function vfx.DefineDebris(key, material, properties)
		local entity = emitters[key]

		if entity then
			vfx.RemoveDelayed(entity, REDEFINE_LINGER)
			emitters[key] = nil
		end

		properties.Material = Material.New(material)
		properties.Playing = false
		properties.Rate = 0
		definitions[key] = properties
	end

	function vfx.HasDebris(key)
		return definitions[key] ~= nil
	end

	function vfx.Debris(key, position, direction, count)
		local entity = emitters[key]

		if not entity or not entity:IsValid() then
			entity = Entity.New{
				Name = "vfx_debris_" .. key,
				transform = {},
				particle_emitter_cpu = definitions[key],
			}
			entity:SetTransient(true)
			emitters[key] = entity
		end

		entity.particle_emitter_cpu:BurstAt(count, position, direction)
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

commands.Add("vfx_exposure=string,number", function(category, amount)
	vfx.SetExposureCompensation(category, amount)
end)

return vfx
