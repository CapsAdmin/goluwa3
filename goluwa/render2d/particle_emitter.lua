local ffi = require("ffi")
local render2d = import("goluwa/render2d/render2d.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local ParticleEmitter = objects.CreateTemplate("ParticleEmitter")
ParticleEmitter:GetSet("MaxParticles", 1000)
ParticleEmitter:GetSet("Speed", 1)
ParticleEmitter:GetSet("Rate", -1)
ParticleEmitter:GetSet("EmitCount", 1)
ParticleEmitter:GetSet("Additive", true)
ParticleEmitter:GetSet("Paused", false)
ParticleEmitter:GetSet("CenterAttractionForce", 0)
ParticleEmitter:GetSet("PosAttractionForce", 0)
ParticleEmitter:GetSet("DefaultVelocity", Vec2(0, 0))
ParticleEmitter:GetSet("DefaultDrag", 0.98)
ParticleEmitter:GetSet("DefaultSize", Vec2(4, 4))
ParticleEmitter:GetSet("DefaultAngle", 0)
ParticleEmitter:GetSet("DefaultStartSize", 1)
ParticleEmitter:GetSet("DefaultEndSize", 1)
ParticleEmitter:GetSet("DefaultStartAlpha", 1)
ParticleEmitter:GetSet("DefaultEndAlpha", 0)
ParticleEmitter:GetSet("DefaultLifeTime", 1)
ParticleEmitter:GetSet("DefaultColor", Color(1, 1, 1, 1))
ParticleEmitter:GetSet("DefaultStartLength", Vec2(0, 0))
ParticleEmitter:GetSet("DefaultEndLength", Vec2(0, 0))
ParticleEmitter:GetSet("DefaultStartJitter", 0)
ParticleEmitter:GetSet("DefaultEndJitter", 0)
ParticleEmitter:GetSet("Position", Vec2(0, 0))
ParticleEmitter:GetSet("Texture", nil)
ParticleEmitter:GetSet("ScreenRect", nil)
ParticleEmitter:GetSet("OnEmit", nil)

function ParticleEmitter.New(config)
	config = config or {}
	return ParticleEmitter:CreateObject{
		particles = {},
		last_emit = 0,
		attraction_center = Vec2(0, 0),
		MaxParticles = config.MaxParticles or 1000,
		Speed = config.Speed or 1,
		Rate = config.Rate or -1,
		EmitCount = config.EmitCount or 1,
		Additive = config.Additive ~= false,
		Paused = config.Paused or false,
		CenterAttractionForce = config.CenterAttractionForce or 0,
		PosAttractionForce = config.PosAttractionForce or 0,
		DefaultVelocity = config.DefaultVelocity or Vec2(0, 0),
		DefaultDrag = config.DefaultDrag or 0.98,
		DefaultSize = config.DefaultSize or Vec2(4, 4),
		DefaultAngle = config.DefaultAngle or 0,
		DefaultStartSize = config.DefaultStartSize or 1,
		DefaultEndSize = config.DefaultEndSize or 1,
		DefaultStartAlpha = config.DefaultStartAlpha or 1,
		DefaultEndAlpha = config.DefaultEndAlpha or 0,
		DefaultLifeTime = config.DefaultLifeTime or 1,
		DefaultColor = config.DefaultColor or Color(1, 1, 1, 1),
		DefaultStartLength = config.DefaultStartLength or Vec2(0, 0),
		DefaultEndLength = config.DefaultEndLength or Vec2(0, 0),
		DefaultStartJitter = config.DefaultStartJitter or 0,
		DefaultEndJitter = config.DefaultEndJitter or 0,
		Position = config.Position or Vec2(0, 0),
		Texture = config.Texture or nil,
		ScreenRect = config.ScreenRect or nil,
		OnEmit = config.OnEmit or nil,
	}
end

function ParticleEmitter:Update(dt)
	if self.Paused then return end

	local time = system.GetElapsedTime()

	if self.Rate == 0 then
		self:Emit()
	elseif self.Rate ~= -1 and self.last_emit < time then
		self:Emit()
		self.last_emit = time + self.Rate
	end

	local remove_indices = {}
	local center = Vec2(0, 0)
	local particle_count = 0
	dt = dt * self.Speed
	local cull = self.ScreenRect ~= nil

	for i, p in ipairs(self.particles) do
		if p.EndTime < time then
			remove_indices[i] = true
		else
			if self.CenterAttractionForce ~= 0 then
				p.Velocity = p.Velocity + (self.attraction_center - p.Position) * self.CenterAttractionForce
			end

			if self.PosAttractionForce ~= 0 then
				p.Velocity = p.Velocity + (self.Position - p.Position) * self.PosAttractionForce
			end

			if p.Velocity.x ~= 0 then
				p.Position.x = p.Position.x + p.Velocity.x * dt
				p.Velocity.x = p.Velocity.x * p.Drag
			end

			if p.Velocity.y ~= 0 then
				p.Position.y = p.Position.y + p.Velocity.y * dt
				p.Velocity.y = p.Velocity.y * p.Drag
			end

			p.LifeMult = math.max(0, (p.EndTime - time) / p.LifeTime)
			center.x = center.x + p.Position.x
			center.y = center.y + p.Position.y
			particle_count = particle_count + 1

			if cull then
				local sr = self.ScreenRect

				if
					p.Position.x > sr.w or
					p.Position.y > sr.h or
					p.Position.x < sr.x or
					p.Position.y < sr.y
				then
					remove_indices[i] = true
				end
			end
		end
	end

	if particle_count > 0 then
		self.attraction_center.x = center.x / particle_count
		self.attraction_center.y = center.y / particle_count
	end

	for i = #self.particles, 1, -1 do
		if remove_indices[i] then table.remove(self.particles, i) end
	end
end

function ParticleEmitter:Draw()
	if #self.particles == 0 then return end

	render2d.PushBlendPreset(self.Additive and "additive" or "alpha")
	render2d.SetTexture(self.Texture)

	for _, p in ipairs(self.particles) do
		local size = math.lerp(p.LifeMult, p.EndSize, p.StartSize)
		local alpha = math.lerp(p.LifeMult, p.EndAlpha, p.StartAlpha)
		local length = math.lerp(p.LifeMult, p.EndLength, p.StartLength)
		local jitter = math.lerp(p.LifeMult, p.EndJitter, p.StartJitter)

		if jitter ~= 0 then
			size = size + math.random(-jitter, jitter)
			alpha = alpha + math.random(-jitter, jitter)
		end

		local w = size * p.Size.x
		local h = size * p.Size.y
		local angle = p.Angle

		if not (length.x == 0 and length.y == 0) then
			if p.Velocity.x ~= 0 or p.Velocity.y ~= 0 then
				angle = angle + math.atan2(p.Velocity.y, p.Velocity.x) + math.pi / 2
			end

			if length.x ~= 0 then w = w * length.x end

			if length.y ~= 0 then h = h * length.y end
		end

		local ox = w * 0.5
		local oy = h * 0.5
		render2d.PushColor(p.Color.r, p.Color.g, p.Color.b, p.Color.a * alpha)
		render2d.DrawRect(p.Position.x - ox, p.Position.y - oy, w, h, angle, ox, oy)
		render2d.PopColor()
	end

	render2d.PopBlendMode()
end

function ParticleEmitter:Emit()
	for _ = 1, self.EmitCount do
		if #self.particles >= self.MaxParticles then
			table.remove(self.particles, 1)
		end

		self:AddParticle()
	end
end

function ParticleEmitter:AddParticle(overrides)
	if #self.particles >= self.MaxParticles then
		table.remove(self.particles, 1)
	end

	overrides = overrides or {}
	local time = system.GetElapsedTime()
	local life = overrides.LifeTime or self.DefaultLifeTime
	local p = {
		Position = overrides.Position or self.Position:Copy(),
		Velocity = overrides.Velocity or self.DefaultVelocity:Copy(),
		Drag = overrides.Drag or self.DefaultDrag,
		Size = overrides.Size or self.DefaultSize:Copy(),
		Angle = overrides.Angle or self.DefaultAngle,
		StartSize = overrides.StartSize or self.DefaultStartSize,
		EndSize = overrides.EndSize or self.DefaultEndSize,
		StartAlpha = overrides.StartAlpha or self.DefaultStartAlpha,
		EndAlpha = overrides.EndAlpha or self.DefaultEndAlpha,
		LifeTime = life,
		StartTime = time,
		EndTime = time + life,
		LifeMult = 1,
		Color = overrides.Color or self.DefaultColor:Copy(),
		StartLength = overrides.StartLength or self.DefaultStartLength:Copy(),
		EndLength = overrides.EndLength or self.DefaultEndLength:Copy(),
		StartJitter = overrides.StartJitter or self.DefaultStartJitter,
		EndJitter = overrides.EndJitter or self.DefaultEndJitter,
	}
	table.insert(self.particles, p)

	if self.OnEmit then self:OnEmit(p) end

	return p
end

function ParticleEmitter:GetParticles()
	return self.particles
end

function ParticleEmitter:Clear()
	self.particles = {}
end

return ParticleEmitter:Register()
