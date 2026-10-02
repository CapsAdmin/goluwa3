local Constraint = import("goluwa/physics/constraint.lua")
local rows = import("goluwa/physics/constraint_rows.lua")
local objects = import("goluwa/objects/objects.lua")
-- Locks two bodies together in the pose they had when it was created.
local META = objects.CreateTemplate("physics_weld_constraint")
META.Base = Constraint

-- config: CollideConnected (default false), BreakForce, BreakTorque
function META.New(body_0, body_1, world_anchor, config)
	config = config or {}
	local self = META:CreateObject{
		CollideConnected = config.CollideConnected or false,
		BreakForce = config.BreakForce,
		BreakTorque = config.BreakTorque,
		PointImpulse = {0, 0, 0},
		AngularImpulse = {0, 0, 0},
	}
	return self:SetupFrames(body_0, body_1, world_anchor)
end

function META:WarmStart()
	if not self:Prepare() then return end

	local point = self.PointImpulse
	local angular = self.AngularImpulse
	rows.WarmStartPoint(self.State0, self.State1, point)
	rows.WarmStartAngular(self.State0, self.State1, angular)
	self:AddLinearImpulse(point[1], point[2], point[3])
	self:AddAngularImpulse(angular[1], angular[2], angular[3])
end

function META:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self:Prepare() then return end

	local bias_rate = relax and 0 or joint_bias_rate
	local mass_scale = relax and 1 or 1 - joint_impulse_scale
	local impulse_scale = relax and 0 or joint_impulse_scale
	local ax, ay, az = rows.SolveAngularLock(
		self.State0,
		self.State1,
		bias_rate,
		mass_scale,
		impulse_scale,
		self.AngularImpulse
	)
	self:AddAngularImpulse(ax, ay, az)
	local lx, ly, lz = rows.SolvePoint(
		self.State0,
		self.State1,
		bias_rate,
		mass_scale,
		impulse_scale,
		self.PointImpulse
	)
	self:AddLinearImpulse(lx, ly, lz)
end

return META:Register()
