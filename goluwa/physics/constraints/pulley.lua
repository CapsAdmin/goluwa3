local Constraint = import("goluwa/physics/constraint.lua")
local rows = import("goluwa/physics/constraint_rows.lua")
local objects = import("goluwa/objects/objects.lua")
-- A rope over two fixed pulley points: length0 + ratio * length1 stays at the
-- total it had when the joint was created, where length0 runs from the first
-- pulley point to the anchor on body 0 and length1 from the second to body 1.
-- A rope pulley (the default) only pulls; Rigid also pushes.
local META = objects.CreateTemplate("physics_pulley_constraint")
META.Base = Constraint
META.CollideConnected = true
local INFINITY = math.huge

-- config: Ratio (default 1), Rigid, CollideConnected (default true), BreakForce
function META.New(body_0, body_1, ground_0, ground_1, anchor_0, anchor_1, config)
	config = config or {}
	local ratio = config.Ratio or 1
	local self = META:CreateObject{
		Ground0 = ground_0:Copy(),
		Ground1 = ground_1:Copy(),
		Ratio = ratio,
		Rigid = config.Rigid or false,
		CollideConnected = config.CollideConnected ~= false,
		BreakForce = config.BreakForce,
		TotalLength = (anchor_0 - ground_0):GetLength() + ratio * (anchor_1 - ground_1):GetLength(),
		Impulse = 0,
	}
	return self:SetupFrames(body_0, body_1, anchor_0, nil, anchor_1)
end

function META:WarmStart()
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	local g0, g1 = self.Ground0, self.Ground1
	local ratio = self.Ratio
	local impulse = self.Impulse
	local d0x, d0y, d0z = s0.px - g0.x, s0.py - g0.y, s0.pz - g0.z
	local d1x, d1y, d1z = s1.px - g1.x, s1.py - g1.y, s1.pz - g1.z
	local length_0 = math.sqrt(d0x * d0x + d0y * d0y + d0z * d0z)
	local length_1 = math.sqrt(d1x * d1x + d1y * d1y + d1z * d1z)

	if length_0 < 1e-6 or length_1 < 1e-6 then return end

	rows.Apply(
		s0,
		1,
		-d0x / length_0 * impulse,
		-d0y / length_0 * impulse,
		-d0z / length_0 * impulse,
		0,
		0,
		0
	)
	rows.Apply(
		s1,
		1,
		-d1x / length_1 * ratio * impulse,
		-d1y / length_1 * ratio * impulse,
		-d1z / length_1 * ratio * impulse,
		0,
		0,
		0
	)
	self:AddLinearImpulse(d0x / length_0 * impulse, d0y / length_0 * impulse, d0z / length_0 * impulse)
end

function META:GetLengths()
	local s0, s1 = self:LoadStates()
	local g0, g1 = self.Ground0, self.Ground1
	return math.sqrt((s0.px - g0.x) ^ 2 + (s0.py - g0.y) ^ 2 + (s0.pz - g0.z) ^ 2),
	math.sqrt((s1.px - g1.x) ^ 2 + (s1.py - g1.y) ^ 2 + (s1.pz - g1.z) ^ 2)
end

function META:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self:Prepare() then return end

	local s0, s1 = self.State0, self.State1
	local g0, g1 = self.Ground0, self.Ground1
	local ratio = self.Ratio
	local d0x, d0y, d0z = s0.px - g0.x, s0.py - g0.y, s0.pz - g0.z
	local length_0 = math.sqrt(d0x * d0x + d0y * d0y + d0z * d0z)
	local d1x, d1y, d1z = s1.px - g1.x, s1.py - g1.y, s1.pz - g1.z
	local length_1 = math.sqrt(d1x * d1x + d1y * d1y + d1z * d1z)

	if length_0 < 1e-6 or length_1 < 1e-6 then return end

	-- g is positive while the rope has slack; the tension is the impulse
	-- along the gradient of g, which pulls both anchors toward their pulleys
	local gap = self.TotalLength - (length_0 + ratio * length_1)
	d0x, d0y, d0z = d0x / length_0, d0y / length_0, d0z / length_0
	d1x, d1y, d1z = d1x / length_1, d1y / length_1, d1z / length_1
	-- the anchors are separate points, so each side is its own one body row
	local inverse_mass = 0

	if s0.body then
		local cx = s0.ry * d0z - s0.rz * d0y
		local cy = s0.rz * d0x - s0.rx * d0z
		local cz = s0.rx * d0y - s0.ry * d0x
		local ux, uy, uz = rows.MulInertia(s0, cx, cy, cz)
		inverse_mass = s0.inverse_mass + cx * ux + cy * uy + cz * uz
	end

	if s1.body then
		local cx = s1.ry * d1z - s1.rz * d1y
		local cy = s1.rz * d1x - s1.rx * d1z
		local cz = s1.rx * d1y - s1.ry * d1x
		local ux, uy, uz = rows.MulInertia(s1, cx, cy, cz)
		inverse_mass = inverse_mass + ratio * ratio * (s1.inverse_mass + cx * ux + cy * uy + cz * uz)
	end

	if inverse_mass == 0 then return end

	local speed = 0
	local pre_speed = 0

	if s0.moving_body then
		local body = s0.moving_body
		local v, w = body.Velocity, body.AngularVelocity
		speed = speed + d0x * (
				v.x + w.y * s0.rz - w.z * s0.ry
			) + d0y * (
				v.y + w.z * s0.rx - w.x * s0.rz
			) + d0z * (
				v.z + w.x * s0.ry - w.y * s0.rx
			)

		if not relax then
			v = body.HasSolverVelocity0 and body.SolverVelocity0 or v
			w = body.HasSolverVelocity0 and body.SolverAngularVelocity0 or w
			pre_speed = pre_speed + d0x * (
					v.x + w.y * s0.rz - w.z * s0.ry
				) + d0y * (
					v.y + w.z * s0.rx - w.x * s0.rz
				) + d0z * (
					v.z + w.x * s0.ry - w.y * s0.rx
				)
		end
	end

	if s1.moving_body then
		local body = s1.moving_body
		local v, w = body.Velocity, body.AngularVelocity
		speed = speed + ratio * (
				d1x * (
					v.x + w.y * s1.rz - w.z * s1.ry
				) + d1y * (
					v.y + w.z * s1.rx - w.x * s1.rz
				) + d1z * (
					v.z + w.x * s1.ry - w.y * s1.rx
				)
			)

		if not relax then
			v = body.HasSolverVelocity0 and body.SolverVelocity0 or v
			w = body.HasSolverVelocity0 and body.SolverAngularVelocity0 or w
			pre_speed = pre_speed + ratio * (
					d1x * (
						v.x + w.y * s1.rz - w.z * s1.ry
					) + d1y * (
						v.y + w.z * s1.rx - w.x * s1.rz
					) + d1z * (
						v.z + w.x * s1.ry - w.y * s1.rx
					)
				)
		end
	end

	local bias, mass_scale, impulse_scale
	local lo = -INFINITY

	if self.Rigid then
		if relax then
			bias, mass_scale, impulse_scale = 0, 1, 0
		else
			bias, mass_scale, impulse_scale = joint_bias_rate * gap, 1 - joint_impulse_scale, joint_impulse_scale
		end
	else
		bias, mass_scale, impulse_scale = rows.GetLimitSoftness(
			gap,
			dt,
			relax,
			joint_bias_rate,
			1 - joint_impulse_scale,
			joint_impulse_scale,
			-pre_speed
		)
		lo = 0
	end

	local before = self.Impulse
	local new = before - mass_scale * (bias - speed) / inverse_mass - impulse_scale * before

	if new < lo then new = lo end

	local delta = new - before
	self.Impulse = new

	if s0.body then
		rows.Apply(s0, 1, -d0x * delta, -d0y * delta, -d0z * delta, 0, 0, 0)
	end

	if s1.body then
		rows.Apply(s1, 1, -d1x * ratio * delta, -d1y * ratio * delta, -d1z * ratio * delta, 0, 0, 0)
	end

	self:AddLinearImpulse(d0x * delta, d0y * delta, d0z * delta)
end

return META:Register()
