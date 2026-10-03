local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local rows = {}
local BASIS = Vec3()
local WORLD_VEC = Vec3()
local FRAME = Quat()

function rows.NewState()
	return {
		inverse_mass = 0,
		inertia = {0, 0, 0, 0, 0, 0, 0, 0, 0},
		rx = 0,
		ry = 0,
		rz = 0,
		px = 0,
		py = 0,
		pz = 0,
		qx = 0,
		qy = 0,
		qz = 0,
		qw = 1,
		xx = 1,
		xy = 0,
		xz = 0,
		yx = 0,
		yy = 1,
		yz = 0,
		zx = 0,
		zy = 0,
		zz = 1,
	}
end

function rows.Load(state, body, local_anchor, local_frame, world_anchor, world_frame)
	local inertia = state.inertia

	if body and body:HasSolverMass() then
		state.body = body
		state.inverse_mass = body.InverseMass

		for column = 0, 2 do
			BASIS.x, BASIS.y, BASIS.z = column == 0 and 1 or 0, column == 1 and 1 or 0, column == 2 and 1 or 0
			local delta = body:GetAngularVelocityDelta(BASIS)
			inertia[1 + column] = delta.x
			inertia[4 + column] = delta.y
			inertia[7 + column] = delta.z
		end
	else
		state.body = nil
		state.inverse_mass = 0

		for i = 1, 9 do
			inertia[i] = 0
		end
	end

	state.moving_body = body

	if body then
		local rotation = body.Rotation
		Quat.SetVecMul(WORLD_VEC, rotation, local_anchor)
		state.rx, state.ry, state.rz = WORLD_VEC.x, WORLD_VEC.y, WORLD_VEC.z
		state.px = body.Position.x + WORLD_VEC.x
		state.py = body.Position.y + WORLD_VEC.y
		state.pz = body.Position.z + WORLD_VEC.z
		Quat.SetMul(FRAME, rotation, local_frame)
	else
		state.rx, state.ry, state.rz = 0, 0, 0
		state.px, state.py, state.pz = world_anchor.x, world_anchor.y, world_anchor.z
		FRAME.x, FRAME.y, FRAME.z, FRAME.w = world_frame.x, world_frame.y, world_frame.z, world_frame.w
	end

	local x, y, z, w = FRAME.x, FRAME.y, FRAME.z, FRAME.w
	state.qx, state.qy, state.qz, state.qw = x, y, z, w
	state.xx, state.xy, state.xz = 1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)
	state.yx, state.yy, state.yz = 2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)
	state.zx, state.zy, state.zz = 2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)
end

function rows.FrameFromAxis(axis)
	local ax, ay, az = axis.x, axis.y, axis.z
	local length = math.sqrt(ax * ax + ay * ay + az * az)
	ax, ay, az = ax / length, ay / length, az / length
	local hx, hy, hz = 0, 1, 0

	if ay > 0.9 or ay < -0.9 then hx, hy = 1, 0 end

	local zx, zy, zz = ay * hz - az * hy, az * hx - ax * hz, ax * hy - ay * hx
	length = math.sqrt(zx * zx + zy * zy + zz * zz)
	zx, zy, zz = zx / length, zy / length, zz / length
	local yx, yy, yz = zy * az - zz * ay, zz * ax - zx * az, zx * ay - zy * ax
	return rows.FrameFromAxes(ax, ay, az, yx, yy, yz, zx, zy, zz)
end

function rows.FrameFromAxes(xx, xy, xz, yx, yy, yz, zx, zy, zz)
	local trace = xx + yy + zz
	local q = Quat()

	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		q.w = 0.25 * s
		q.x = (yz - zy) / s
		q.y = (zx - xz) / s
		q.z = (xy - yx) / s
	elseif xx > yy and xx > zz then
		local s = math.sqrt(1 + xx - yy - zz) * 2
		q.w = (yz - zy) / s
		q.x = 0.25 * s
		q.y = (yx + xy) / s
		q.z = (zx + xz) / s
	elseif yy > zz then
		local s = math.sqrt(1 + yy - xx - zz) * 2
		q.w = (zx - xz) / s
		q.x = (yx + xy) / s
		q.y = 0.25 * s
		q.z = (zy + yz) / s
	else
		local s = math.sqrt(1 + zz - xx - yy) * 2
		q.w = (xy - yx) / s
		q.x = (zx + xz) / s
		q.y = (zy + yz) / s
		q.z = 0.25 * s
	end

	return q
end

local function mul_inertia(state, x, y, z)
	local i = state.inertia
	return i[1] * x + i[2] * y + i[3] * z,
	i[4] * x + i[5] * y + i[6] * z,
	i[7] * x + i[8] * y + i[9] * z
end

rows.MulInertia = mul_inertia

function rows.AddPointMass(k, state)
	local im = state.inverse_mass

	if not state.body then return end

	local rx, ry, rz = state.rx, state.ry, state.rz
	local i = state.inertia
	local b11 = -i[2] * rz + i[3] * ry
	local b12 = i[1] * rz - i[3] * rx
	local b13 = -i[1] * ry + i[2] * rx
	local b21 = -i[5] * rz + i[6] * ry
	local b22 = i[4] * rz - i[6] * rx
	local b23 = -i[4] * ry + i[5] * rx
	local b31 = -i[8] * rz + i[9] * ry
	local b32 = i[7] * rz - i[9] * rx
	local b33 = -i[7] * ry + i[8] * rx
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

function rows.AddAngularMass(k, state)
	if not state.body then return end

	local i = state.inertia

	for n = 1, 9 do
		k[n] = k[n] + i[n]
	end
end

function rows.Solve3(k, bx, by, bz)
	local det = k[1] * (
			k[5] * k[9] - k[6] * k[8]
		) + k[4] * (
			k[3] * k[8] - k[2] * k[9]
		) + k[7] * (
			k[2] * k[6] - k[3] * k[5]
		)

	if det < 1e-30 and det > -1e-30 then return 0, 0, 0 end

	det = 1 / det
	return (
			(
				k[5] * k[9] - k[6] * k[8]
			) * bx + (
				k[3] * k[8] - k[2] * k[9]
			) * by + (
				k[2] * k[6] - k[3] * k[5]
			) * bz
		) * det,
	(
			(
				k[6] * k[7] - k[4] * k[9]
			) * bx + (
				k[1] * k[9] - k[3] * k[7]
			) * by + (
				k[3] * k[4] - k[1] * k[6]
			) * bz
		) * det,
	(
			(
				k[4] * k[8] - k[5] * k[7]
			) * bx + (
				k[2] * k[7] - k[1] * k[8]
			) * by + (
				k[1] * k[5] - k[2] * k[4]
			) * bz
		) * det
end

function rows.Solve2(a, b, c, d, x, y)
	local det = a * d - b * c

	if det < 1e-30 and det > -1e-30 then return 0, 0 end

	return (d * x - b * y) / det, (a * y - c * x) / det
end

function rows.Apply(state, sign, lx, ly, lz, ax, ay, az)
	local body = state.body

	if not body then return end

	local im = state.inverse_mass * sign
	local velocity = body.Velocity
	velocity.x = velocity.x + lx * im
	velocity.y = velocity.y + ly * im
	velocity.z = velocity.z + lz * im
	local tx = state.ry * lz - state.rz * ly + ax
	local ty = state.rz * lx - state.rx * lz + ay
	local tz = state.rx * ly - state.ry * lx + az
	local i = state.inertia
	local angular = body.AngularVelocity
	angular.x = angular.x + sign * (i[1] * tx + i[2] * ty + i[3] * tz)
	angular.y = angular.y + sign * (i[4] * tx + i[5] * ty + i[6] * tz)
	angular.z = angular.z + sign * (i[7] * tx + i[8] * ty + i[9] * tz)
end

function rows.RelativePointVelocity(s0, s1)
	local x, y, z = 0, 0, 0
	local body = s1.moving_body

	if body then
		local v, w = body.Velocity, body.AngularVelocity
		x = v.x + w.y * s1.rz - w.z * s1.ry
		y = v.y + w.z * s1.rx - w.x * s1.rz
		z = v.z + w.x * s1.ry - w.y * s1.rx
	end

	body = s0.moving_body

	if body then
		local v, w = body.Velocity, body.AngularVelocity
		x = x - (v.x + w.y * s0.rz - w.z * s0.ry)
		y = y - (v.y + w.z * s0.rx - w.x * s0.rz)
		z = z - (v.z + w.x * s0.ry - w.y * s0.rx)
	end

	return x, y, z
end

function rows.RelativeAngularVelocity(s0, s1)
	local x, y, z = 0, 0, 0
	local body = s1.moving_body

	if body then
		local w = body.AngularVelocity
		x, y, z = w.x, w.y, w.z
	end

	body = s0.moving_body

	if body then
		local w = body.AngularVelocity
		x, y, z = x - w.x, y - w.y, z - w.z
	end

	return x, y, z
end

function rows.GetSwingTwist(s0, s1)
	local w = s0.qw * s1.qw + s0.qx * s1.qx + s0.qy * s1.qy + s0.qz * s1.qz
	local x = s0.qw * s1.qx - s0.qx * s1.qw - s0.qy * s1.qz + s0.qz * s1.qy
	local y = s0.qw * s1.qy - s0.qy * s1.qw - s0.qz * s1.qx + s0.qx * s1.qz
	local z = s0.qw * s1.qz - s0.qz * s1.qw - s0.qx * s1.qy + s0.qy * s1.qx

	if w < 0 then w, x, y, z = -w, -x, -y, -z end

	local twist_length = math.sqrt(x * x + w * w)
	local tx, tw = x / twist_length, w / twist_length
	local sw = w * tw + x * tx
	local sy = y * tw - z * tx
	local sz = z * tw + y * tx
	local length = math.sqrt(sy * sy + sz * sz)
	local scale = 0

	if length > 1e-9 then
		scale = 2 * math.atan2(length, sw) / length
	else
		scale = 2 / sw
	end

	return 2 * math.atan2(tx, tw), sy * scale, sz * scale
end

function rows.GetTwist(s0, s1)
	local w = s0.qw * s1.qw + s0.qx * s1.qx + s0.qy * s1.qy + s0.qz * s1.qz
	local x = s0.qw * s1.qx - s0.qx * s1.qw - s0.qy * s1.qz + s0.qz * s1.qy

	if w < 0 then w, x = -w, -x end

	return 2 * math.atan2(x, w)
end

local K = {0, 0, 0, 0, 0, 0, 0, 0, 0}
local K_ANGULAR = {0, 0, 0, 0, 0, 0, 0, 0, 0}

function rows.SolvePoint(s0, s1, bias_rate, mass_scale, impulse_scale, acc)
	for i = 1, 9 do
		K[i] = 0
	end

	rows.AddPointMass(K, s0)
	rows.AddPointMass(K, s1)
	local vx, vy, vz = rows.RelativePointVelocity(s0, s1)
	local lx, ly, lz = rows.Solve3(
		K,
		-mass_scale * (vx + bias_rate * (s1.px - s0.px)),
		-mass_scale * (vy + bias_rate * (s1.py - s0.py)),
		-mass_scale * (vz + bias_rate * (s1.pz - s0.pz))
	)
	lx, ly, lz = lx - impulse_scale * acc[1],
	ly - impulse_scale * acc[2],
	lz - impulse_scale * acc[3]
	rows.Apply(s1, 1, lx, ly, lz, 0, 0, 0)
	rows.Apply(s0, -1, lx, ly, lz, 0, 0, 0)
	acc[1], acc[2], acc[3] = acc[1] + lx, acc[2] + ly, acc[3] + lz
	return lx, ly, lz
end

function rows.WarmStartPoint(s0, s1, acc)
	rows.Apply(s1, 1, acc[1], acc[2], acc[3], 0, 0, 0)
	rows.Apply(s0, -1, acc[1], acc[2], acc[3], 0, 0, 0)
end

function rows.WarmStartAngular(s0, s1, acc)
	rows.Apply(s1, 1, 0, 0, 0, acc[1], acc[2], acc[3])
	rows.Apply(s0, -1, 0, 0, 0, acc[1], acc[2], acc[3])
end

function rows.GetRotationError(s0, s1)
	local w = s1.qw * s0.qw + s1.qx * s0.qx + s1.qy * s0.qy + s1.qz * s0.qz
	local x = -s1.qw * s0.qx + s1.qx * s0.qw - s1.qy * s0.qz + s1.qz * s0.qy
	local y = -s1.qw * s0.qy + s1.qy * s0.qw - s1.qz * s0.qx + s1.qx * s0.qz
	local z = -s1.qw * s0.qz + s1.qz * s0.qw - s1.qx * s0.qy + s1.qy * s0.qx

	if w < 0 then x, y, z = -x, -y, -z end

	return 2 * x, 2 * y, 2 * z
end

function rows.SolveAngularLock(s0, s1, bias_rate, mass_scale, impulse_scale, acc)
	for i = 1, 9 do
		K_ANGULAR[i] = 0
	end

	rows.AddAngularMass(K_ANGULAR, s0)
	rows.AddAngularMass(K_ANGULAR, s1)
	local wx, wy, wz = rows.RelativeAngularVelocity(s0, s1)
	local ex, ey, ez = rows.GetRotationError(s0, s1)
	local lx, ly, lz = rows.Solve3(
		K_ANGULAR,
		-mass_scale * (wx + bias_rate * ex),
		-mass_scale * (wy + bias_rate * ey),
		-mass_scale * (wz + bias_rate * ez)
	)
	lx, ly, lz = lx - impulse_scale * acc[1],
	ly - impulse_scale * acc[2],
	lz - impulse_scale * acc[3]
	rows.Apply(s1, 1, 0, 0, 0, lx, ly, lz)
	rows.Apply(s0, -1, 0, 0, 0, lx, ly, lz)
	acc[1], acc[2], acc[3] = acc[1] + lx, acc[2] + ly, acc[3] + lz
	return lx, ly, lz
end

local K2 = {0, 0, 0, 0}

function rows.SolveAxisAlign(s0, s1, ax, ay, az, bx, by, bz, bias_rate, mass_scale, impulse_scale, acc)
	local hx, hy, hz = 1, 0, 0

	if ax > 0.9 or ax < -0.9 then hx, hy = 0, 1 end

	local t1x, t1y, t1z = ay * hz - az * hy, az * hx - ax * hz, ax * hy - ay * hx
	local length = math.sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
	t1x, t1y, t1z = t1x / length, t1y / length, t1z / length
	local t2x, t2y, t2z = ay * t1z - az * t1y, az * t1x - ax * t1z, ax * t1y - ay * t1x
	K2[1], K2[2], K2[3], K2[4] = 0, 0, 0, 0

	for n = 0, 1 do
		local state = n == 0 and s0 or s1

		if state.body then
			local ux, uy, uz = mul_inertia(state, t1x, t1y, t1z)
			K2[1] = K2[1] + t1x * ux + t1y * uy + t1z * uz
			K2[2] = K2[2] + t2x * ux + t2y * uy + t2z * uz
			ux, uy, uz = mul_inertia(state, t2x, t2y, t2z)
			K2[3] = K2[3] + t1x * ux + t1y * uy + t1z * uz
			K2[4] = K2[4] + t2x * ux + t2y * uy + t2z * uz
		end
	end

	local ex, ey, ez = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
	local wx, wy, wz = rows.RelativeAngularVelocity(s0, s1)
	local m1, m2 = rows.Solve2(
		K2[1],
		K2[2],
		K2[3],
		K2[4],
		-mass_scale * (
				t1x * wx + t1y * wy + t1z * wz + bias_rate * (
					t1x * ex + t1y * ey + t1z * ez
				)
			),
		-mass_scale * (
				t2x * wx + t2y * wy + t2z * wz + bias_rate * (
					t2x * ex + t2y * ey + t2z * ez
				)
			)
	)
	m1 = m1 - impulse_scale * (t1x * acc[1] + t1y * acc[2] + t1z * acc[3])
	m2 = m2 - impulse_scale * (t2x * acc[1] + t2y * acc[2] + t2z * acc[3])
	local lx, ly, lz = t1x * m1 + t2x * m2, t1y * m1 + t2y * m2, t1z * m1 + t2z * m2
	rows.Apply(s1, 1, 0, 0, 0, lx, ly, lz)
	rows.Apply(s0, -1, 0, 0, 0, lx, ly, lz)
	acc[1], acc[2], acc[3] = acc[1] + lx, acc[2] + ly, acc[3] + lz
	return lx, ly, lz
end

function rows.SolvePointPlane(s0, s1, t1x, t1y, t1z, t2x, t2y, t2z, bias_rate, mass_scale, impulse_scale, acc)
	for i = 1, 9 do
		K[i] = 0
	end

	rows.AddPointMass(K, s0)
	rows.AddPointMass(K, s1)
	local k11 = t1x * (
			K[1] * t1x + K[2] * t1y + K[3] * t1z
		) + t1y * (
			K[4] * t1x + K[5] * t1y + K[6] * t1z
		) + t1z * (
			K[7] * t1x + K[8] * t1y + K[9] * t1z
		)
	local k12 = t1x * (
			K[1] * t2x + K[2] * t2y + K[3] * t2z
		) + t1y * (
			K[4] * t2x + K[5] * t2y + K[6] * t2z
		) + t1z * (
			K[7] * t2x + K[8] * t2y + K[9] * t2z
		)
	local k22 = t2x * (
			K[1] * t2x + K[2] * t2y + K[3] * t2z
		) + t2y * (
			K[4] * t2x + K[5] * t2y + K[6] * t2z
		) + t2z * (
			K[7] * t2x + K[8] * t2y + K[9] * t2z
		)
	local vx, vy, vz = rows.RelativePointVelocity(s0, s1)
	local dx, dy, dz = s1.px - s0.px, s1.py - s0.py, s1.pz - s0.pz
	local m1, m2 = rows.Solve2(
		k11,
		k12,
		k12,
		k22,
		-mass_scale * (
				t1x * vx + t1y * vy + t1z * vz + bias_rate * (
					t1x * dx + t1y * dy + t1z * dz
				)
			),
		-mass_scale * (
				t2x * vx + t2y * vy + t2z * vz + bias_rate * (
					t2x * dx + t2y * dy + t2z * dz
				)
			)
	)
	m1 = m1 - impulse_scale * (t1x * acc[1] + t1y * acc[2] + t1z * acc[3])
	m2 = m2 - impulse_scale * (t2x * acc[1] + t2y * acc[2] + t2z * acc[3])
	local lx, ly, lz = t1x * m1 + t2x * m2, t1y * m1 + t2y * m2, t1z * m1 + t2z * m2
	rows.Apply(s1, 1, lx, ly, lz, 0, 0, 0)
	rows.Apply(s0, -1, lx, ly, lz, 0, 0, 0)
	acc[1], acc[2], acc[3] = acc[1] + lx, acc[2] + ly, acc[3] + lz
	return lx, ly, lz
end

function rows.GetAngularRowMass(s0, s1, x, y, z)
	local result = 0

	if s0.body then
		local ux, uy, uz = mul_inertia(s0, x, y, z)
		result = result + x * ux + y * uy + z * uz
	end

	if s1.body then
		local ux, uy, uz = mul_inertia(s1, x, y, z)
		result = result + x * ux + y * uy + z * uz
	end

	return result
end

function rows.AngularRow(s0, s1, x, y, z, target, bias, mass_scale, impulse_scale, accumulated, lo, hi)
	local inverse_mass = rows.GetAngularRowMass(s0, s1, x, y, z)

	if inverse_mass == 0 then return accumulated end

	local wx, wy, wz = rows.RelativeAngularVelocity(s0, s1)
	local speed = wx * x + wy * y + wz * z
	local impulse = -mass_scale * (
			speed - target + bias
		) / inverse_mass - impulse_scale * accumulated
	local new = accumulated + impulse
	new = math.min(math.max(new, lo), hi)
	impulse = new - accumulated
	rows.Apply(s1, 1, 0, 0, 0, x * impulse, y * impulse, z * impulse)
	rows.Apply(s0, -1, 0, 0, 0, x * impulse, y * impulse, z * impulse)
	return new
end

function rows.GetLinearRowMass(s0, s1, x, y, z)
	local result = 0

	for n = 0, 1 do
		local state = n == 0 and s0 or s1

		if state.body then
			local cx = state.ry * z - state.rz * y
			local cy = state.rz * x - state.rx * z
			local cz = state.rx * y - state.ry * x
			local ux, uy, uz = mul_inertia(state, cx, cy, cz)
			result = result + state.inverse_mass + cx * ux + cy * uy + cz * uz
		end
	end

	return result
end

function rows.LinearRow(s0, s1, x, y, z, target, bias, mass_scale, impulse_scale, accumulated, lo, hi)
	local inverse_mass = rows.GetLinearRowMass(s0, s1, x, y, z)

	if inverse_mass == 0 then return accumulated end

	local vx, vy, vz = rows.RelativePointVelocity(s0, s1)
	local speed = vx * x + vy * y + vz * z
	local impulse = -mass_scale * (
			speed - target + bias
		) / inverse_mass - impulse_scale * accumulated
	local new = accumulated + impulse
	new = math.min(math.max(new, lo), hi)
	impulse = new - accumulated
	rows.Apply(s1, 1, x * impulse, y * impulse, z * impulse, 0, 0, 0)
	rows.Apply(s0, -1, x * impulse, y * impulse, z * impulse, 0, 0, 0)
	return new
end

function rows.GetSpringSoftness(stiffness, damping, inverse_mass, dt)
	local omega = math.sqrt(stiffness * inverse_mass)
	local zeta = damping * math.sqrt(inverse_mass) / (2 * math.sqrt(stiffness))
	local a1 = 2 * zeta + dt * omega
	local a2 = dt * omega * a1
	local a3 = 1 / (1 + a2)
	return omega / a1, a2 * a3, a3
end

function rows.GetPreSolveAngularSpeed(s0, s1, x, y, z)
	local result = 0
	local body = s1.moving_body

	if body then
		local w = body.HasSolverVelocity0 and body.SolverAngularVelocity0 or body.AngularVelocity
		result = w.x * x + w.y * y + w.z * z
	end

	body = s0.moving_body

	if body then
		local w = body.HasSolverVelocity0 and body.SolverAngularVelocity0 or body.AngularVelocity
		result = result - (w.x * x + w.y * y + w.z * z)
	end

	return result
end

function rows.GetPreSolveLinearSpeed(s0, s1, x, y, z)
	local result = 0

	for n = 0, 1 do
		local state = n == 0 and s0 or s1
		local body = state.moving_body

		if body then
			local v = body.HasSolverVelocity0 and body.SolverVelocity0 or body.Velocity
			local w = body.HasSolverVelocity0 and body.SolverAngularVelocity0 or body.AngularVelocity
			local speed = x * (
					v.x + w.y * state.rz - w.z * state.ry
				) + y * (
					v.y + w.z * state.rx - w.x * state.rz
				) + z * (
					v.z + w.x * state.ry - w.y * state.rx
				)
			result = result + (n == 0 and -speed or speed)
		end
	end

	return result
end

function rows.GetLimitSoftness(gap, dt, relax, bias_rate, soft_mass_scale, soft_impulse_scale, gap_rate)
	if relax then return math.max(gap, 0) / dt, 1, 0 end

	local start_gap = gap - gap_rate * dt

	if start_gap > 0 then return start_gap / dt, 1, 0 end

	return bias_rate * gap, soft_mass_scale, soft_impulse_scale
end

return rows
