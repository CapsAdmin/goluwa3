local ffi = require("ffi")
local physics_constants = import("goluwa/physics/constants.lua")
local motion = import("goluwa/physics/motion.lua")
local contact_store = import("goluwa/physics/contact_store.lua")
local contact_solver = {}
local EPSILON = physics_constants.EPSILON
local math_min = math.min
local math_max = math.max
local math_abs = math.abs
local math_sqrt = math.sqrt
local Contact = contact_store.Contact
local Body = ffi.typeof([[struct {
	double vx, vy, vz, wx, wy, wz;
	double px, py, pz;
	double i00, i01, i02, i10, i11, i12, i20, i21, i22;
	double r00, r01, r02, r10, r11, r12, r20, r21, r22;
	double pc;
	int movable, asleep;
}]])
local Man = ffi.typeof(
	[[struct {
	$ *cs;
	int a, b, rows;
	double nx, ny, nz;
	double pax, pay, paz, qax, qay, qaz, qaw;
	double pbx, pby, pbz, qbx, qby, qbz, qbw;
	double depth_offset;
	double pm_a, pm_b;
	double dyn, stat;
	double twist_mass, twist_impulse;
	double bias_rate[2], soft_mass_scale[2], soft_impulse_scale[2], spec[2];
	double pcorr;
	double restitution;
	int bounces, soft, persistent, resting, passes;
}]],
	Contact
)
local Params = ffi.typeof([[struct {
	double dt, slop, push, relax_gap, static_speed, static_exit_speed;
	double resting_rel_sq, resting_tan_sq, resting_ang_sq, resting_min_normal_y;
	double warm_scale, tangent_warm_scale, max_tangent_warm_sq, collide_stamp, touch_tolerance;
	int passes_base, passes_resting, resting_min_contacts;
}]])
local Task = ffi.typeof("struct { int m, k, kind, pass; }")
local TaskArray = ffi.typeof("$[?]", Task)
local BodyArray = ffi.typeof("$[?]", Body)
local ManArray = ffi.typeof("$[?]", Man)
local P = Params()
local body_capacity, man_capacity = 2048, 4096
local bodies = BodyArray(body_capacity)
local mans = ManArray(man_capacity)
local body_count, man_count, task_count = 0, 0, 0
local task_capacity = 16384
local tasks = TaskArray(task_capacity)
local body_objects = {}
local man_objects = {}
local body_stamp = 0

local function grow(array, ctype, used, capacity, needed)
	local new_capacity = capacity

	while new_capacity < needed do
		new_capacity = new_capacity * 2
	end

	local new_array = ctype(new_capacity)
	ffi.copy(new_array, array, used * ffi.sizeof(array[0]))
	return new_array, new_capacity
end

-- Solver constants for one substep.
local function configure(solver, dt)
	P.dt = dt
	P.slop = solver.PENETRATION_SLOP
	P.push = solver.CONTACT_PUSH_SPEED
	P.relax_gap = solver.RELAX_OPEN_GAP
	P.static_speed = solver.STATIC_FRICTION_SPEED
	P.static_exit_speed = solver.STATIC_FRICTION_EXIT_SPEED
	P.resting_rel_sq = solver.RESTING_MANIFOLD_MAX_RELATIVE_SPEED ^ 2
	P.resting_tan_sq = solver.RESTING_MANIFOLD_MAX_TANGENT_SPEED ^ 2
	P.resting_ang_sq = solver.RESTING_MANIFOLD_MAX_ANGULAR_SPEED ^ 2
	P.resting_min_normal_y = solver.RESTING_MANIFOLD_MIN_NORMAL_Y
	P.resting_min_contacts = solver.RESTING_MANIFOLD_MIN_CONTACTS
	P.passes_base = math_max(1, solver.MANIFOLD_SOLVER_PASSES)
	P.passes_resting = math_max(P.passes_base, solver.RESTING_MANIFOLD_SOLVER_PASSES)
	P.warm_scale = solver.WARM_START_SCALE
	P.tangent_warm_scale = solver.TANGENT_WARM_START_SCALE
	P.max_tangent_warm_sq = solver.MAX_TANGENT_WARM_SPEED ^ 2
	P.collide_stamp = solver.CollideStamp
	P.touch_tolerance = math_max(solver.PENETRATION_SLOP, 0.005)
	return math_min(solver.CONTACT_HERTZ, 0.25 / dt), solver.CONTACT_DAMPING_RATIO
end

local soft_hertz, soft_damping_ratio

-- Starts a substep: clears the batch and loads the solver constants every island shares.
function contact_solver.Begin(solver, dt)
	body_count, man_count, task_count = 0, 0, 0
	soft_hertz, soft_damping_ratio = configure(solver, dt)
end

function contact_solver.BeginGroup(group)
	body_stamp = body_stamp + 1
	group.first_man = man_count
	group.man_end = man_count
	group.first_body = body_count
	group.body_end = body_count
	group.first_task = task_count
	group.task_end = task_count
end

local function load_velocity(b, body)
	local v = body.Velocity
	local w = body.AngularVelocity
	b.vx, b.vy, b.vz = v.x, v.y, v.z
	b.wx, b.wy, b.wz = w.x, w.y, w.z
	b.pc = body.PositionCorrection
end

-- World inverse inertia is R * M * R^T, zero for bodies the solver must not move.
local function load_pose(b, body)
	local p = body.Position
	b.px, b.py, b.pz = p.x, p.y, p.z
	b.movable = body:HasSolverMass() and 1 or 0
	b.asleep = body.Awake == false and 1 or 0
	local q = body.Rotation
	local qx, qy, qz, qw = q.x, q.y, q.z, q.w
	b.r00, b.r01, b.r02 = 1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qw * qz), 2 * (qx * qz + qw * qy)
	b.r10, b.r11, b.r12 = 2 * (qx * qy + qw * qz), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qw * qx)
	b.r20, b.r21, b.r22 = 2 * (qx * qz - qw * qy), 2 * (qy * qz + qw * qx), 1 - 2 * (qx * qx + qy * qy)
	local m = body.InverseInertiaTensor
	b.i00 = b.r00 * m.m00 + b.r01 * m.m10 + b.r02 * m.m20
	b.i01 = b.r00 * m.m01 + b.r01 * m.m11 + b.r02 * m.m21
	b.i02 = b.r00 * m.m02 + b.r01 * m.m12 + b.r02 * m.m22
	b.i10 = b.r10 * m.m00 + b.r11 * m.m10 + b.r12 * m.m20
	b.i11 = b.r10 * m.m01 + b.r11 * m.m11 + b.r12 * m.m21
	b.i12 = b.r10 * m.m02 + b.r11 * m.m12 + b.r12 * m.m22
	b.i20 = b.r20 * m.m00 + b.r21 * m.m10 + b.r22 * m.m20
	b.i21 = b.r20 * m.m01 + b.r21 * m.m11 + b.r22 * m.m21
	b.i22 = b.r20 * m.m02 + b.r21 * m.m12 + b.r22 * m.m22
	local a0, a1, a2 = b.i00, b.i01, b.i02
	b.i00, b.i01, b.i02 = a0 * b.r00 + a1 * b.r01 + a2 * b.r02,
	a0 * b.r10 + a1 * b.r11 + a2 * b.r12,
	a0 * b.r20 + a1 * b.r21 + a2 * b.r22
	a0, a1, a2 = b.i10, b.i11, b.i12
	b.i10, b.i11, b.i12 = a0 * b.r00 + a1 * b.r01 + a2 * b.r02,
	a0 * b.r10 + a1 * b.r11 + a2 * b.r12,
	a0 * b.r20 + a1 * b.r21 + a2 * b.r22
	a0, a1, a2 = b.i20, b.i21, b.i22
	b.i20, b.i21, b.i22 = a0 * b.r00 + a1 * b.r01 + a2 * b.r02,
	a0 * b.r10 + a1 * b.r11 + a2 * b.r12,
	a0 * b.r20 + a1 * b.r21 + a2 * b.r22

	if b.movable == 0 then
		b.i00, b.i01, b.i02, b.i10, b.i11, b.i12, b.i20, b.i21, b.i22 = 0, 0, 0, 0, 0, 0, 0, 0, 0
	end
end

-- Registers a manifold in the island's batch. Only bookkeeping happens here, the contact math
-- runs in Prepare once every manifold of the island is known.
function contact_solver.Add(
	group,
	manifold_data,
	solve_a,
	solve_b,
	restitution,
	friction,
	static_friction,
	persistent
)
	if man_count + 1 > man_capacity then
		mans, man_capacity = grow(mans, ManArray, man_count, man_capacity, man_count + 1)
	end

	if body_count + 2 > body_capacity then
		bodies, body_capacity = grow(bodies, BodyArray, body_count, body_capacity, body_count + 2)
	end

	local root_a = solve_a:GetBody()
	local root_b = solve_b:GetBody()
	local slot_a, slot_b

	if root_a.SolverBatchStamp == body_stamp then
		slot_a = root_a.SolverBatchSlot
	else
		slot_a = body_count
		body_count = body_count + 1
		root_a.SolverBatchStamp = body_stamp
		root_a.SolverBatchSlot = slot_a
		body_objects[slot_a] = root_a
	end

	if root_b.SolverBatchStamp == body_stamp then
		slot_b = root_b.SolverBatchSlot
	else
		slot_b = body_count
		body_count = body_count + 1
		root_b.SolverBatchStamp = body_stamp
		root_b.SolverBatchSlot = slot_b
		body_objects[slot_b] = root_b
	end

	local m_index = man_count
	man_count = man_count + 1
	man_objects[m_index] = manifold_data
	local m = mans[m_index]
	local normal = manifold_data.normal
	local position, rotation
	manifold_data.simple_a = solve_a == root_a
	manifold_data.simple_b = solve_b == root_b

	if manifold_data.simple_a then
		position, rotation = root_a.Position, root_a.Rotation
	else
		position, rotation = solve_a:GetPosition(), solve_a:GetRotation()
	end

	m.cs = manifold_data.cs
	m.rows = manifold_data.n
	m.a, m.b = slot_a, slot_b
	m.nx, m.ny, m.nz = normal.x, normal.y, normal.z
	m.pax, m.pay, m.paz = position.x, position.y, position.z
	m.qax, m.qay, m.qaz, m.qaw = rotation.x, rotation.y, rotation.z, rotation.w

	if manifold_data.simple_b then
		position, rotation = root_b.Position, root_b.Rotation
	else
		position, rotation = solve_b:GetPosition(), solve_b:GetRotation()
	end

	m.pbx, m.pby, m.pbz = position.x, position.y, position.z
	m.qbx, m.qby, m.qbz, m.qbw = rotation.x, rotation.y, rotation.z, rotation.w
	m.depth_offset = manifold_data.depth_offset or 0
	local mass_a = root_a.MotionType == "dynamic" and root_a.InverseMass or 0
	local mass_b = root_b.MotionType == "dynamic" and root_b.InverseMass or 0
	manifold_data.prepared_mass_a = mass_a
	manifold_data.prepared_mass_b = mass_b
	m.pm_a, m.pm_b = mass_a, mass_b
	m.dyn, m.stat = friction, static_friction
	m.restitution = restitution
	m.bounces = restitution > 0 and 1 or 0
	m.persistent = persistent and 1 or 0
	m.soft = (
			not (
				(
					mass_a > 0 and
					root_a.Awake == false
				)
				or
				(
					mass_b > 0 and
					root_b.Awake == false
				)
			)
		) and
		1 or
		0
	group.man_end = man_count
	group.body_end = body_count
end

function contact_solver.Reload(group, with_pose)
	if with_pose then
		for i = group.first_body, group.body_end - 1 do
			load_velocity(bodies[i], body_objects[i])
			load_pose(bodies[i], body_objects[i])
		end
	else
		for i = group.first_body, group.body_end - 1 do
			load_velocity(bodies[i], body_objects[i])
		end
	end
end

function contact_solver.Store(group, dt)
	for i = group.first_body, group.body_end - 1 do
		local b = bodies[i]

		if b.movable == 1 then
			local body = body_objects[i]
			local v = body.Velocity
			local w = body.AngularVelocity
			v.x, v.y, v.z = b.vx, b.vy, b.vz
			w.x, w.y, w.z = b.wx, b.wy, b.wz
			body.PositionCorrection = b.pc

			if b.asleep == 1 then
				motion.SetBodyMotionFromCurrentState(body, v, w, dt)
			end
		end
	end
end

-- Contact anchors, effective masses, separation and the pre-solve normal speed of one manifold.
local function prepare_manifold(m, ba, bb)
	local cs = m.cs
	local last = m.rows - 1
	local nx, ny, nz = m.nx, m.ny, m.nz
	local centre_x, centre_y, centre_z = 0, 0, 0
	local min_separation = math.huge

	for i = 0, last do
		local c = cs[i]
		local lx, ly, lz = c.lax, c.lay, c.laz
		local tx = 2 * (m.qay * lz - m.qaz * ly)
		local ty = 2 * (m.qaz * lx - m.qax * lz)
		local tz = 2 * (m.qax * ly - m.qay * lx)
		local pax = m.pax + lx + m.qaw * tx + (m.qay * tz - m.qaz * ty)
		local pay = m.pay + ly + m.qaw * ty + (m.qaz * tx - m.qax * tz)
		local paz = m.paz + lz + m.qaw * tz + (m.qax * ty - m.qay * tx)
		c.wpx, c.wpy, c.wpz = pax, pay, paz
		centre_x, centre_y, centre_z = centre_x + pax, centre_y + pay, centre_z + paz
		lx, ly, lz = c.lbx, c.lby, c.lbz
		tx = 2 * (m.qby * lz - m.qbz * ly)
		ty = 2 * (m.qbz * lx - m.qbx * lz)
		tz = 2 * (m.qbx * ly - m.qby * lx)
		local pbx = m.pbx + lx + m.qbw * tx + (m.qby * tz - m.qbz * ty)
		local pby = m.pby + ly + m.qbw * ty + (m.qbz * tx - m.qbx * tz)
		local pbz = m.pbz + lz + m.qbw * tz + (m.qbx * ty - m.qby * tx)
		local depth = (pax - pbx) * nx + (pay - pby) * ny + (paz - pbz) * nz
		-- First substep after a rebuild: remember depth and starting separation, afterwards the
		-- separation follows the depth change.
		local first = 1 - c.has_base
		local start = c.has_sep * c.sep - (1 - c.has_sep) * (depth + m.depth_offset)
		c.base_sep = first * start + (1 - first) * c.base_sep
		c.base_depth = first * depth + (1 - first) * c.base_depth
		c.sep = c.base_sep - (depth - c.base_depth)
		c.has_sep, c.has_base = 1, 1
		min_separation = math_min(min_separation, c.sep)
		c.rax, c.ray, c.raz = pax - ba.px, pay - ba.py, paz - ba.pz
		c.cax, c.cay, c.caz = c.ray * nz - c.raz * ny, c.raz * nx - c.rax * nz, c.rax * ny - c.ray * nx
		c.wax = ba.i00 * c.cax + ba.i01 * c.cay + ba.i02 * c.caz
		c.way = ba.i10 * c.cax + ba.i11 * c.cay + ba.i12 * c.caz
		c.waz = ba.i20 * c.cax + ba.i21 * c.cay + ba.i22 * c.caz
		c.rbx, c.rby, c.rbz = pbx - bb.px, pby - bb.py, pbz - bb.pz
		c.cbx, c.cby, c.cbz = c.rby * nz - c.rbz * ny, c.rbz * nx - c.rbx * nz, c.rbx * ny - c.rby * nx
		c.wbx = bb.i00 * c.cbx + bb.i01 * c.cby + bb.i02 * c.cbz
		c.wby = bb.i10 * c.cbx + bb.i11 * c.cby + bb.i12 * c.cbz
		c.wbz = bb.i20 * c.cbx + bb.i21 * c.cby + bb.i22 * c.cbz
		c.nim = m.pm_a + c.cax * c.wax + c.cay * c.way + c.caz * c.waz + m.pm_b + c.cbx * c.wbx + c.cby * c.wby + c.cbz * c.wbz
		local v_pre = (
				bb.vx - ba.vx
			) * nx + (
				bb.vy - ba.vy
			) * ny + (
				bb.vz - ba.vz
			) * nz + bb.wx * c.cbx + bb.wy * c.cby + bb.wz * c.cbz - ba.wx * c.cax - ba.wy * c.cay - ba.wz * c.caz
		c.v_pre = v_pre

		if c.rest_stamp ~= P.collide_stamp then
			c.rest_stamp = P.collide_stamp
			c.rest_speed = v_pre
			c.rest_total = 0
			c.rest_impulse = 0
		end
	end

	centre_x, centre_y, centre_z = centre_x / m.rows, centre_y / m.rows, centre_z / m.rows

	for i = 0, last do
		local c = cs[i]
		local dx, dy, dz = c.wpx - centre_x, c.wpy - centre_y, c.wpz - centre_z
		c.lever = math_sqrt(dx * dx + dy * dy + dz * dz)
	end

	local twist_inverse_mass = nx * (
			ba.i00 * nx + ba.i01 * ny + ba.i02 * nz
		) + ny * (
			ba.i10 * nx + ba.i11 * ny + ba.i12 * nz
		) + nz * (
			ba.i20 * nx + ba.i21 * ny + ba.i22 * nz
		) + nx * (
			bb.i00 * nx + bb.i01 * ny + bb.i02 * nz
		) + ny * (
			bb.i10 * nx + bb.i11 * ny + bb.i12 * nz
		) + nz * (
			bb.i20 * nx + bb.i21 * ny + bb.i22 * nz
		)
	m.twist_mass = twist_inverse_mass > EPSILON and 1 / twist_inverse_mass or 0
	m.twist_impulse = 0
	return min_separation <= P.touch_tolerance
end

-- Orthonormal tangent frame for warm starting: the cached tangent projected onto the contact plane,
-- else an arbitrary one. Written to the row's t and b.
local function warm_frame(m, c)
	local nx, ny, nz = m.nx, m.ny, m.nz
	local px, py, pz, length = 0, 0, 0, 0

	if c.has_tangent == 1 then
		local dot = c.tx * nx + c.ty * ny + c.tz * nz
		px, py, pz = c.tx - nx * dot, c.ty - ny * dot, c.tz - nz * dot
		length = math_sqrt(px * px + py * py + pz * pz)
	end

	if length <= EPSILON then
		local ax, ay = 1, 0

		if math_abs(ny) < 0.9 then ax, ay = 0, 1 end

		local dot = ax * nx + ay * ny
		px, py, pz = ax - nx * dot, ay - ny * dot, -nz * dot
		length = math_sqrt(px * px + py * py + pz * pz)

		if length <= EPSILON then return false end
	end

	local inv = 1 / length
	px, py, pz = px * inv, py * inv, pz * inv
	local bx, by, bz = py * nz - pz * ny, pz * nx - px * nz, px * ny - py * nx

	if bx * bx + by * by + bz * bz <= EPSILON * EPSILON then
		local ax, ay = 1, 0

		if math_abs(ny) < 0.9 then ax, ay = 0, 1 end

		local dot = ax * nx + ay * ny
		px, py, pz = ax - nx * dot, ay - ny * dot, -nz * dot
		inv = 1 / math_sqrt(px * px + py * py + pz * pz)
		px, py, pz = px * inv, py * inv, pz * inv
		bx, by, bz = py * nz - pz * ny, pz * nx - px * nz, px * ny - py * nx
	end

	inv = 1 / math_sqrt(bx * bx + by * by + bz * bz)
	bx, by, bz = bx * inv, by * inv, bz * inv
	c.bx, c.by, c.bz = bx, by, bz
	local tx, ty, tz = ny * bz - nz * by, nz * bx - nx * bz, nx * by - ny * bx
	inv = 1 / math_sqrt(tx * tx + ty * ty + tz * tz)
	c.tx, c.ty, c.tz = tx * inv, ty * inv, tz * inv
	return true
end

-- Applies impulse * direction at the contact to both bodies (ia/ib are 0 for bodies that must not move).
local function apply_contact_impulse(m, c, ba, bb, ia, ib, dx, dy, dz, impulse)
	local scale = impulse * m.pm_a * ia
	ba.vx, ba.vy, ba.vz = ba.vx - dx * scale, ba.vy - dy * scale, ba.vz - dz * scale
	local ux, uy, uz = c.ray * dz - c.raz * dy, c.raz * dx - c.rax * dz, c.rax * dy - c.ray * dx
	scale = impulse * ia
	ba.wx = ba.wx - scale * (ba.i00 * ux + ba.i01 * uy + ba.i02 * uz)
	ba.wy = ba.wy - scale * (ba.i10 * ux + ba.i11 * uy + ba.i12 * uz)
	ba.wz = ba.wz - scale * (ba.i20 * ux + ba.i21 * uy + ba.i22 * uz)
	scale = impulse * m.pm_b * ib
	bb.vx, bb.vy, bb.vz = bb.vx + dx * scale, bb.vy + dy * scale, bb.vz + dz * scale
	ux, uy, uz = c.rby * dz - c.rbz * dy, c.rbz * dx - c.rbx * dz, c.rbx * dy - c.rby * dx
	scale = impulse * ib
	bb.wx = bb.wx + scale * (bb.i00 * ux + bb.i01 * uy + bb.i02 * uz)
	bb.wy = bb.wy + scale * (bb.i10 * ux + bb.i11 * uy + bb.i12 * uz)
	bb.wz = bb.wz + scale * (bb.i20 * ux + bb.i21 * uy + bb.i22 * uz)
end

local function warm_start_manifold(m, ba, bb)
	local cs = m.cs
	local ia = 1 - ba.asleep
	local ib = 1 - bb.asleep

	for i = 0, m.rows - 1 do
		local c = cs[i]
		local impulse = math_max(c.jn, 0) * P.warm_scale

		if impulse > EPSILON then
			apply_contact_impulse(m, c, ba, bb, ia, ib, m.nx, m.ny, m.nz, impulse)
		end

		local tangent_1 = c.jt1 * P.tangent_warm_scale
		local tangent_2 = c.jt2 * P.tangent_warm_scale
		c.jt1, c.jt2 = 0, 0

		if
			m.persistent == 1 and
			(
				math_abs(tangent_1) > EPSILON or
				math_abs(tangent_2) > EPSILON
			)
			and
			warm_frame(m, c)
		then
			local rel_x = bb.vx + bb.wy * c.rbz - bb.wz * c.rby - ba.vx - ba.wy * c.raz + ba.wz * c.ray
			local rel_y = bb.vy + bb.wz * c.rbx - bb.wx * c.rbz - ba.vy - ba.wz * c.rax + ba.wx * c.raz
			local rel_z = bb.vz + bb.wx * c.rby - bb.wy * c.rbx - ba.vz - ba.wx * c.ray + ba.wy * c.rax
			local normal_dot = rel_x * m.nx + rel_y * m.ny + rel_z * m.nz

			if
				rel_x * rel_x + rel_y * rel_y + rel_z * rel_z - normal_dot * normal_dot <= P.max_tangent_warm_sq
			then
				if math_abs(tangent_1) > EPSILON then
					apply_contact_impulse(m, c, ba, bb, ia, ib, c.tx, c.ty, c.tz, tangent_1)
					c.jt1 = tangent_1
				end

				if math_abs(tangent_2) > EPSILON then
					apply_contact_impulse(m, c, ba, bb, ia, ib, c.bx, c.by, c.bz, tangent_2)
					c.jt2 = tangent_2
				end
			end
		end
	end
end

local function solve_normal(m, c, ba, bb, relax)
	if c.nim <= EPSILON then return end

	local gap = c.sep - c.v_pre * P.dt
	local open_gap = math_max(
		m.spec[relax] * math_min(1, math_max(0, gap * 1e30)),
		relax * math_min(1, math_max(0, (gap - P.relax_gap) * 1e30))
	)
	local closed = 1 - open_gap
	m.pcorr = math_max(m.pcorr, -(gap + P.slop) * closed)
	local old_impulse = c.jn
	local new_impulse = math_max(
		old_impulse + (
				-(
					1 + closed * (
						m.soft_mass_scale[relax] - 1
					)
				) * (
					(
						bb.vx - ba.vx
					) * m.nx + (
						bb.vy - ba.vy
					) * m.ny + (
						bb.vz - ba.vz
					) * m.nz + bb.wx * c.cbx + bb.wy * c.cby + bb.wz * c.cbz - ba.wx * c.cax - ba.wy * c.cay - ba.wz * c.caz + open_gap * gap / P.dt + closed * math_max(m.bias_rate[relax] * (gap + P.slop), -P.push)
				) / c.nim - closed * m.soft_impulse_scale[relax] * old_impulse
			),
		0
	)
	local delta = new_impulse - old_impulse
	c.jn = new_impulse
	c.rest_total = c.rest_total + new_impulse * m.bounces
	local scale = delta * m.pm_a
	ba.vx = ba.vx - m.nx * scale
	ba.vy = ba.vy - m.ny * scale
	ba.vz = ba.vz - m.nz * scale
	ba.wx = ba.wx - delta * c.wax
	ba.wy = ba.wy - delta * c.way
	ba.wz = ba.wz - delta * c.waz
	scale = delta * m.pm_b
	bb.vx = bb.vx + m.nx * scale
	bb.vy = bb.vy + m.ny * scale
	bb.vz = bb.vz + m.nz * scale
	bb.wx = bb.wx + delta * c.wbx
	bb.wy = bb.wy + delta * c.wby
	bb.wz = bb.wz + delta * c.wbz
end

-- Builds the friction frame for a row from the current slip velocity: t along the slip (or the
-- cached tangent), b = n x t. Writes t, b and the slip numerators to the row; returns false when
-- there is no slip.
local function friction_frame(m, c, ba, bb)
	local rel_x = bb.vx + bb.wy * c.rbz - bb.wz * c.rby - ba.vx - ba.wy * c.raz + ba.wz * c.ray
	local rel_y = bb.vy + bb.wz * c.rbx - bb.wx * c.rbz - ba.vy - ba.wz * c.rax + ba.wx * c.raz
	local rel_z = bb.vz + bb.wx * c.rby - bb.wy * c.rbx - ba.vz - ba.wx * c.ray + ba.wy * c.rax
	local normal_dot = rel_x * m.nx + rel_y * m.ny + rel_z * m.nz
	local px, py, pz = rel_x - m.nx * normal_dot, rel_y - m.ny * normal_dot, rel_z - m.nz * normal_dot
	local speed = math_sqrt(px * px + py * py + pz * pz)
	c.speed = speed

	if speed <= EPSILON then return false end

	local inv = 1 / speed

	if m.persistent == 1 and c.has_tangent == 1 then
		local dot = c.tx * m.nx + c.ty * m.ny + c.tz * m.nz
		local cx, cy, cz = c.tx - m.nx * dot, c.ty - m.ny * dot, c.tz - m.nz * dot
		local length_squared = cx * cx + cy * cy + cz * cz

		if length_squared > EPSILON * EPSILON then
			px, py, pz = cx, cy, cz
			inv = 1 / math_sqrt(length_squared)
		end
	end

	local bx, by, bz = (py * m.nz - pz * m.ny) * inv,
	(pz * m.nx - px * m.nz) * inv,
	(px * m.ny - py * m.nx) * inv
	px, py, pz = px * inv, py * inv, pz * inv

	if bx * bx + by * by + bz * bz <= EPSILON * EPSILON then
		local ax, ay = 1, 0

		if math_abs(m.ny) < 0.9 then ax, ay = 0, 1 end

		local dot = ax * m.nx + ay * m.ny
		px, py, pz = ax - m.nx * dot, ay - m.ny * dot, -m.nz * dot
		inv = 1 / math_sqrt(px * px + py * py + pz * pz)
		px, py, pz = px * inv, py * inv, pz * inv
		bx, by, bz = py * m.nz - pz * m.ny, pz * m.nx - px * m.nz, px * m.ny - py * m.nx
	end

	inv = 1 / math_sqrt(bx * bx + by * by + bz * bz)
	bx, by, bz = bx * inv, by * inv, bz * inv
	c.bx, c.by, c.bz = bx, by, bz
	local tx, ty, tz = m.ny * bz - m.nz * by, m.nz * bx - m.nx * bz, m.nx * by - m.ny * bx
	inv = 1 / math_sqrt(tx * tx + ty * ty + tz * tz)
	tx, ty, tz = tx * inv, ty * inv, tz * inv
	c.tx, c.ty, c.tz = tx, ty, tz
	c.n1 = -(rel_x * tx + rel_y * ty + rel_z * tz)
	c.n2 = -(rel_x * bx + rel_y * by + rel_z * bz)
	return true
end

-- Effective mass of a row along the direction (dx, dy, dz) for both bodies.
local function friction_inverse_mass(m, c, ba, bb, dx, dy, dz)
	local ux, uy, uz = c.ray * dz - c.raz * dy, c.raz * dx - c.rax * dz, c.rax * dy - c.ray * dx
	local vx, vy, vz = c.rby * dz - c.rbz * dy, c.rbz * dx - c.rbx * dz, c.rbx * dy - c.rby * dx
	return m.pm_a + m.pm_b + ux * (
			ba.i00 * ux + ba.i01 * uy + ba.i02 * uz
		) + uy * (
			ba.i10 * ux + ba.i11 * uy + ba.i12 * uz
		) + uz * (
			ba.i20 * ux + ba.i21 * uy + ba.i22 * uz
		) + vx * (
			bb.i00 * vx + bb.i01 * vy + bb.i02 * vz
		) + vy * (
			bb.i10 * vx + bb.i11 * vy + bb.i12 * vz
		) + vz * (
			bb.i20 * vx + bb.i21 * vy + bb.i22 * vz
		)
end

local function solve_friction(m, c, ba, bb)
	if not friction_frame(m, c, ba, bb) then return end

	local inverse_mass_1 = friction_inverse_mass(m, c, ba, bb, c.tx, c.ty, c.tz)
	local inverse_mass_2 = friction_inverse_mass(m, c, ba, bb, c.bx, c.by, c.bz)

	if inverse_mass_1 <= EPSILON or inverse_mass_2 <= EPSILON then return end

	local impulse_1 = c.n1 / inverse_mass_1
	local impulse_2 = c.n2 / inverse_mass_2
	local limit = c.jn * m.stat
	local static_flag = math_max(
		math_min(1, math_max(0, limit * 1e8)) * math_min(
				1,
				math_max(0, (limit * limit - impulse_1 * impulse_1 - impulse_2 * impulse_2) * 1e8 + 1)
			),
		math_min(1, math_max(0, (P.static_speed - c.speed) * 1e8 + 1)),
		c.static_active * math_min(1, math_max(0, (P.static_exit_speed - c.speed) * 1e8 + 1))
	)
	c.static_active = static_flag
	local previous_1, previous_2 = 0, 0

	if m.persistent == 1 then previous_1, previous_2 = c.jt1, c.jt2 end

	local new_1 = previous_1 + impulse_1
	local new_2 = previous_2 + impulse_2
	local cone_scale = math_min(
		1,
		c.jn * (
				m.dyn + (
					m.stat - m.dyn
				) * static_flag
			) / math_max(math_sqrt(new_1 * new_1 + new_2 * new_2), EPSILON)
	)
	new_1 = new_1 * cone_scale
	new_2 = new_2 * cone_scale

	if m.persistent == 1 then
		c.jt1, c.jt2 = new_1, new_2
		c.has_tangent = 1
	end

	local delta_1 = new_1 - previous_1
	local delta_2 = new_2 - previous_2
	local wx = delta_1 * c.tx + delta_2 * c.bx
	local wy = delta_1 * c.ty + delta_2 * c.by
	local wz = delta_1 * c.tz + delta_2 * c.bz
	ba.vx = ba.vx - wx * m.pm_a
	ba.vy = ba.vy - wy * m.pm_a
	ba.vz = ba.vz - wz * m.pm_a
	bb.vx = bb.vx + wx * m.pm_b
	bb.vy = bb.vy + wy * m.pm_b
	bb.vz = bb.vz + wz * m.pm_b
	local ux, uy, uz = c.ray * wz - c.raz * wy, c.raz * wx - c.rax * wz, c.rax * wy - c.ray * wx
	ba.wx = ba.wx - (ba.i00 * ux + ba.i01 * uy + ba.i02 * uz)
	ba.wy = ba.wy - (ba.i10 * ux + ba.i11 * uy + ba.i12 * uz)
	ba.wz = ba.wz - (ba.i20 * ux + ba.i21 * uy + ba.i22 * uz)
	ux, uy, uz = c.rby * wz - c.rbz * wy, c.rbz * wx - c.rbx * wz, c.rbx * wy - c.rby * wx
	bb.wx = bb.wx + (bb.i00 * ux + bb.i01 * uy + bb.i02 * uz)
	bb.wy = bb.wy + (bb.i10 * ux + bb.i11 * uy + bb.i12 * uz)
	bb.wz = bb.wz + (bb.i20 * ux + bb.i21 * uy + bb.i22 * uz)
end

local function solve_twist(m, ba, bb, last)
	local twist_limit = 0
	local cs = m.cs

	for k = 0, last do
		twist_limit = twist_limit + cs[k].lever * cs[k].jn
	end

	twist_limit = twist_limit * m.dyn
	local previous = m.twist_impulse
	local new_impulse = math_min(
		math_max(
			previous - m.twist_mass * (
					(
						bb.wx - ba.wx
					) * m.nx + (
						bb.wy - ba.wy
					) * m.ny + (
						bb.wz - ba.wz
					) * m.nz
				),
			-twist_limit
		),
		twist_limit
	)
	m.twist_impulse = new_impulse
	local ux, uy, uz = m.nx * (new_impulse - previous),
	m.ny * (new_impulse - previous),
	m.nz * (new_impulse - previous)
	ba.wx = ba.wx - (ba.i00 * ux + ba.i01 * uy + ba.i02 * uz)
	ba.wy = ba.wy - (ba.i10 * ux + ba.i11 * uy + ba.i12 * uz)
	ba.wz = ba.wz - (ba.i20 * ux + ba.i21 * uy + ba.i22 * uz)
	bb.wx = bb.wx + (bb.i00 * ux + bb.i01 * uy + bb.i02 * uz)
	bb.wy = bb.wy + (bb.i10 * ux + bb.i11 * uy + bb.i12 * uz)
	bb.wz = bb.wz + (bb.i20 * ux + bb.i21 * uy + bb.i22 * uz)
end

local function get_passes(m, ba, bb)
	if m.resting == 1 then
		local dx, dy, dz = bb.vx - ba.vx, bb.vy - ba.vy, bb.vz - ba.vz
		local normal_dot = dx * m.nx + dy * m.ny + dz * m.nz
		local tx, ty, tz = dx - m.nx * normal_dot, dy - m.ny * normal_dot, dz - m.nz * normal_dot

		if
			dx * dx + dy * dy + dz * dz <= P.resting_rel_sq and
			tx * tx + ty * ty + tz * tz <= P.resting_tan_sq and
			math_max(
				ba.wx * ba.wx + ba.wy * ba.wy + ba.wz * ba.wz,
				bb.wx * bb.wx + bb.wy * bb.wy + bb.wz * bb.wz
			) <= P.resting_ang_sq
		then
			return P.passes_resting
		end
	end

	return P.passes_base
end

-- A sweep is a flat list of tasks instead of nested loops over manifolds and rows: LuaJIT unrolls
-- short inner loops into the outer trace, which overflowed its spill slots for large contact patches
-- and left the whole solver interpreted.
local TASK_BEGIN, TASK_NORMAL, TASK_NORMAL_EXTRA, TASK_FRICTION, TASK_TWIST, TASK_COMMIT = 0, 1, 2, 3, 4, 5

local function add_task(m_index, k, kind, pass)
	if task_count >= task_capacity then
		tasks, task_capacity = grow(tasks, TaskArray, task_count, task_capacity, task_count + 1)
	end

	local task = tasks[task_count]
	task.m, task.k, task.kind, task.pass = m_index, k, kind, pass
	task_count = task_count + 1
end

local function build_tasks(group)
	for i = group.first_man, group.man_end - 1 do
		local m = mans[i]
		add_task(i, 0, TASK_BEGIN, 0)

		for k = 0, m.rows - 1 do
			add_task(i, k, TASK_NORMAL, 1)
		end

		for pass = 2, P.passes_resting do
			for k = 0, m.rows - 1 do
				add_task(i, k, TASK_NORMAL_EXTRA, pass)
			end
		end

		if m.dyn > 0 or m.stat > 0 then
			for k = 0, m.rows - 1 do
				add_task(i, k, TASK_FRICTION, 0)
			end
		end

		if m.twist_mass > 0 and m.dyn > 0 then add_task(i, 0, TASK_TWIST, 0) end

		add_task(i, 0, TASK_COMMIT, 0)
	end

	group.task_end = task_count
end

local function solve_tasks(first, last, relax)
	for t = first, last do
		local task = tasks[t]
		local m = mans[task.m]
		local kind = task.kind

		if kind == TASK_NORMAL then
			solve_normal(m, m.cs[task.k], bodies[m.a], bodies[m.b], relax)
		elseif kind == TASK_FRICTION then
			solve_friction(m, m.cs[task.k], bodies[m.a], bodies[m.b])
		elseif kind == TASK_NORMAL_EXTRA then
			if m.passes >= task.pass then
				solve_normal(m, m.cs[task.k], bodies[m.a], bodies[m.b], relax)
			end
		elseif kind == TASK_BEGIN then
			m.pcorr = -math.huge
			m.passes = get_passes(m, bodies[m.a], bodies[m.b])
		elseif kind == TASK_TWIST then
			solve_twist(m, bodies[m.a], bodies[m.b], m.rows - 1)
		else
			bodies[m.a].pc = math_max(bodies[m.a].pc, m.pcorr)
			bodies[m.b].pc = math_max(bodies[m.b].pc, m.pcorr)
		end
	end
end

-- Loads the island's bodies and prepares and warm starts every collected manifold.
function contact_solver.Prepare(solver, group, dt)
	local first = group.first_man
	local last = group.man_end - 1
	contact_solver.Reload(group, true)

	for i = first, last do
		local m = mans[i]

		if prepare_manifold(m, bodies[m.a], bodies[m.b]) then
			man_objects[i].touched_stamp = solver.StepStamp
		end
	end

	for i = first, last do
		local m = mans[i]
		warm_start_manifold(m, bodies[m.a], bodies[m.b])
	end

	local omega = 2 * math.pi * soft_hertz

	for i = first, last do
		local m = mans[i]
		m.resting = (
				m.rows >= P.resting_min_contacts and
				math_abs(m.ny) >= P.resting_min_normal_y and
				m.restitution <= 0.05
			)
			and
			1 or
			0
		local h, z = omega, soft_damping_ratio

		if m.pm_a == 0 or m.pm_b == 0 then
			h = h * 2
			z = z * 0.5
		end

		local a1 = 2 * z + dt * h
		local a2 = dt * h * a1
		local impulse_scale = 1 / (1 + a2)
		local soft = m.soft
		m.spec[0] = soft
		m.bias_rate[0] = soft == 1 and h / a1 or 0
		m.soft_mass_scale[0] = soft == 1 and a2 * impulse_scale or 1
		m.soft_impulse_scale[0] = soft == 1 and impulse_scale or 0
		m.spec[1], m.bias_rate[1], m.soft_mass_scale[1], m.soft_impulse_scale[1] = 0, 0, 1, 0
	end

	build_tasks(group)
end

-- One Gauss-Seidel sweep over the island's prepared manifolds, on the loaded velocities.
function contact_solver.Solve(group, relax)
	if group.task_end > group.first_task then
		solve_tasks(group.first_task, group.task_end - 1, relax and 1 or 0)
	end
end

return contact_solver
