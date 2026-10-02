local Constraint = import("goluwa/physics/constraint.lua")
local rows = import("goluwa/physics/constraint_rows.lua")
local objects = import("goluwa/objects/objects.lua")
-- Revolute joint: three rows pin the anchors together, two keep the hinge axes
-- parallel, leaving one free rotation about the axis. The free rotation can be
-- limited, driven by a motor and slowed by friction.
local META = objects.CreateTemplate("physics_hinge_constraint")
META.Base = Constraint
local INFINITY = math.huge

-- config: CollideConnected (default false), LowerAngle and UpperAngle (radians
-- from the pose at creation), MotorSpeed with MaxMotorTorque, Friction (torque),
-- BreakForce, BreakTorque
function META.New(body_0, body_1, world_anchor, world_axis, config)
	config = config or {}
	local self = META:CreateObject{
		CollideConnected = config.CollideConnected or false,
		BreakForce = config.BreakForce,
		BreakTorque = config.BreakTorque,
		LowerAngle = config.LowerAngle,
		UpperAngle = config.UpperAngle,
		MotorSpeed = config.MotorSpeed or 0,
		MaxMotorTorque = config.MaxMotorTorque or 0,
		Friction = config.Friction or 0,
		Angle = 0,
		RawAngle = 0,
		FrictionImpulse = 0,
		MotorImpulse = 0,
		LowerImpulse = 0,
		UpperImpulse = 0,
		PointImpulse = {0, 0, 0},
		AxisImpulse = {0, 0, 0},
	}
	return self:SetupFrames(body_0, body_1, world_anchor, rows.FrameFromAxis(world_axis))
end

function META:SetLimits(lower, upper)
	self.LowerAngle = lower
	self.UpperAngle = upper
	return self
end

function META:SetMotor(speed, max_torque)
	self.MotorSpeed = speed
	self.MaxMotorTorque = max_torque
	return self
end

function META:SetFriction(torque)
	self.Friction = torque
	return self
end

function META:WarmStart()
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	-- the angle only changes between substeps, the limit rows read it
	self:UpdateAngle(s0, s1)
	local point = self.PointImpulse
	local axis = self.AxisImpulse
	local along = self.FrictionImpulse + self.MotorImpulse + self.LowerImpulse - self.UpperImpulse
	local ax, ay, az = s0.xx * along, s0.xy * along, s0.xz * along
	rows.WarmStartPoint(s0, s1, point)
	rows.WarmStartAngular(s0, s1, axis)
	rows.Apply(s1, 1, 0, 0, 0, ax, ay, az)
	rows.Apply(s0, -1, 0, 0, 0, ax, ay, az)
	self:AddLinearImpulse(point[1], point[2], point[3])
	self:AddAngularImpulse(axis[1] + ax, axis[2] + ay, axis[3] + az)
end

-- the angle about the axis, accumulated over turns, 0 in the pose at creation
function META:UpdateAngle(s0, s1)
	local raw = rows.GetTwist(s0, s1)
	local delta = raw - self.RawAngle

	if delta > math.pi then
		delta = delta - 2 * math.pi
	elseif delta < -math.pi then
		delta = delta + 2 * math.pi
	end

	self.RawAngle = raw
	self.Angle = self.Angle + delta
	return self.Angle
end

function META:GetAngle()
	return self:UpdateAngle(self:LoadStates())
end

function META:GetAxisError()
	local s0, s1 = self:LoadStates()
	local ex = s0.xy * s1.xz - s0.xz * s1.xy
	local ey = s0.xz * s1.xx - s0.xx * s1.xz
	local ez = s0.xx * s1.xy - s0.xy * s1.xx
	return math.sqrt(ex * ex + ey * ey + ez * ez)
end

function META:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	local bias_rate = relax and 0 or joint_bias_rate
	local mass_scale = relax and 1 or 1 - joint_impulse_scale
	local ax, ay, az = s0.xx, s0.xy, s0.xz
	local friction = self.Friction

	if friction > 0 then
		local limit = friction * dt
		local before = self.FrictionImpulse
		self.FrictionImpulse = rows.AngularRow(s0, s1, ax, ay, az, 0, 0, 1, 0, before, -limit, limit)
		local delta = self.FrictionImpulse - before
		self:AddAngularImpulse(ax * delta, ay * delta, az * delta)
	end

	local max_motor_torque = self.MaxMotorTorque

	if max_motor_torque > 0 then
		local limit = max_motor_torque * dt
		local before = self.MotorImpulse
		self.MotorImpulse = rows.AngularRow(s0, s1, ax, ay, az, self.MotorSpeed, 0, 1, 0, before, -limit, limit)
		local delta = self.MotorImpulse - before
		self:AddAngularImpulse(ax * delta, ay * delta, az * delta)
	end

	local lower = self.LowerAngle
	local upper = self.UpperAngle

	if lower or upper then
		local angle = self:UpdateAngle(s0, s1)
		local soft_mass_scale = 1 - joint_impulse_scale

		if lower then
			local bias, scale, impulse_scale = rows.GetLimitSoftness(
				angle - lower,
				dt,
				relax,
				joint_bias_rate,
				soft_mass_scale,
				joint_impulse_scale,
				relax and 0 or rows.GetPreSolveAngularSpeed(s0, s1, ax, ay, az)
			)
			local before = self.LowerImpulse
			self.LowerImpulse = rows.AngularRow(s0, s1, ax, ay, az, 0, bias, scale, impulse_scale, before, 0, INFINITY)
			local delta = self.LowerImpulse - before
			self:AddAngularImpulse(ax * delta, ay * delta, az * delta)
		end

		if upper then
			local bias, scale, impulse_scale = rows.GetLimitSoftness(
				upper - angle,
				dt,
				relax,
				joint_bias_rate,
				soft_mass_scale,
				joint_impulse_scale,
				relax and 0 or -rows.GetPreSolveAngularSpeed(s0, s1, ax, ay, az)
			)
			local before = self.UpperImpulse
			self.UpperImpulse = rows.AngularRow(s0, s1, -ax, -ay, -az, 0, bias, scale, impulse_scale, before, 0, INFINITY)
			local delta = self.UpperImpulse - before
			self:AddAngularImpulse(-ax * delta, -ay * delta, -az * delta)
		end
	end

	local impulse_scale = relax and 0 or joint_impulse_scale
	local lx, ly, lz = rows.SolvePoint(s0, s1, bias_rate, mass_scale, impulse_scale, self.PointImpulse)
	self:AddLinearImpulse(lx, ly, lz)
	lx, ly, lz = rows.SolveAxisAlign(
		s0,
		s1,
		ax,
		ay,
		az,
		s1.xx,
		s1.xy,
		s1.xz,
		bias_rate,
		mass_scale,
		impulse_scale,
		self.AxisImpulse
	)
	self:AddAngularImpulse(lx, ly, lz)
end

return META:Register()
