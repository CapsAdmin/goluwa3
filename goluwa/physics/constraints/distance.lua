local Constraint = import("goluwa/physics/constraint.lua")
local rows = import("goluwa/physics/constraint_rows.lua")
local objects = import("goluwa/objects/objects.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local META = objects.CreateTemplate("physics_distance_constraint")
META.Base = Constraint
META.CollideConnected = true
local INFINITY = math.huge

function META.New(body_0, body_1, world_anchor_0, world_anchor_1, config)
	config = config or {}
	local self = META:CreateObject{
		Length = config.Length or (world_anchor_1 - world_anchor_0):GetLength(),
		Unilateral = config.Unilateral or false,
		Stiffness = config.Stiffness or 0,
		Damping = config.Damping or 0,
		MaxForce = config.MaxForce or INFINITY,
		CollideConnected = config.CollideConnected ~= false,
		BreakForce = config.BreakForce,
		LengthRate = 0,
		Impulse = 0,
		LastDirection = {1, 0, 0},
	}
	return self:SetupFrames(body_0, body_1, world_anchor_0, nil, world_anchor_1)
end

function META:SetLength(length)
	self.Length = length
	self.TargetLength = nil
	self.OscillationPeriod = nil
	return self
end

function META:SetTargetLength(length, speed)
	self.TargetLength = length
	self.LengthSpeed = speed
	self.OscillationPeriod = nil
	return self
end

function META:SetOscillation(center, amplitude, period)
	self.OscillationCenter = center
	self.OscillationAmplitude = amplitude
	self.OscillationPeriod = period
	self.OscillationTime = 0
	self.TargetLength = nil
	return self
end

function META:GetCurrentLength()
	local s0, s1 = self:LoadStates()
	local dx, dy, dz = s1.px - s0.px, s1.py - s0.py, s1.pz - s0.pz
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function META:BeginStep(dt)
	Constraint.BeginStep(self, dt)
	local previous = self.Length

	if self.OscillationPeriod then
		self.OscillationTime = self.OscillationTime + dt
		self.Length = self.OscillationCenter + self.OscillationAmplitude * math.sin(2 * math.pi * self.OscillationTime / self.OscillationPeriod)
	elseif self.TargetLength then
		local step = self.LengthSpeed * dt
		self.Length = previous + math.clamp(self.TargetLength - previous, -step, step)
	end

	self.LengthRate = (self.Length - previous) / dt
end

function META:GetDirection(s0, s1)
	local dx, dy, dz = s1.px - s0.px, s1.py - s0.py, s1.pz - s0.pz
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)

	if length > physics_constants.EPSILON then
		local last = self.LastDirection
		last[1], last[2], last[3] = dx / length, dy / length, dz / length
		return last[1], last[2], last[3], length
	end

	local last = self.LastDirection
	return last[1], last[2], last[3], length
end

function META:WarmStart()
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	local nx, ny, nz = self:GetDirection(s0, s1)
	local impulse = self.Impulse
	rows.Apply(s1, 1, nx * impulse, ny * impulse, nz * impulse, 0, 0, 0)
	rows.Apply(s0, -1, nx * impulse, ny * impulse, nz * impulse, 0, 0, 0)
	self:AddLinearImpulse(nx * impulse, ny * impulse, nz * impulse)
end

function META:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	local nx, ny, nz, length = self:GetDirection(s0, s1)
	local gap = length - self.Length
	local unilateral = self.Unilateral
	local limit = self.MaxForce * dt
	local bias, mass_scale, impulse_scale
	local stiffness = self.Stiffness

	if stiffness > 0 then
		if unilateral and gap <= 0 then return end

		local inverse_mass = rows.GetLinearRowMass(s0, s1, nx, ny, nz)

		if inverse_mass == 0 then return end

		local bias_rate
		bias_rate, mass_scale, impulse_scale = rows.GetSpringSoftness(stiffness, self.Damping, inverse_mass, dt)
		bias = bias_rate * gap
	elseif unilateral then
		bias, mass_scale, impulse_scale = rows.GetLimitSoftness(
			-gap,
			dt,
			relax,
			joint_bias_rate,
			1 - joint_impulse_scale,
			joint_impulse_scale,
			relax and 0 or -rows.GetPreSolveLinearSpeed(s0, s1, nx, ny, nz)
		)
		bias = -bias
	elseif relax then
		bias, mass_scale, impulse_scale = 0, 1, 0
	else
		bias, mass_scale, impulse_scale = joint_bias_rate * gap, 1 - joint_impulse_scale, joint_impulse_scale
	end

	local before = self.Impulse
	self.Impulse = rows.LinearRow(
		s0,
		s1,
		nx,
		ny,
		nz,
		self.LengthRate,
		bias,
		mass_scale,
		impulse_scale,
		before,
		-limit,
		unilateral and 0 or limit
	)
	local delta = self.Impulse - before
	self:AddLinearImpulse(nx * delta, ny * delta, nz * delta)
end

return META:Register()
