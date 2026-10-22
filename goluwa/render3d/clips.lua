local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local track = import("goluwa/math/track.lua")
local sprites = import("goluwa/render3d/sprites.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local system = import("goluwa/system.lua")
local clips = {}
local definitions = {}
local WHITE = Color(1, 1, 1, 1)
local BLACK = Color(0, 0, 0, 1)
local UP = Vec3(0, 1, 0)

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

		if layer.Flat then
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
		if type(prop) == "function" then return prop(p) end

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
			state.trails[i] = vfx.AcquireGpuTrail(color, strength, layer.Points, radius, texture, layer.Drift or 0)

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

function clips.Define(name, definition)
	local tracks = {}
	local names = {}

	for key, spec in pairs(definition.Tracks or {}) do
		tracks[#tracks + 1] = track.New(spec)
		names[#names + 1] = key
	end

	local events = {}

	for key, properties in pairs(definition.Bursts or {}) do
		vfx.DefineBurst(key, properties)
	end

	for i, entry in ipairs(definition.Events or {}) do
		if entry.Burst then
			entry = {entry[1], make_burst_event(entry.Burst, entry.Count, entry.Direction)}
		end

		events[i] = entry
	end

	table.sort(events, function(a, b)
		return a[1] < b[1]
	end)

	for _, layer in ipairs(definition.Layers or {}) do
		layer.type = LAYERS[layer.Type or "custom"] or error("unknown layer type " .. layer.Type)
	end

	definitions[name] = {
		Duration = definition.Duration,
		Follow = definition.Follow,
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
