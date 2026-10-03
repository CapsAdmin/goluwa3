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
		MaxTorque = config.MaxTorque or INFINITY,
		Acc = {0, 0, 0},
	}
	return self:SetupFrames(nil, body, body.Position)
end

function META:WarmStart()
	if not self:Prepare() then return end

	local acc = self.Acc
	rows.Apply(self.State1, 1, 0, 0, 0, acc[1], acc[2], acc[3])
	self:AddAngularImpulse(acc[1], acc[2], acc[3])
end

function META:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self:Prepare() then return end

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
