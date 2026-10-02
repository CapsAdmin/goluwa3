local Constraint = import("goluwa/physics/constraint.lua")
local rows = import("goluwa/physics/constraint_rows.lua")
local objects = import("goluwa/objects/objects.lua")
-- Pins one point of each body together; the bodies rotate freely about it.
local META = objects.CreateTemplate("physics_ball_socket_constraint")
META.Base = Constraint

-- config: CollideConnected (default false), BreakForce
function META.New(body_0, body_1, world_anchor, config)
	config = config or {}
	local self = META:CreateObject{
		CollideConnected = config.CollideConnected or false,
		BreakForce = config.BreakForce,
		PointImpulse = {0, 0, 0},
	}
	return self:SetupFrames(body_0, body_1, world_anchor)
end

function META:WarmStart()
	if not self:Prepare() then return end

	local acc = self.PointImpulse
	rows.WarmStartPoint(self.State0, self.State1, acc)
	self:AddLinearImpulse(acc[1], acc[2], acc[3])
end

function META:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self:Prepare() then return end

	local lx, ly, lz = rows.SolvePoint(
		self.State0,
		self.State1,
		relax and 0 or joint_bias_rate,
		relax and 1 or 1 - joint_impulse_scale,
		relax and 0 or joint_impulse_scale,
		self.PointImpulse
	)
	self:AddLinearImpulse(lx, ly, lz)
end

return META:Register()
