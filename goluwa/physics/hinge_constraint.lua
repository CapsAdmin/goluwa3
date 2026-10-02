local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local constraint = import("goluwa/physics/constraint.lua")
local objects = import("goluwa/objects/objects.lua")
-- Revolute joint: 3 rows pin the anchors together, 2 rows keep the hinge axes
-- parallel, leaving one free rotation around the axis. Solved at velocity level
-- as a soft constraint, matching how contacts are solved: the biased call
-- feeds the anchor and axis error back as velocity, the relax calls are rigid.
local HingeConstraint = objects.CreateTemplate("physics_hinge_constraint")
local BASIS = Vec3()
local WORLD_VEC = Vec3()
local CONJUGATE = Quat()

local function new_state()
	return {
		inverse_mass = 0,
		inertia = {0, 0, 0, 0, 0, 0, 0, 0, 0},
		rx = 0,
		ry = 0,
		rz = 0,
		px = 0,
		py = 0,
		pz = 0,
		ax = 0,
		ay = 0,
		az = 0,
	}
end

local STATE_0 = new_state()
local STATE_1 = new_state()
local K = {0, 0, 0, 0, 0, 0, 0, 0, 0}

local function load_state(state, body, local_anchor, world_anchor, local_axis, world_axis)
	if not body or not body:HasSolverMass() then
		state.inverse_mass = 0
		local inertia = state.inertia

		for i = 1, 9 do
			inertia[i] = 0
		end

		state.body = nil
		state.position = nil
	else
		state.body = body
		state.inverse_mass = body.InverseMass
		local inertia = state.inertia

		for column = 0, 2 do
			BASIS.x, BASIS.y, BASIS.z = column == 0 and 1 or 0, column == 1 and 1 or 0, column == 2 and 1 or 0
			local d = body:GetAngularVelocityDelta(BASIS)
			inertia[1 + column] = d.x
			inertia[4 + column] = d.y
			inertia[7 + column] = d.z
		end
	end

	local position = body and body.Position

	if body then
		local rotation = body.Rotation
		Quat.SetVecMul(WORLD_VEC, rotation, local_anchor)
		state.px = position.x + WORLD_VEC.x
		state.py = position.y + WORLD_VEC.y
		state.pz = position.z + WORLD_VEC.z
		state.rx, state.ry, state.rz = WORLD_VEC.x, WORLD_VEC.y, WORLD_VEC.z
		Quat.SetVecMul(WORLD_VEC, rotation, local_axis)
		state.ax, state.ay, state.az = WORLD_VEC.x, WORLD_VEC.y, WORLD_VEC.z
	else
		state.px, state.py, state.pz = world_anchor.x, world_anchor.y, world_anchor.z
		state.rx, state.ry, state.rz = 0, 0, 0
		state.ax, state.ay, state.az = world_axis.x, world_axis.y, world_axis.z
	end
end

-- accumulates [r]x * I^-1 * [r]x^T (plus inverse mass) into K
local function add_point_mass(k, state)
	local im = state.inverse_mass

	if im == 0 and not state.body then return end

	local rx, ry, rz = state.rx, state.ry, state.rz
	local i = state.inertia
	-- B = I * [r]x^T ; [r]x^T = [[0, rz, -ry], [-rz, 0, rx], [ry, -rx, 0]]
	local b11 = -i[2] * rz + i[3] * ry
	local b12 = i[1] * rz - i[3] * rx
	local b13 = -i[1] * ry + i[2] * rx
	local b21 = -i[5] * rz + i[6] * ry
	local b22 = i[4] * rz - i[6] * rx
	local b23 = -i[4] * ry + i[5] * rx
	local b31 = -i[8] * rz + i[9] * ry
	local b32 = i[7] * rz - i[9] * rx
	local b33 = -i[7] * ry + i[8] * rx
	-- K += [r]x * B, [r]x = [[0, -rz, ry], [rz, 0, -rx], [-ry, rx, 0]]
	k[1] = k[1] + (-rz * b21 + ry * b31 + im)
	k[2] = k[2] + (-rz * b22 + ry * b32)
	k[3] = k[3] + (-rz * b23 + ry * b33)
	k[4] = k[4] + (rz * b11 - rx * b31)
	k[5] = k[5] + (rz * b12 - rx * b32 + im)
	k[6] = k[6] + (rz * b13 - rx * b33)
	k[7] = k[7] + (-ry * b11 + rx * b21)
	k[8] = k[8] + (-ry * b12 + rx * b22)
	k[9] = k[9] + (-ry * b13 + rx * b23 + im)
end

local function solve_3x3(k, bx, by, bz)
	local a, b, c, d, e, f, g, h, i = k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8], k[9]
	local c11 = e * i - f * h
	local c12 = c * h - b * i
	local c13 = b * f - c * e
	local det = a * c11 + d * c12 + g * c13

	if det < 1e-30 and det > -1e-30 then return 0, 0, 0 end

	local inv = 1 / det
	return (c11 * bx + c12 * by + c13 * bz) * inv,
	((f * g - d * i) * bx + (a * i - c * g) * by + (c * d - a * f) * bz) * inv,
	((d * h - e * g) * bx + (b * g - a * h) * by + (a * e - b * d) * bz) * inv
end

local function apply_velocity_impulse(state, sign, lx, ly, lz, ax, ay, az)
	local body = state.body

	if not body then return end

	local im = state.inverse_mass * sign
	local velocity = body.Velocity
	velocity.x = velocity.x + lx * im
	velocity.y = velocity.y + ly * im
	velocity.z = velocity.z + lz * im
	-- angular impulse = r x L + A
	local tx = state.ry * lz - state.rz * ly + ax
	local ty = state.rz * lx - state.rx * lz + ay
	local tz = state.rx * ly - state.ry * lx + az
	local i = state.inertia
	local angular = body.AngularVelocity
	angular.x = angular.x + sign * (i[1] * tx + i[2] * ty + i[3] * tz)
	angular.y = angular.y + sign * (i[4] * tx + i[5] * ty + i[6] * tz)
	angular.z = angular.z + sign * (i[7] * tx + i[8] * ty + i[9] * tz)
end

local function body_angular_dot(state, t1x, t1y, t1z, t2x, t2y, t2z, out, index)
	local i = state.inertia
	local x = i[1] * t2x + i[2] * t2y + i[3] * t2z
	local y = i[4] * t2x + i[5] * t2y + i[6] * t2z
	local z = i[7] * t2x + i[8] * t2y + i[9] * t2z
	out[index] = out[index] + t1x * x + t1y * y + t1z * z
end

local K2 = {0, 0, 0, 0}

local function build_axis_rows(state_0, state_1)
	local ax, ay, az = state_0.ax, state_0.ay, state_0.az
	local hx, hy, hz = 1, 0, 0

	if ax > 0.9 or ax < -0.9 then hx, hy = 0, 1 end

	local t1x = ay * hz - az * hy
	local t1y = az * hx - ax * hz
	local t1z = ax * hy - ay * hx
	local length = math.sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
	t1x, t1y, t1z = t1x / length, t1y / length, t1z / length
	local t2x = ay * t1z - az * t1y
	local t2y = az * t1x - ax * t1z
	local t2z = ax * t1y - ay * t1x
	K2[1], K2[2], K2[3], K2[4] = 0, 0, 0, 0

	if state_0.body then
		body_angular_dot(state_0, t1x, t1y, t1z, t1x, t1y, t1z, K2, 1)
		body_angular_dot(state_0, t1x, t1y, t1z, t2x, t2y, t2z, K2, 2)
		body_angular_dot(state_0, t2x, t2y, t2z, t1x, t1y, t1z, K2, 3)
		body_angular_dot(state_0, t2x, t2y, t2z, t2x, t2y, t2z, K2, 4)
	end

	if state_1.body then
		body_angular_dot(state_1, t1x, t1y, t1z, t1x, t1y, t1z, K2, 1)
		body_angular_dot(state_1, t1x, t1y, t1z, t2x, t2y, t2z, K2, 2)
		body_angular_dot(state_1, t2x, t2y, t2z, t1x, t1y, t1z, K2, 3)
		body_angular_dot(state_1, t2x, t2y, t2z, t2x, t2y, t2z, K2, 4)
	end

	return t1x, t1y, t1z, t2x, t2y, t2z
end

local function solve_2x2(a, b, c, d, x, y)
	local det = a * d - b * c

	if det < 1e-30 and det > -1e-30 then return 0, 0 end

	return (d * x - b * y) / det, (a * y - c * x) / det
end

local function get_relative_angular(state_0, state_1, tx, ty, tz)
	local result = 0

	if state_1.body then
		local w = state_1.body.AngularVelocity
		result = result + w.x * tx + w.y * ty + w.z * tz
	end

	if state_0.body then
		local w = state_0.body.AngularVelocity
		result = result - (w.x * tx + w.y * ty + w.z * tz)
	end

	return result
end

local function get_point_velocity(state, out_index, out)
	local body = state.body

	if not body then return end

	local v = body.Velocity
	local w = body.AngularVelocity
	out[1] = out[1] + out_index * (v.x + w.y * state.rz - w.z * state.ry)
	out[2] = out[2] + out_index * (v.y + w.z * state.rx - w.x * state.rz)
	out[3] = out[3] + out_index * (v.z + w.x * state.ry - w.y * state.rx)
end

local JV = {0, 0, 0}

function HingeConstraint:SetEnabled(enabled)
	self.Enabled = enabled ~= false
	return self
end

function HingeConstraint:BeginStep()
	return self
end

function HingeConstraint:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self.Enabled then return 0 end

	local body_0 = self.Body0
	local body_1 = self.Body1
	local awake_0 = body_0 and body_0:HasSolverMass()
	local awake_1 = body_1 and body_1:HasSolverMass()

	if not (awake_0 or awake_1) then return 0 end

	if awake_0 and not body_0.Awake and not (awake_1 and body_1.Awake) then
		return 0
	end

	if awake_1 and not body_1.Awake and not (awake_0 and body_0.Awake) then
		return 0
	end

	if awake_0 then body_0:Wake() end

	if awake_1 then body_1:Wake() end

	load_state(
		STATE_0,
		body_0,
		self.LocalAnchor0,
		self.WorldAnchor,
		self.LocalAxis0,
		self.WorldAxis
	)
	load_state(
		STATE_1,
		body_1,
		self.LocalAnchor1,
		self.WorldAnchor,
		self.LocalAxis1,
		self.WorldAxis
	)

	for i = 1, 9 do
		K[i] = 0
	end

	add_point_mass(K, STATE_0)
	add_point_mass(K, STATE_1)
	local bias_rate = relax and 0 or joint_bias_rate
	local mass_scale = relax and 1 or 1 - joint_impulse_scale
	-- point constraint, velocity level plus the anchor error as bias
	JV[1], JV[2], JV[3] = 0, 0, 0
	get_point_velocity(STATE_1, 1, JV)
	get_point_velocity(STATE_0, -1, JV)
	local lx, ly, lz = solve_3x3(
		K,
		-mass_scale * (JV[1] + bias_rate * (STATE_1.px - STATE_0.px)),
		-mass_scale * (JV[2] + bias_rate * (STATE_1.py - STATE_0.py)),
		-mass_scale * (JV[3] + bias_rate * (STATE_1.pz - STATE_0.pz))
	)
	apply_velocity_impulse(STATE_1, 1, lx, ly, lz, 0, 0, 0)
	apply_velocity_impulse(STATE_0, -1, lx, ly, lz, 0, 0, 0)
	-- axis alignment, velocity level; the error e = A x B is the bias
	local ex = STATE_0.ay * STATE_1.az - STATE_0.az * STATE_1.ay
	local ey = STATE_0.az * STATE_1.ax - STATE_0.ax * STATE_1.az
	local ez = STATE_0.ax * STATE_1.ay - STATE_0.ay * STATE_1.ax
	local t1x, t1y, t1z, t2x, t2y, t2z = build_axis_rows(STATE_0, STATE_1)
	local m1, m2 = solve_2x2(
		K2[1],
		K2[2],
		K2[3],
		K2[4],
		-mass_scale * (
				get_relative_angular(STATE_0, STATE_1, t1x, t1y, t1z) + bias_rate * (
					t1x * ex + t1y * ey + t1z * ez
				)
			),
		-mass_scale * (
				get_relative_angular(STATE_0, STATE_1, t2x, t2y, t2z) + bias_rate * (
					t2x * ex + t2y * ey + t2z * ez
				)
			)
	)
	local lax = t1x * m1 + t2x * m2
	local lay = t1y * m1 + t2y * m2
	local laz = t1z * m1 + t2z * m2
	apply_velocity_impulse(STATE_1, 1, 0, 0, 0, lax, lay, laz)
	apply_velocity_impulse(STATE_0, -1, 0, 0, 0, lax, lay, laz)
	return 0
end

function HingeConstraint:GetAnchorError()
	load_state(
		STATE_0,
		self.Body0,
		self.LocalAnchor0,
		self.WorldAnchor,
		self.LocalAxis0,
		self.WorldAxis
	)
	load_state(
		STATE_1,
		self.Body1,
		self.LocalAnchor1,
		self.WorldAnchor,
		self.LocalAxis1,
		self.WorldAxis
	)
	local dx, dy, dz = STATE_1.px - STATE_0.px, STATE_1.py - STATE_0.py, STATE_1.pz - STATE_0.pz
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function HingeConstraint:GetAxisError()
	load_state(
		STATE_0,
		self.Body0,
		self.LocalAnchor0,
		self.WorldAnchor,
		self.LocalAxis0,
		self.WorldAxis
	)
	load_state(
		STATE_1,
		self.Body1,
		self.LocalAnchor1,
		self.WorldAnchor,
		self.LocalAxis1,
		self.WorldAxis
	)
	local ex = STATE_0.ay * STATE_1.az - STATE_0.az * STATE_1.ay
	local ey = STATE_0.az * STATE_1.ax - STATE_0.ax * STATE_1.az
	local ez = STATE_0.ax * STATE_1.ay - STATE_0.ay * STATE_1.ax
	return math.sqrt(ex * ex + ey * ey + ez * ez)
end

local function to_local_direction(body, world_axis)
	Quat.SetConjugated(CONJUGATE, body.Rotation)
	return Quat.SetVecMul(Vec3(), CONJUGATE, world_axis)
end

-- config.CollideConnected: keep collisions between the two bodies (default false)
function HingeConstraint.New(body_0, body_1, world_anchor, world_axis, config)
	config = config or {}
	local axis = world_axis:GetNormalized()
	local self = HingeConstraint:CreateObject{
		Body0 = body_0,
		Body1 = body_1,
		Enabled = true,
		CollideConnected = config.CollideConnected or false,
	}

	if body_0 then
		self.LocalAnchor0 = body_0:WorldToLocal(world_anchor)
		self.LocalAxis0 = to_local_direction(body_0, axis)
	end

	if body_1 then
		self.LocalAnchor1 = body_1:WorldToLocal(world_anchor)
		self.LocalAxis1 = to_local_direction(body_1, axis)
	end

	if not (body_0 and body_1) then
		self.WorldAnchor = world_anchor:Copy()
		self.WorldAxis = axis
	end

	if body_0 and body_1 and not self.CollideConnected then
		body_0:IgnoreCollisionWith(body_1)
	end

	return constraint.Track(self)
end

function HingeConstraint:OnRemove()
	self.Enabled = false
	constraint.Untrack(self)

	if self.Body0 and self.Body1 and not self.CollideConnected then
		self.Body0:RestoreCollisionWith(self.Body1)
	end
end

return HingeConstraint:Register()
