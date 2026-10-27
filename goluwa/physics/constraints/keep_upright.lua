local Constraint = import("goluwa/physics/constraint.lua")
local rows = import("goluwa/physics/constraint_rows.lua")
local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("physics_keep_upright_constraint")
META.Base = Constraint
META.CollideConnected = true
local CONJUGATE = Quat()
local WORLD_AXIS = Vec3()
local ROLL_AXIS = Vec3()
local INFINITY = math.huge

function META.New(body, config)
	config = config or {}
	local world_axis = (config.WorldAxis or Vec3(0, 1, 0)):GetNormalized()
	local local_axis

	if config.LocalAxis then
		local_axis = config.LocalAxis:GetNormalized()
	else
		Quat.SetConjugated(CONJUGATE, body.Rotation)
		local_axis = Quat.SetVecMul(Vec3(), CONJUGATE, world_axis)
	end

	local self = META:CreateObject{
		LocalAxis = local_axis,
		TargetAxis = world_axis,
		LocalRollAxis = config.LocalRollAxis and config.LocalRollAxis:GetNormalized(),
		Hertz = config.Hertz,
		DampingRatio = config.DampingRatio or 1,
		MaxTorque = config.MaxTorque or INFINITY,
		Acc = {0, 0, 0},
		RollImpulse = 0,
	}
	return self:SetupFrames(nil, body, body.Position)
end

function META:WarmStart()
	if not self:Prepare() then return end

	if self.LocalRollAxis then
		local roll = Quat.SetVecMul(ROLL_AXIS, self.Body1.Rotation, self.LocalRollAxis)
		local impulse = self.RollImpulse
		rows.Apply(self.State1, 1, 0, 0, 0, roll.x * impulse, roll.y * impulse, roll.z * impulse)
		self:AddAngularImpulse(roll.x * impulse, roll.y * impulse, roll.z * impulse)
		return
	end

	local acc = self.Acc
	local target = self.TargetAxis
	rows.RemoveAxis(acc, target.x, target.y, target.z)
	rows.Apply(self.State1, 1, 0, 0, 0, acc[1], acc[2], acc[3])
	self:AddAngularImpulse(acc[1], acc[2], acc[3])
end

function META:SolveRoll(dt, relax, joint_bias_rate, joint_impulse_scale)
	local s0, s1 = self.State0, self.State1
	local rotation = self.Body1.Rotation
	local roll = Quat.SetVecMul(ROLL_AXIS, rotation, self.LocalRollAxis)
	local up = Quat.SetVecMul(WORLD_AXIS, rotation, self.LocalAxis)
	local target = self.TargetAxis
	local rx, ry, rz = roll.x, roll.y, roll.z
	local along = up.x * rx + up.y * ry + up.z * rz
	local ux, uy, uz = up.x - rx * along, up.y - ry * along, up.z - rz * along
	along = target.x * rx + target.y * ry + target.z * rz
	local tx, ty, tz = target.x - rx * along, target.y - ry * along, target.z - rz * along
	local angle = math.atan2(
		(uy * tz - uz * ty) * rx + (uz * tx - ux * tz) * ry + (ux * ty - uy * tx) * rz,
		ux * tx + uy * ty + uz * tz
	)
	local bias_rate, mass_scale, impulse_scale

	if self.Hertz then
		local omega = 2 * math.pi * self.Hertz
		local a1 = 2 * self.DampingRatio + dt * omega
		local a2 = dt * omega * a1
		local a3 = 1 / (1 + a2)
		bias_rate, mass_scale, impulse_scale = omega / a1, a2 * a3, a3
	elseif relax then
		bias_rate, mass_scale, impulse_scale = 0, 1, 0
	else
		bias_rate, mass_scale, impulse_scale = joint_bias_rate, 1 - joint_impulse_scale, joint_impulse_scale
	end

	local limit = self.MaxTorque * dt
	local before = self.RollImpulse
	self.RollImpulse = rows.AngularRow(
		s0,
		s1,
		rx,
		ry,
		rz,
		0,
		-bias_rate * angle,
		mass_scale,
		impulse_scale,
		before,
		-limit,
		limit
	)
	local delta = self.RollImpulse - before
	self:AddAngularImpulse(rx * delta, ry * delta, rz * delta)
end

function META:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self:Prepare() then return end

	if self.LocalRollAxis then
		return self:SolveRoll(dt, relax, joint_bias_rate, joint_impulse_scale)
	end

	local s0, s1 = self.State0, self.State1
	local target = self.TargetAxis
	local axis = Quat.SetVecMul(WORLD_AXIS, self.Body1.Rotation, self.LocalAxis)
	local acc = self.Acc
	local lx, ly, lz = rows.SolveAxisAlign(
		s0,
		s1,
		target.x,
		target.y,
		target.z,
		axis.x,
		axis.y,
		axis.z,
		relax and 0 or joint_bias_rate,
		relax and 1 or 1 - joint_impulse_scale,
		relax and 0 or joint_impulse_scale,
		acc
	)
	local limit = self.MaxTorque * dt
	local length = math.sqrt(acc[1] * acc[1] + acc[2] * acc[2] + acc[3] * acc[3])

	if length > limit then
		local scale = limit / length
		local cx, cy, cz = acc[1] * (scale - 1), acc[2] * (scale - 1), acc[3] * (scale - 1)
		rows.Apply(s1, 1, 0, 0, 0, cx, cy, cz)
		rows.Apply(s0, -1, 0, 0, 0, cx, cy, cz)
		acc[1], acc[2], acc[3] = acc[1] + cx, acc[2] + cy, acc[3] + cz
		lx, ly, lz = lx + cx, ly + cy, lz + cz
	end

	self:AddAngularImpulse(lx, ly, lz)
end

return META:Register()
