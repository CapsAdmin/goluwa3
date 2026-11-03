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
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local data_files = import("goluwa/data_files.lua")
local vfs = import("goluwa/vfs.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local vfx = {}
local UP = Vec3(0, 1, 0)
local WHITE = Color(1, 1, 1, 1)
local SLASH_END_FADE = 0.15
vfx.exposure_compensation = {particles = 0, sprites = 0, trails = 0}

do
	local textures = {}
	local flipbooks = {}
	local definitions = {}
	local names = {textures = {}, flipbooks = {}}
	local TEXTURE_CONFIG = {
		format = "r8g8b8a8_unorm",
		image = {usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"}},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	vfx.Files = data_files.New(
		"lua/vfx_textures/",
		{"Size", "Columns", "Rows", "TileSize", "MipLevels", "Source"}
	)
	vfx.Errors = {}

	local function create_texture(width, height, mip_map_levels, mipmapped_sampler)
		local config = table.copy(TEXTURE_CONFIG)
		config.width = width
		config.height = height
		config.mip_map_levels = mip_map_levels

		if mipmapped_sampler then config.sampler.mipmap_mode = "linear" end

		return Texture.New(config)
	end

	local function shade_texture(texture, definition)
		texture:Shade("#line 1 1\n" .. definition.Source)
	end

	local function get_flipbook_source(definition, entry)
		local columns, rows = definition.Columns, definition.Rows
		return glsl_common.GetNoiseGLSL() .. string.format(
				[[
			const vec2 FLIPBOOK_GRID = vec2(%d.0, %d.0);
			const float FLIPBOOK_FRAMES = %d.0;
			#line 1 1
			%s

			vec4 shade(vec2 uv, vec3 _cube_dir) {
				vec2 cell = floor(uv * FLIPBOOK_GRID);
				float frame = cell.y * FLIPBOOK_GRID.x + cell.x;
				return %s(fract(uv * FLIPBOOK_GRID), frame / FLIPBOOK_FRAMES * 6.2831853, frame);
			}
		]],
				columns,
				rows,
				columns * rows,
				definition.Source,
				entry
			)
	end

	local function bake_flipbook(texture, definition, entry)
		texture:Shade(get_flipbook_source(definition, entry))
	end

	local function remove_name(list, name)
		for i, other in ipairs(list) do
			if other == name then
				table.remove(list, i)
				return
			end
		end
	end

	function vfx.RegisterFile(name, data)
		assert(
			type(name) == "string" and name:find("^[%w_]+$"),
			"vfx texture names are letters, digits and underscores"
		)
		assert(type(data.Source) == "string", name .. " needs a Source")
		local flipbook = data.Columns ~= nil

		if flipbook then
			for _, key in ipairs{"Columns", "Rows", "TileSize"} do
				assert(
					type(data[key]) == "number" and data[key] >= 1 and data[key] % 1 == 0,
					name .. " needs a whole number " .. key
				)
			end

			assert(
				data.Source:find("flipbook_frame", 1, true),
				name .. " needs a flipbook_frame function"
			)
		else
			assert(
				data.Size == nil or
					type(data.Size) == "number" and
					data.Size >= 1 and
					data.Size % 1 == 0,
				name .. " Size is a whole number"
			)
		end

		local previous = definitions[name]
		assert(
			not previous or (previous.Columns ~= nil) == flipbook,
			name .. " is already a " .. (flipbook and "texture" or "flipbook")
		)
		vfx.Files:Remember(name, data)
		definitions[name] = data

		if not previous then
			local list = flipbook and names.flipbooks or names.textures
			list[#list + 1] = name
			table.sort(list)
		end

		if flipbook then
			local baked = flipbooks[name]

			if baked then
				local same_size = baked.Columns == data.Columns and
					baked.Rows == data.Rows and
					baked.TileSize == data.TileSize and
					(
						baked.Normal ~= nil
					) == (
						data.Source:find("flipbook_normal", 1, true) ~= nil
					)

				if same_size then
					bake_flipbook(baked.Texture, data, "flipbook_frame")

					if baked.Normal then bake_flipbook(baked.Normal, data, "flipbook_normal") end
				else
					flipbooks[name] = nil
					vfx.GetFlipbook(name)
				end
			end
		else
			local baked = textures[name]

			if baked then
				if baked:GetWidth() == (data.Size or 256) then
					shade_texture(baked, data)
				else
					textures[name] = nil
					vfx.GetTexture(name)
				end
			end
		end
	end

	do
		local files = {}

		for _, file in ipairs(vfs.Find("lua/vfx_textures/%.lua$")) do
			files[#files + 1] = file:gsub("%.lua$", "")
		end

		table.sort(files)

		for _, name in ipairs(files) do
			vfx.RegisterFile(name, vfx.Files:Read(name))
		end
	end

	function vfx.GetTextureNames()
		return table.copy(names.textures)
	end

	function vfx.GetFlipbookNames()
		return table.copy(names.flipbooks)
	end

	function vfx.IsFlipbook(name)
		return definitions[name].Columns ~= nil
	end

	function vfx.GetFileNames()
		return list.extend(table.copy(names.textures), names.flipbooks)
	end

	function vfx.GetTexture(name)
		if textures[name] then return textures[name] end

		local definition = definitions[name]
		assert(definition and not definition.Columns, "unknown vfx texture " .. tostring(name))
		local size = definition.Size or 256
		local texture = create_texture(size, size, "auto")
		shade_texture(texture, definition)
		textures[name] = texture
		return texture
	end

	function vfx.GetFlipbook(name)
		local flipbook = flipbooks[name]

		if flipbook then return flipbook end

		local definition = definitions[name]
		assert(definition and definition.Columns, "unknown vfx flipbook " .. tostring(name))
		local columns, rows, tile = definition.Columns, definition.Rows, definition.TileSize
		local texture = create_texture(columns * tile, rows * tile, definition.MipLevels or 3, true)
		bake_flipbook(texture, definition, "flipbook_frame")
		local normal

		if definition.Source:find("flipbook_normal", 1, true) then
			normal = create_texture(columns * tile, rows * tile, definition.MipLevels or 3, true)
			bake_flipbook(normal, definition, "flipbook_normal")
		end

		flipbook = {
			Texture = texture,
			Normal = normal,
			Columns = columns,
			Rows = rows,
			TileSize = tile,
			Frames = columns * rows,
		}
		flipbooks[name] = flipbook
		return flipbook
	end

	function vfx.ParseError(message)
		local line, text = message:match("1:(%d+): error: ([^\n]*)")

		if not line then return message end

		return ("line %s: %s"):format(line, text)
	end

	function vfx.UpdateFile(name, data)
		local previous = vfx.Files.Source[name]
		local ok, err = pcall(vfx.RegisterFile, name, data)

		if ok then
			ok, err = pcall(definitions[name].Columns and vfx.GetFlipbook or vfx.GetTexture, name)
		end

		if not ok then
			if previous then
				pcall(vfx.RegisterFile, name, previous)
			else
				local flipbook = definitions[name] and definitions[name].Columns ~= nil
				definitions[name] = nil
				vfx.Files.Source[name] = nil
				remove_name(flipbook and names.flipbooks or names.textures, name)
			end

			vfx.Errors[name] = vfx.ParseError(tostring(err))
			error(vfx.Errors[name], 0)
		end

		vfx.Errors[name] = nil
	end

	function vfx.ReloadFile(name)
		return vfx.UpdateFile(name, vfx.Files:Read(name))
	end

	function vfx.SaveFile(name)
		return vfx.Files:Save(name)
	end

	function vfx.GetFileStatus(name)
		return vfx.Errors[name]
	end

	function vfx.GetNewFileName(base)
		local index = 2

		while definitions[base .. "_" .. index] do
			index = index + 1
		end

		return base .. "_" .. index
	end

	function vfx.CreateFile(name, from)
		vfx.UpdateFile(name, table.copy(vfx.Files.Source[from]))
		return name
	end
end

do
	local LIT_SPRITES = {
		Additive = false,
		Translucent = true,
		Unlit = false,
		VertexTint = true,
		SimpleLighting = true,
		Roughness = 1,
		Metallic = 0,
	}
	local ADDITIVE_SPRITES = {Additive = true, VertexTint = true}
	local materials = {}

	function vfx.GetFlipbookBatch(name)
		local flipbook = vfx.GetFlipbook(name)
		local config = materials[flipbook]

		if not config then
			config = flipbook.Normal and
				table.merge({NormalTexture = flipbook.Normal}, LIT_SPRITES) or
				ADDITIVE_SPRITES
			materials[flipbook] = config
		end

		local batch = sprites.GetBatch(flipbook.Texture, config)
		batch:SetAtlas(flipbook.Columns, flipbook.Rows)
		batch:SetNearFade(0.5, 1.5)
		return batch, flipbook.Frames
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

			if object.pane and object.pane.tint_dirty then object.pane:ApplyTint() end
		end
	end)

	local double_array = ffi.typeof("double[?]")

	do
		local META = {}
		META.__index = META

		function vfx.AcquireBeam(color, strength, radius, texture)
			local key = "beam" .. tostring(texture)
			local object = acquire(key)

			if not object then
				object = setmetatable(
					{
						key = key,
						beam = Beam.New{Points = 2, Ribbon = true, Radius = 0, Material = get_tint_material(texture)},
					},
					META
				)
			end

			object.beam:SetRadius(radius)
			object.beam:SetRadiusEnd(nil)
			set_tint(object, color, strength, 1)
			return object
		end

		function META:SetRadius(radius)
			self.beam:SetRadius(radius)
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

	function vfx.AcquireGpuTrail(config)
		local color = config.Color
		local strength = config.Strength
		local end_color = config.EndColor or color
		return setmetatable(
			{
				trail = trails.Acquire{
					r = color.r * strength,
					g = color.g * strength,
					b = color.b * strength,
					alpha = 1,
					points = config.Points,
					radius_start = 0,
					radius_end = config.Radius,
					texture = config.Texture,
					drift = config.Drift,
					r_end = end_color.r * strength,
					g_end = end_color.g * strength,
					b_end = end_color.b * strength,
					flicker = config.Flicker,
					taper = config.Taper,
					exposure_compensation = config.ExposureCompensation or vfx.exposure_compensation.trails,
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

	function vfx.StopEmitter(entity, linger)
		entity.particle_emitter_gpu:SetPlaying(false)
		vfx.RemoveDelayed(entity, linger)
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

	function vfx.Flash(position, color, lumen, duration, options)
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
				light = {
					entity = entity,
					time = 0,
					duration = 0,
					lumen = 0,
					color = Color(1, 1, 1, 1),
					x = 0,
					y = 0,
					z = 0,
					flip = false,
					positions = {Vec3(), Vec3()},
				}
				lights[i] = light
			end

			if not pick or light.duration - light.time < pick.duration - pick.time then
				pick = light
			end
		end

		pick.x, pick.y, pick.z = position.x, position.y, position.z
		pick.entity.transform:SetPosition(position:Copy())
		pick.velocity = options and options.Velocity
		pick.time = 0
		pick.duration = duration
		pick.lumen = lumen
		pick.start = color
		pick.finish = options and options.ColorEnd or color
		pick.attack = options and options.Attack or 0
		pick.falloff = options and options.Falloff or 2
		pick.flicker = options and options.Flicker or 0
		pick.sustain = options and options.Sustain or 1
		pick.sustain_time = options and options.SustainTime or 0
		pick.seed = math.random() * 100
		pick.entity.light_point:SetRange(options and options.Range or 12)
		pick.radius = options and options.SourceRadius or 0
		pick.radius_end = options and options.SourceRadiusEnd or pick.radius
		pick.entity.light_point:SetSourceRadius(pick.radius)
		pick.entity.light_point:SetOcclusionMap(options and options.Shadows or false)
		pick.entity.light_point:SetColor(pick.color:Set(color.r, color.g, color.b, 1))
	end

	event.AddListener("Update", "vfx_flash_lights", function(dt)
		for _, light in ipairs(lights) do
			if light.time < light.duration then
				light.time = math.min(light.time + dt, light.duration)
				local t = light.time / light.duration
				local f = t < light.attack and t / light.attack or (1 - t) ^ light.falloff

				if light.sustain < 1 then
					f = f * (
							light.sustain + (
								1 - light.sustain
							) * (
								1 - math.smoothstep(0, light.sustain_time, t)
							)
						)
				end

				if light.flicker > 0 then
					f = f * (1 - light.flicker * (0.5 + 0.5 * math.sin(light.time * 60 + light.seed)))
				end

				local start, finish = light.start, light.finish
				local k = math.sqrt(t)
				local point = light.entity.light_point
				point:SetColor(
					light.color:Set(
						start.r + (finish.r - start.r) * k,
						start.g + (finish.g - start.g) * k,
						start.b + (finish.b - start.b) * k,
						1
					)
				)
				point:SetLumen(light.lumen * f)

				if light.radius_end ~= light.radius then
					point:SetSourceRadius(light.radius + (light.radius_end - light.radius) * (1 - (1 - t) ^ 2))
				end

				local velocity = light.velocity

				if velocity then
					light.x, light.y, light.z = light.x + velocity.x * dt, light.y + velocity.y * dt, light.z + velocity.z * dt
					light.flip = not light.flip
					local position = light.positions[light.flip and 1 or 2]
					position:Set(light.x, light.y, light.z)
					light.entity.transform:SetPosition(position)
				end
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
