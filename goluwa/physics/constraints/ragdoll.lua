local Constraint = import("goluwa/physics/constraint.lua")
local rows = import("goluwa/physics/constraint_rows.lua")
local objects = import("goluwa/objects/objects.lua")
-- Ball and socket with per axis angle limits, the shape of a ragdoll joint.
-- The x axis of the joint frame is the twist axis, the swing is limited about
-- the y and z axes. Each limit is an angle in radians from the pose at
-- creation; nil leaves that side free.
local META = objects.CreateTemplate("physics_ragdoll_constraint")
META.Base = Constraint
local INFINITY = math.huge
-- lower limit key, upper limit key, friction key of the three axes
local LIMIT_KEYS = {
	{"TwistMin", "TwistMax", "TwistFriction"},
	{"SwingYMin", "SwingYMax", "SwingFriction"},
	{"SwingZMin", "SwingZMax", "SwingFriction"},
}

-- config: CollideConnected (default false), TwistMin, TwistMax, SwingYMin,
-- SwingYMax, SwingZMin, SwingZMax, TwistFriction and SwingFriction (torque),
-- BreakForce, BreakTorque
function META.New(body_0, body_1, world_anchor, world_axis, config)
	config = config or {}
	local self = META:CreateObject{
		CollideConnected = config.CollideConnected or false,
		BreakForce = config.BreakForce,
		BreakTorque = config.BreakTorque,
		TwistMin = config.TwistMin,
		TwistMax = config.TwistMax,
		SwingYMin = config.SwingYMin,
		SwingYMax = config.SwingYMax,
		SwingZMin = config.SwingZMin,
		SwingZMax = config.SwingZMax,
		TwistFriction = config.TwistFriction or 0,
		SwingFriction = config.SwingFriction or 0,
		LowerImpulses = {0, 0, 0},
		UpperImpulses = {0, 0, 0},
		FrictionImpulses = {0, 0, 0},
		PointImpulse = {0, 0, 0},
	}
	return self:SetupFrames(body_0, body_1, world_anchor, rows.FrameFromAxis(world_axis))
end

function META:WarmStart()
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	local point = self.PointImpulse
	rows.WarmStartPoint(s0, s1, point)
	self:AddLinearImpulse(point[1], point[2], point[3])

	for axis = 1, 3 do
		local along = self.FrictionImpulses[axis] + self.LowerImpulses[axis] - self.UpperImpulses[axis]
		local ax, ay, az

		if axis == 1 then
			ax, ay, az = s0.xx, s0.xy, s0.xz
		elseif axis == 2 then
			ax, ay, az = s0.yx, s0.yy, s0.yz
		else
			ax, ay, az = s0.zx, s0.zy, s0.zz
		end

		ax, ay, az = ax * along, ay * along, az * along
		rows.Apply(s1, 1, 0, 0, 0, ax, ay, az)
		rows.Apply(s0, -1, 0, 0, 0, ax, ay, az)
		self:AddAngularImpulse(ax, ay, az)
	end
end

-- twist, swing about y, swing about z
function META:GetAngles()
	return rows.GetSwingTwist(self:LoadStates())
end

function META:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	local soft_mass_scale = 1 - joint_impulse_scale
	local angles_0, angles_1, angles_2 = rows.GetSwingTwist(s0, s1)

	for axis = 1, 3 do
		local keys = LIMIT_KEYS[axis]
		local ax, ay, az

		if axis == 1 then
			ax, ay, az = s0.xx, s0.xy, s0.xz
		elseif axis == 2 then
			ax, ay, az = s0.yx, s0.yy, s0.yz
		else
			ax, ay, az = s0.zx, s0.zy, s0.zz
		end

		local friction = self[keys[3]]

		if friction > 0 then
			local limit = friction * dt
			local before = self.FrictionImpulses[axis]
			local after = rows.AngularRow(s0, s1, ax, ay, az, 0, 0, 1, 0, before, -limit, limit)
			self.FrictionImpulses[axis] = after
			self:AddAngularImpulse(ax * (after - before), ay * (after - before), az * (after - before))
		end

		local angle = axis == 1 and angles_0 or axis == 2 and angles_1 or angles_2
		local lower = self[keys[1]]
		local upper = self[keys[2]]

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
			local before = self.LowerImpulses[axis]
			local after = rows.AngularRow(s0, s1, ax, ay, az, 0, bias, scale, impulse_scale, before, 0, INFINITY)
			self.LowerImpulses[axis] = after
			self:AddAngularImpulse(ax * (after - before), ay * (after - before), az * (after - before))
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
			local before = self.UpperImpulses[axis]
			local after = rows.AngularRow(s0, s1, -ax, -ay, -az, 0, bias, scale, impulse_scale, before, 0, INFINITY)
			self.UpperImpulses[axis] = after
			self:AddAngularImpulse(-ax * (after - before), -ay * (after - before), -az * (after - before))
		end
	end

	local lx, ly, lz = rows.SolvePoint(
		s0,
		s1,
		relax and 0 or joint_bias_rate,
		relax and 1 or soft_mass_scale,
		relax and 0 or joint_impulse_scale,
		self.PointImpulse
	)
	self:AddLinearImpulse(lx, ly, lz)
end

return META:Register()
