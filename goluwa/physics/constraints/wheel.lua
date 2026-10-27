local Constraint = import("goluwa/physics/constraint.lua")
local rows = import("goluwa/physics/constraint_rows.lua")
local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("physics_wheel_constraint")
META.Base = Constraint
local INFINITY = math.huge

function META.New(body_0, body_1, world_anchor, world_suspension_axis, world_axle, config)
	config = config or {}
	local self = META:CreateObject{
		CollideConnected = config.CollideConnected or false,
		BreakForce = config.BreakForce,
		BreakTorque = config.BreakTorque,
		Stiffness = config.Stiffness or 0,
		Damping = config.Damping or 0,
		LowerTranslation = config.LowerTranslation,
		UpperTranslation = config.UpperTranslation,
		MotorSpeed = config.MotorSpeed or 0,
		MaxMotorTorque = config.MaxMotorTorque or 0,
		BrakeTorque = config.BrakeTorque or 0,
		SteerAngle = 0,
		SteerCos = 1,
		SteerSin = 0,
		SpringImpulse = 0,
		LowerImpulse = 0,
		UpperImpulse = 0,
		MotorImpulse = 0,
		BrakeImpulse = 0,
		PlaneImpulse = {0, 0, 0},
		AxisImpulse = {0, 0, 0},
	}
	local s = world_suspension_axis:GetNormalized()
	local a = world_axle - s * world_axle:GetDot(s)
	a:Normalize()
	local f = s:GetCross(a)
	return self:SetupFrames(
		body_0,
		body_1,
		world_anchor,
		rows.FrameFromAxes(s.x, s.y, s.z, a.x, a.y, a.z, f.x, f.y, f.z)
	)
end

function META:SetSteerAngle(angle)
	self.SteerAngle = angle
	self.SteerCos = math.cos(angle)
	self.SteerSin = math.sin(angle)
	return self
end

function META:GetSteerAngle()
	return self.SteerAngle
end

function META:SetSuspension(stiffness, damping)
	self.Stiffness = stiffness
	self.Damping = damping
	return self
end

function META:SetLimits(lower, upper)
	self.LowerTranslation = lower
	self.UpperTranslation = upper
	return self
end

function META:SetMotor(speed, max_torque)
	self.MotorSpeed = speed
	self.MaxMotorTorque = max_torque
	return self
end

function META:SetBrake(torque)
	self.BrakeTorque = torque
	return self
end

function META:GetSteeredAxle(s0)
	local c, s = self.SteerCos, self.SteerSin
	return s0.yx * c + s0.zx * s, s0.yy * c + s0.zy * s, s0.yz * c + s0.zz * s
end

function META:GetTranslation()
	local s0, s1 = self:LoadStates()
	return (s1.px - s0.px) * s0.xx + (s1.py - s0.py) * s0.xy + (s1.pz - s0.pz) * s0.xz
end

function META:GetSpinSpeed()
	local s0, s1 = self:LoadStates()
	local ax, ay, az = self:GetSteeredAxle(s0)
	local wx, wy, wz = rows.RelativeAngularVelocity(s0, s1)
	return wx * ax + wy * ay + wz * az
end

function META:GetSuspensionForce()
	return (self.SpringImpulse + self.LowerImpulse - self.UpperImpulse) / (self.StepDt or 1)
end

function META:BeginStep(dt)
	Constraint.BeginStep(self, dt)
	self.StepDt = dt
end

function META:WarmStart()
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	local sx, sy, sz = s0.xx, s0.xy, s0.xz
	local ax, ay, az = self:GetSteeredAxle(s0)
	local along = self.SpringImpulse + self.LowerImpulse - self.UpperImpulse
	local spin = self.MotorImpulse + self.BrakeImpulse
	local plane = self.PlaneImpulse
	local axis = self.AxisImpulse
	rows.RemoveAxis(plane, sx, sy, sz)
	rows.RemoveAxis(axis, ax, ay, az)
	rows.WarmStartPoint(s0, s1, plane)
	rows.WarmStartAngular(s0, s1, axis)
	rows.Apply(s1, 1, sx * along, sy * along, sz * along, ax * spin, ay * spin, az * spin)
	rows.Apply(s0, -1, sx * along, sy * along, sz * along, ax * spin, ay * spin, az * spin)
	self:AddLinearImpulse(plane[1] + sx * along, plane[2] + sy * along, plane[3] + sz * along)
	self:AddAngularImpulse(axis[1] + ax * spin, axis[2] + ay * spin, axis[3] + az * spin)
end

function META:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	local bias_rate = relax and 0 or joint_bias_rate
	local mass_scale = relax and 1 or 1 - joint_impulse_scale
	local impulse_scale = relax and 0 or joint_impulse_scale
	local sx, sy, sz = s0.xx, s0.xy, s0.xz
	local ax, ay, az = self:GetSteeredAxle(s0)
	local stiffness = self.Stiffness

	if stiffness > 0 then
		local inverse_mass = rows.GetLinearRowMass(s0, s1, sx, sy, sz)

		if inverse_mass > 0 then
			local translation = (s1.px - s0.px) * sx + (s1.py - s0.py) * sy + (s1.pz - s0.pz) * sz
			local rate, spring_mass_scale, spring_impulse_scale = rows.GetSpringSoftness(stiffness, self.Damping, inverse_mass, dt)
			local before = self.SpringImpulse
			self.SpringImpulse = rows.LinearRow(
				s0,
				s1,
				sx,
				sy,
				sz,
				0,
				rate * translation,
				spring_mass_scale,
				spring_impulse_scale,
				before,
				-INFINITY,
				INFINITY
			)
			local delta = self.SpringImpulse - before
			self:AddLinearImpulse(sx * delta, sy * delta, sz * delta)
		end
	end

	local lower = self.LowerTranslation
	local upper = self.UpperTranslation

	if lower or upper then
		local translation = (s1.px - s0.px) * sx + (s1.py - s0.py) * sy + (s1.pz - s0.pz) * sz
		local soft_mass_scale = 1 - joint_impulse_scale

		if lower then
			local bias, scale, limit_impulse_scale = rows.GetLimitSoftness(
				translation - lower,
				dt,
				relax,
				joint_bias_rate,
				soft_mass_scale,
				joint_impulse_scale,
				relax and 0 or rows.GetPreSolveLinearSpeed(s0, s1, sx, sy, sz)
			)
			local before = self.LowerImpulse
			self.LowerImpulse = rows.LinearRow(s0, s1, sx, sy, sz, 0, bias, scale, limit_impulse_scale, before, 0, INFINITY)
			local delta = self.LowerImpulse - before
			self:AddLinearImpulse(sx * delta, sy * delta, sz * delta)
		end

		if upper then
			local bias, scale, limit_impulse_scale = rows.GetLimitSoftness(
				upper - translation,
				dt,
				relax,
				joint_bias_rate,
				soft_mass_scale,
				joint_impulse_scale,
				relax and 0 or -rows.GetPreSolveLinearSpeed(s0, s1, sx, sy, sz)
			)
			local before = self.UpperImpulse
			self.UpperImpulse = rows.LinearRow(s0, s1, -sx, -sy, -sz, 0, bias, scale, limit_impulse_scale, before, 0, INFINITY)
			local delta = self.UpperImpulse - before
			self:AddLinearImpulse(-sx * delta, -sy * delta, -sz * delta)
		end
	end

	local max_motor_torque = self.MaxMotorTorque

	if max_motor_torque > 0 then
		local limit = max_motor_torque * dt
		local before = self.MotorImpulse
		self.MotorImpulse = rows.AngularRow(s0, s1, ax, ay, az, self.MotorSpeed, 0, 1, 0, before, -limit, limit)
		local delta = self.MotorImpulse - before
		self:AddAngularImpulse(ax * delta, ay * delta, az * delta)
	else
		self.MotorImpulse = 0
	end

	local brake_torque = self.BrakeTorque

	if brake_torque > 0 then
		local limit = brake_torque * dt
		local before = self.BrakeImpulse
		self.BrakeImpulse = rows.AngularRow(s0, s1, ax, ay, az, 0, 0, 1, 0, before, -limit, limit)
		local delta = self.BrakeImpulse - before
		self:AddAngularImpulse(ax * delta, ay * delta, az * delta)
	else
		self.BrakeImpulse = 0
	end

	local lx, ly, lz = rows.SolvePointPlane(
		s0,
		s1,
		s0.yx,
		s0.yy,
		s0.yz,
		s0.zx,
		s0.zy,
		s0.zz,
		bias_rate,
		mass_scale,
		impulse_scale,
		self.PlaneImpulse
	)
	self:AddLinearImpulse(lx, ly, lz)
	lx, ly, lz = rows.SolveAxisAlign(
		s0,
		s1,
		ax,
		ay,
		az,
		s1.yx,
		s1.yy,
		s1.yz,
		bias_rate,
		mass_scale,
		impulse_scale,
		self.AxisImpulse
	)
	self:AddAngularImpulse(lx, ly, lz)
end

return META:Register()
