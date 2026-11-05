local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local track = import("goluwa/math/track.lua")
local sprites = import("goluwa/render3d/sprites.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local emitter_data = import("goluwa/render3d/emitter_data.lua")
local system = import("goluwa/system.lua")
local clips = {}
local definitions = {}
local WHITE = Color(1, 1, 1, 1)
local BLACK = Color(0, 0, 0, 1)
local UP = Vec3(0, 1, 0)
clips.Source = {}
clips.Scripts = {}

function clips.RegisterScript(name, script)
	clips.Scripts[name] = script
end

clips.RegisterScript("entity", {
	Follow = function(p)
		clips.FollowEntity(p)
	end,
})

local function get(prop, p, v)
	local kind = type(prop)

	if kind == "number" then return prop end

	if kind == "string" then
		local value = v[prop]

		if value == nil then return p[prop] end

		return value
	end

	return prop(p, v)
end

local compile

do
	local env = setmetatable({pi = math.pi}, {__index = math})
	local cache = {}

	function clips.IsExpression(source)
		return type(source) == "string" and not source:find("^[%a_][%w_]*$")
	end

	function compile(source, arguments)
		local key = arguments .. "|" .. source
		local fn = cache[key]

		if not fn then
			fn = assert(loadstring("local " .. arguments .. " = ...\nreturn " .. source, "=" .. source))
			setfenv(fn, env)
			cache[key] = fn
		end

		return fn
	end
end

local EXPRESSION_KEYS = {
	"Alpha",
	"Radius",
	"Brightness",
	"Scale",
	"Yaw",
	"Size",
	"Flicker",
	"LensScale",
	"Strength",
	"Offset",
}
local LAYERS = {}

do
	local SPRITE = {}

	function SPRITE.Setup(layer, p, state)
		state.batch = layer.batch

		if not state.batch then
			state.batch = sprites.GetBatch(layer.Texture and vfx.GetTexture(layer.Texture), layer.Extra)
			layer.batch = state.batch
		end

		local color = p.color
		local tint = layer.Tint and WHITE:GetLerped(layer.Tint, color) or color
		state.r, state.g, state.b = tint.r, tint.g, tint.b
	end

	function SPRITE.Update(layer, p, v, state)
		local alpha = get(layer.Alpha, p, v)

		if alpha <= 0.002 then return end

		local radius = get(layer.Radius, p, v)

		if layer.ScaleBy then radius = radius * p[layer.ScaleBy] end

		local brightness = get(layer.Brightness, p, v)
		local position = p.position
		local lift = layer.Lift or 0
		local ox, oy, oz = 0, 0, 0

		if layer.Offset then ox, oy, oz = layer.Offset(p, v) end

		if layer.Axial then
			local axis = p[layer.Axial]
			state.batch:AddAxial(
				position.x + ox,
				position.y + oy,
				position.z + oz,
				axis.x,
				axis.y,
				axis.z,
				radius,
				state.r * brightness,
				state.g * brightness,
				state.b * brightness,
				alpha
			)
		elseif layer.Flat then
			local normal = p.normal
			state.batch:AddFlat(
				position.x + ox + normal.x * lift,
				position.y + oy + normal.y * lift,
				position.z + oz + normal.z * lift,
				normal.x,
				normal.y,
				normal.z,
				radius,
				state.r * brightness,
				state.g * brightness,
				state.b * brightness,
				alpha
			)
		else
			state.batch:Add(
				position.x + ox,
				position.y + oy + lift,
				position.z + oz,
				radius,
				state.r * brightness,
				state.g * brightness,
				state.b * brightness,
				alpha
			)
		end
	end

	function SPRITE.Remove() end

	LAYERS.sprite = SPRITE
end

do
	local QUAD = {}

	function QUAD.Setup(layer, p, state)
		state.quad = vfx.AcquireQuad(
			layer.Color or BLACK,
			layer.Strength or 0,
			vfx.GetTexture(layer.Texture),
			layer.Material
		)
	end

	function QUAD.Update(layer, p, v, state)
		local transform = state.quad.transform
		local position = p.position
		local size = get(layer.Scale, p, v) * p[layer.ScaleBy]
		transform:SetPosition(Vec3(position.x, position.y + layer.Lift, position.z))
		transform:SetRotation(Quat():Identity():RotateYaw(get(layer.Yaw, p, v)))
		transform:SetScale(Vec3(size, 1, size))
		state.quad:SetAlpha(get(layer.Alpha, p, v))
	end

	function QUAD.Remove(layer, p, state)
		state.quad:Release()
	end

	LAYERS.quad = QUAD
end

do
	local CUSTOM = {}

	function CUSTOM.Setup(layer, p, state)
		if layer.Setup then layer.Setup(p, state) end
	end

	function CUSTOM.Update(layer, p, v, state, dt)
		layer.Update(p, v, state, dt)
	end

	function CUSTOM.Remove(layer, p, state)
		if layer.Remove then layer.Remove(p, state) end
	end

	LAYERS.custom = CUSTOM
end

do
	local ORB = {}
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
	local batches

	function ORB.Setup(layer, p, state)
		if not batches then
			LENS.NormalTexture = vfx.GetTexture("lens")
			batches = {
				core = sprites.GetBatch(),
				halo = sprites.GetBatch(nil, {IgnoreZ = true, OcclusionRadius = 0.3, OcclusionSoftness = 0.25}),
				flare = sprites.GetBatch(vfx.GetTexture("flare")),
			}
		end

		state.core = WHITE:GetLerped(0.4, p.color)
		state.lens = sprites.GetBatch(vfx.GetTexture("lens_mask"), LENS, WHITE:GetLerped(0.85, p.color))
	end

	function ORB.Update(layer, p, v, state)
		local size = get(layer.Size, p, v)
		local alpha = get(layer.Alpha, p, v)

		if alpha <= 0.002 or size <= 0 then return end

		local flicker = layer.Flicker and get(layer.Flicker, p, v) or 1
		local position = p.position
		local x, y, z = position.x, position.y, position.z
		local core, color = state.core, p.color
		batches.core:Add(x, y, z, size * 0.7, core.r * 8, core.g * 8, core.b * 8, alpha * alpha)
		batches.halo:Add(
			x,
			y,
			z,
			size * (2.2 + math.sin(system.GetElapsedTime() * 9) * 0.2),
			color.r * 2,
			color.g * 2,
			color.b * 2,
			0.6 * flicker * alpha
		)
		batches.flare:Add(
			x,
			y,
			z,
			size * 1.6 * flicker,
			color.r * 5,
			color.g * 5,
			color.b * 5,
			0.64 * alpha * alpha
		)
		state.lens:Add(
			x,
			y,
			z,
			size * 2 * (layer.LensScale and get(layer.LensScale, p, v) or 1) * alpha,
			1,
			1,
			1,
			1
		)
	end

	function ORB.Remove() end

	LAYERS.orb = ORB
end

do
	local TRAIL = {}

	local function setup_value(prop, p)
		if type(prop) == "function" then return prop(p, p) end

		if type(prop) == "string" then return p[prop] end

		return prop
	end

	function TRAIL.Setup(layer, p, state)
		local color = layer.Color and layer.Color(p) or p.color
		local strength = setup_value(layer.Strength, p)
		local radius = setup_value(layer.Radius, p)
		local texture = vfx.GetTexture(layer.Texture)
		state.trails = {}
		state.data = {}

		for i = 1, layer.Count or 1 do
			state.trails[i] = vfx.AcquireGpuTrail{
				Color = color,
				Strength = strength,
				Points = layer.Points,
				Radius = radius,
				Texture = texture,
				Drift = layer.Drift,
				EndColor = layer.EndColor and layer.EndColor(p),
				Flicker = layer.Flicker,
				Taper = layer.Taper,
			}

			if layer.Init then state.data[i] = layer.Init(p, i) end
		end
	end

	function TRAIL.Update(layer, p, v, state, dt)
		local alpha = get(layer.Alpha, p, v)
		local position = p.position

		for i, trail in ipairs(state.trails) do
			if layer.Push then
				layer.Push(p, v, trail, state.data[i], dt)
			else
				trail:ShiftXYZ(position.x, position.y, position.z)
			end

			trail:SetAlpha(alpha)
		end
	end

	function TRAIL.Remove(layer, p, state)
		for _, trail in ipairs(state.trails) do
			trail:Release()
		end
	end

	LAYERS.gpu_trail = TRAIL
end

do
	local SLASH = {}

	function SLASH.Setup(layer, p, state)
		local config = layer.OverlayConfig

		if p.overlay_color then
			config = table.shallow_copy(config)
			config.ColorA = p.overlay_color
		end

		state.trail = vfx.AcquireSlashTrail(p.color, layer.Strength, layer.Points, p.overlay or layer.Overlay, config)
	end

	function SLASH.Update(layer, p, v, state)
		state.trail:Push(p.base, p.tip)
		state.trail:SetAlpha(get(layer.Alpha, p, v))
	end

	function SLASH.Remove(layer, p, state)
		state.trail:Release()
	end

	LAYERS.slash = SLASH
end

do
	local EMITTER = {}

	function EMITTER.Setup(layer, p, state)
		local inputs

		if layer.Inputs then
			inputs = {}

			for input_name, param in pairs(layer.Inputs) do
				inputs[input_name] = p[param]
			end
		end

		state.entity = vfx.CreateEmitter("clip_emitter", emitter_data.Get(layer.emitter_key, inputs))
		EMITTER.Update(layer, p, nil, state)
	end

	function EMITTER.Update(layer, p, v, state)
		local at = p[layer.At or "position"]
		state.entity.transform:SetPosition(Vec3(at.x, at.y, at.z))
	end

	function EMITTER.Remove(layer, p, state)
		vfx.StopEmitter(state.entity, layer.Linger or 2)
	end

	LAYERS.emitter = EMITTER
end

function clips.FollowEntity(p)
	if p.entity:IsValid() then
		local position = p.entity.transform:GetPosition()
		p.position:Set(position.x, position.y, position.z)
	end
end

local function make_burst_event(key, count, direction)
	return function(p)
		vfx.Burst(key, p.position, p[direction], count)
	end
end

local function make_emitter_event(key, entry)
	local count, direction, when, inputs_map = entry.Count, entry.Direction, entry.When, entry.Inputs
	return function(p)
		if when and not p[when] then return end

		local inputs

		if inputs_map then
			inputs = {}

			for input_name, param in pairs(inputs_map) do
				inputs[input_name] = p[param]
			end
		end

		emitter_data.Burst(key, p.position, p[direction], count, inputs)
	end
end

local function make_debris_event(key, count, direction)
	return function(p)
		vfx.Debris(key, p.position, p[direction], count)
	end
end

local function make_flash_event(entry)
	local lumen = compile(tostring(entry.Lumen), "p")
	local time = compile(tostring(entry.Time), "p")
	local ox, oy, oz = unpack(entry.Offset or {0, 0, 0})
	local normal_offset = entry.NormalOffset or 0
	local color = entry.Color or "color"
	local temp = Vec3()
	return function(p)
		local normal = p.normal
		temp:Set(
			p.position.x + ox + normal.x * normal_offset,
			p.position.y + oy + normal.y * normal_offset,
			p.position.z + oz + normal.z * normal_offset
		)
		vfx.Flash(temp, p[color], lumen(p), time(p))
	end
end

local function resolve_script(name)
	return clips.Scripts[name] or error("unknown clip script " .. tostring(name))
end

function clips.Define(name, source)
	clips.Source[name] = source
	local definition = table.copy(source)

	if definition.Loop then definition.Duration = math.huge end

	local tracks = {}
	local names = {}

	for key, spec in pairs(definition.Tracks or {}) do
		if type(spec) == "string" then
			spec = compile(spec, "f")
		elseif type(spec) == "table" then
			for _, entry in ipairs(spec) do
				if clips.IsExpression(entry[3]) then
					entry[3] = compile(entry[3], "f")
				end
			end
		end

		tracks[#tracks + 1] = track.New(spec)
		names[#names + 1] = key
	end

	local events = {}

	for key, properties in pairs(definition.Bursts or {}) do
		vfx.DefineBurst(key, properties)
	end

	for key, debris in pairs(definition.Debris or {}) do
		vfx.DefineDebris(key, debris.Material, debris.Emitter)
	end

	for i, entry in ipairs(definition.Events or {}) do
		if entry.Emitter then
			local key = entry.Emitter

			if type(key) == "table" then
				emitter_data.Set(name .. ":event" .. i, key)
				key = name .. ":event" .. i
			end

			entry = {entry[1], make_emitter_event(key, entry)}
		elseif entry.Debris then
			entry = {entry[1], make_debris_event(entry.Debris, entry.Count, entry.Direction)}
		elseif entry.Burst then
			entry = {entry[1], make_burst_event(entry.Burst, entry.Count, entry.Direction)}
		elseif entry.Flash then
			entry = {entry[1], make_flash_event(entry)}
		elseif entry.Call then
			entry = {entry[1], resolve_script(entry.Call).Event}
		end

		events[i] = entry
	end

	table.sort(events, function(a, b)
		return a[1] < b[1]
	end)

	for i, layer in ipairs(definition.Layers or {}) do
		if layer.Type == "emitter" then
			layer.emitter_key = layer.Emitter

			if type(layer.Emitter) == "table" then
				layer.emitter_key = name .. ":layer" .. i
				emitter_data.Set(layer.emitter_key, layer.Emitter)
			end
		end

		layer.type = LAYERS[layer.Type or
			"custom"] or
			error("unknown layer type " .. tostring(layer.Type))

		if layer.Script then
			for key, value in pairs(resolve_script(layer.Script)) do
				layer[key] = value
			end
		end

		for _, key in ipairs(EXPRESSION_KEYS) do
			if clips.IsExpression(layer[key]) then
				layer[key] = compile(layer[key], "p, v")
			end
		end
	end

	local follow = definition.Follow

	if type(follow) == "string" then follow = resolve_script(follow).Follow end

	definitions[name] = {
		Duration = definition.Duration,
		Follow = follow,
		EndWithEntity = definition.EndWithEntity,
		Layers = definition.Layers or {},
		events = events,
		tracks = tracks,
		names = names,
	}
end

local CLIP = {}
CLIP.__index = CLIP

function CLIP:FireEvents(f)
	local events = self.definition.events
	local i = self.next_event

	while events[i] and events[i][1] <= f do
		events[i][2](self.params)
		i = i + 1
	end

	self.next_event = i
end

function CLIP:Update(f, dt)
	local definition = self.definition
	local p = self.params

	if definition.EndWithEntity and not p.entity:IsValid() then return false end

	if definition.Follow then definition.Follow(p) end

	local v = self.values
	local tracks, names = definition.tracks, definition.names

	for i = 1, #tracks do
		v[names[i]] = tracks[i]:Get(f)
	end

	if self.manual then self.time = self.time + dt end

	if self.release_duration then
		self.release_elapsed = self.release_elapsed + dt
		v.release = 1 - self.release_elapsed / self.release_duration

		if v.release <= 0 then return false end
	else
		v.release = 1
	end

	v.f = f
	v.time = self.time
	self:FireEvents(f)
	local layers, states = definition.Layers, self.states

	for i = 1, #layers do
		local layer = layers[i]
		local state = states[i]

		if state then layer.type.Update(layer, p, v, state, dt) end
	end

	return true
end

function CLIP:End(duration)
	self.release_duration = duration
	self.release_elapsed = 0
end

function CLIP:Stop()
	self.duration = 0
end

function CLIP:Remove()
	local layers, states = self.definition.Layers, self.states

	for i = 1, #layers do
		if states[i] then layers[i].type.Remove(layers[i], self.params, states[i]) end
	end
end

function clips.Play(name, params, manual)
	local definition = definitions[name] or error("unknown clip " .. name)
	params.duration = params.duration or definition.Duration
	params.normal = params.normal or UP
	local self = setmetatable(
		{
			definition = definition,
			params = params,
			values = {},
			states = {},
			next_event = 1,
			time = 0,
			manual = manual,
		},
		CLIP
	)
	local layers = definition.Layers

	for i = 1, #layers do
		local layer = layers[i]

		if not layer.When or params[layer.When] then
			self.states[i] = {}
			layer.type.Setup(layer, params, self.states[i])
		end
	end

	self:FireEvents(0)
	self.duration = params.duration

	if not manual then vfx.AddTimed(self) end

	return self
end

return clips
