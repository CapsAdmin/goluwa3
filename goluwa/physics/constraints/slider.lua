local Constraint = import("goluwa/physics/constraint.lua")
local rows = import("goluwa/physics/constraint_rows.lua")
local objects = import("goluwa/objects/objects.lua")
-- Prismatic joint: the bodies slide along one axis and are locked in every
-- other direction. The travel can be limited, driven by a motor and slowed by
-- friction.
local META = objects.CreateTemplate("physics_slider_constraint")
META.Base = Constraint
local INFINITY = math.huge

-- config: CollideConnected (default false), LowerTranslation and
-- UpperTranslation (from the pose at creation), MotorSpeed with MaxMotorForce,
-- Friction (force), BreakForce, BreakTorque
function META.New(body_0, body_1, world_anchor, world_axis, config)
	config = config or {}
	local self = META:CreateObject{
		CollideConnected = config.CollideConnected or false,
		BreakForce = config.BreakForce,
		BreakTorque = config.BreakTorque,
		LowerTranslation = config.LowerTranslation,
		UpperTranslation = config.UpperTranslation,
		MotorSpeed = config.MotorSpeed or 0,
		MaxMotorForce = config.MaxMotorForce or 0,
		Friction = config.Friction or 0,
		FrictionImpulse = 0,
		MotorImpulse = 0,
		LowerImpulse = 0,
		UpperImpulse = 0,
		PlaneImpulse = {0, 0, 0},
		AngularImpulse = {0, 0, 0},
	}
	return self:SetupFrames(body_0, body_1, world_anchor, rows.FrameFromAxis(world_axis))
end

function META:SetLimits(lower, upper)
	self.LowerTranslation = lower
	self.UpperTranslation = upper
	return self
end

function META:SetMotor(speed, max_force)
	self.MotorSpeed = speed
	self.MaxMotorForce = max_force
	return self
end

function META:SetFriction(force)
	self.Friction = force
	return self
end

function META:WarmStart()
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	local plane = self.PlaneImpulse
	local angular = self.AngularImpulse
	local along = self.FrictionImpulse + self.MotorImpulse + self.LowerImpulse - self.UpperImpulse
	local ax, ay, az = s0.xx * along, s0.xy * along, s0.xz * along
	rows.WarmStartPoint(s0, s1, plane)
	rows.WarmStartAngular(s0, s1, angular)
	rows.Apply(s1, 1, ax, ay, az, 0, 0, 0)
	rows.Apply(s0, -1, ax, ay, az, 0, 0, 0)
	self:AddLinearImpulse(plane[1] + ax, plane[2] + ay, plane[3] + az)
	self:AddAngularImpulse(angular[1], angular[2], angular[3])
end

function META:GetTranslation()
	local s0, s1 = self:LoadStates()
	return (s1.px - s0.px) * s0.xx + (s1.py - s0.py) * s0.xy + (s1.pz - s0.pz) * s0.xz
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
		self.FrictionImpulse = rows.LinearRow(s0, s1, ax, ay, az, 0, 0, 1, 0, before, -limit, limit)
		local delta = self.FrictionImpulse - before
		self:AddLinearImpulse(ax * delta, ay * delta, az * delta)
	end

	local max_motor_force = self.MaxMotorForce

	if max_motor_force > 0 then
		local limit = max_motor_force * dt
		local before = self.MotorImpulse
		self.MotorImpulse = rows.LinearRow(s0, s1, ax, ay, az, self.MotorSpeed, 0, 1, 0, before, -limit, limit)
		local delta = self.MotorImpulse - before
		self:AddLinearImpulse(ax * delta, ay * delta, az * delta)
	end

	local lower = self.LowerTranslation
	local upper = self.UpperTranslation

	if lower or upper then
		local translation = (s1.px - s0.px) * ax + (s1.py - s0.py) * ay + (s1.pz - s0.pz) * az
		local soft_mass_scale = 1 - joint_impulse_scale

		if lower then
			local bias, scale, impulse_scale = rows.GetLimitSoftness(
				translation - lower,
				dt,
				relax,
				joint_bias_rate,
				soft_mass_scale,
				joint_impulse_scale,
				relax and 0 or rows.GetPreSolveLinearSpeed(s0, s1, ax, ay, az)
			)
			local before = self.LowerImpulse
			self.LowerImpulse = rows.LinearRow(s0, s1, ax, ay, az, 0, bias, scale, impulse_scale, before, 0, INFINITY)
			local delta = self.LowerImpulse - before
			self:AddLinearImpulse(ax * delta, ay * delta, az * delta)
		end

		if upper then
			local bias, scale, impulse_scale = rows.GetLimitSoftness(
				upper - translation,
				dt,
				relax,
				joint_bias_rate,
				soft_mass_scale,
				joint_impulse_scale,
				relax and 0 or -rows.GetPreSolveLinearSpeed(s0, s1, ax, ay, az)
			)
			local before = self.UpperImpulse
			self.UpperImpulse = rows.LinearRow(s0, s1, -ax, -ay, -az, 0, bias, scale, impulse_scale, before, 0, INFINITY)
			local delta = self.UpperImpulse - before
			self:AddLinearImpulse(-ax * delta, -ay * delta, -az * delta)
		end
	end

	local impulse_scale = relax and 0 or joint_impulse_scale
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
	lx, ly, lz = rows.SolveAngularLock(s0, s1, bias_rate, mass_scale, impulse_scale, self.AngularImpulse)
	self:AddAngularImpulse(lx, ly, lz)
end

return META:Register()
