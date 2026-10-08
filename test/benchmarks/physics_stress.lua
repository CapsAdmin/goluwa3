-- glw: --cli --physics
local system = import("goluwa/system.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local constraints = import("goluwa/physics/constraints.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local stats = import("goluwa/physics/stats.lua")
local benchmark_results = import("goluwa/benchmark_results.lua")
-- One deterministic world made of independent zones, each one a different way to hurt the solver.
-- ZONES=pit,chains env restricts which zones are built, WARMUP/STEPS/WINDOW override the phases.
local DT = 1 / 60
local WARMUP_STEPS = tonumber(os.getenv("WARMUP") or "150")
local MEASURE_STEPS = tonumber(os.getenv("STEPS") or "100")
local WINDOW_STEPS = tonumber(os.getenv("WINDOW") or "50")
local ALLOC_STEPS = 20
local ZONE_SPACING = 60
-- FULL=1 builds the large scene (~965 bodies), the default is a quarter of that so a run takes seconds.
local FULL = os.getenv("FULL") ~= nil
local WALL_H = tonumber(os.getenv("WALL_H") or (FULL and "12" or "8"))
local WALL_W = tonumber(os.getenv("WALL_W") or (FULL and "20" or "10"))
local PYRAMID_N = tonumber(os.getenv("PYRAMID_N") or (FULL and "16" or "10"))
local PIT_BODIES = FULL and 300 or 100
local CHAIN_COUNT = FULL and 8 or 3
local DRUM_BODIES = FULL and 40 or 20
local PROJECTILE_WALL_H = FULL and 8 or 5
local enabled_zones = {}

if os.getenv("ZONES") then
	for name in os.getenv("ZONES"):gmatch("[^,]+") do
		enabled_zones[name] = true
	end
else
	for _, name in ipairs{"pyramid", "wall", "pit", "chains", "drum", "projectiles"} do
		enabled_zones[name] = true
	end
end

local world = physics.instance

if os.getenv("JITOPT") then
	local options = {}

	for option in os.getenv("JITOPT"):gmatch("[^,]+") do
		options[#options + 1] = option
	end

	jit.opt.start(unpack(options))
end

for env, key in pairs{
	SUBSTEPS = "RigidBodySubsteps",
	ITERS = "RigidBodyIterations",
	RELAXN = "RigidBodyRelaxIterations",
} do
	if os.getenv(env) then world[key] = tonumber(os.getenv(env)) end
end

for env, key in pairs{
	CHZ = "CONTACT_HERTZ",
	CZETA = "CONTACT_DAMPING_RATIO",
	CPUSH = "CONTACT_PUSH_SPEED",
	REBUILD_T = "REBUILD_POSE_THRESHOLD",
} do
	if os.getenv(env) then world.solver[key] = tonumber(os.getenv(env)) end
end

local seed = 987654321

local function rand()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

local function yaw_quat(angle)
	return Quat(0, math.sin(angle * 0.5), 0, math.cos(angle * 0.5))
end

local function random_quat()
	local x, y, z, w = rand() - 0.5, rand() - 0.5, rand() - 0.5, rand() - 0.5
	local length = math.sqrt(x * x + y * y + z * z + w * w)
	return Quat(x / length, y / length, z / length, w / length)
end

local function spawn(position, config, rotation)
	local ent = Entity.New({Name = "stress_body"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)

	if rotation then ent.transform:SetRotation(rotation) end

	return ent, ent:AddComponent("rigid_body", config)
end

local function static_box(position, size, friction)
	return spawn(
		position,
		{
			Shape = BoxShape.New(size),
			Size = size,
			MotionType = "static",
			Friction = friction or 0.8,
		}
	)
end

local triangle_pyramid_hull

do
	local poly = Polygon3D.New()

	local function triangle(a, b, c)
		poly:AddVertex{pos = a, uv = Vec2(0, 0)}
		poly:AddVertex{pos = b, uv = Vec2(1, 0)}
		poly:AddVertex{pos = c, uv = Vec2(0.5, 1)}
	end

	local a, b, c, d = Vec3(-0.4, -0.35, -0.4),
	Vec3(0.4, -0.35, -0.4),
	Vec3(0.4, -0.35, 0.4),
	Vec3(-0.4, -0.35, 0.4)
	local apex = Vec3(0, 0.5, 0)
	triangle(a, b, apex)
	triangle(b, c, apex)
	triangle(c, d, apex)
	triangle(d, a, apex)
	triangle(a, d, c)
	triangle(a, c, b)
	poly:BuildBoundingBox()
	triangle_pyramid_hull = convex_hull.BuildFromTriangles(poly)
end

local shape_configs = {
	function()
		local size = Vec3(0.5, 0.5, 0.5)
		return {Shape = BoxShape.New(size), Size = size}
	end,
	function()
		return {Shape = SphereShape.New(0.3), Radius = 0.3}
	end,
	function()
		return {Shape = CapsuleShape.New(0.22, 0.7), Radius = 0.22, Height = 0.7}
	end,
	function()
		return {
			Shape = ConvexShape.New(triangle_pyramid_hull),
			ConvexHull = triangle_pyramid_hull,
		}
	end,
	function()
		return {
			Shape = CompoundShape.New{
				{
					Shape = BoxShape.New(Vec3(0.9, 0.15, 0.15)),
					Position = Vec3(0, 0, 0),
					Rotation = Quat(0, 0, 0, 1),
				},
				{
					Shape = SphereShape.New(0.25),
					Position = Vec3(-0.45, 0, 0),
					Rotation = Quat(0, 0, 0, 1),
				},
				{
					Shape = SphereShape.New(0.25),
					Position = Vec3(0.45, 0, 0),
					Rotation = Quat(0, 0, 0, 1),
				},
			},
		}
	end,
}

local function spawn_mixed(index, position, rotation)
	local config = shape_configs[index % #shape_configs + 1]()
	config.Friction = 0.6
	config.Restitution = 0.1
	return spawn(position, config, rotation)
end

local zone_origin = 0
local steppers = {}
local zone_body_counts = {}

local function begin_zone(name)
	zone_origin = zone_origin + ZONE_SPACING
	zone_body_counts[#zone_body_counts + 1] = {name = name, first = #RigidBody.Instances + 1}
	return Vec3(zone_origin, 0, 0)
end

local function end_zone()
	local zone = zone_body_counts[#zone_body_counts]
	zone.count = #RigidBody.Instances - zone.first + 1
end

static_box(Vec3(0, -0.5, 0), Vec3(2000, 1, 2000), 0.9)

if enabled_zones.pyramid then
	local origin = begin_zone("pyramid")
	local size = Vec3(1, 1, 1)

	for level = 0, PYRAMID_N - 1 do
		local count = PYRAMID_N - level

		for i = 0, count - 1 do
			spawn(
				origin + Vec3((i - (count - 1) / 2) * 1.02, 0.5 + level, 0),
				{
					Shape = BoxShape.New(size),
					Size = size,
					Mass = 2,
					AutomaticMass = false,
					Friction = 0.7,
					Restitution = 0,
				}
			)
		end
	end

	end_zone()
end

if enabled_zones.wall then
	local origin = begin_zone("wall")
	local size = Vec3(1, 1, 1)

	for y = 0, WALL_H - 1 do
		for x = 0, WALL_W - 1 - y % 2 do
			spawn(
				origin + Vec3((x - (WALL_W - 1) / 2 + (y % 2) * 0.5) * 1.01, 0.5 + y, 0),
				{
					Shape = BoxShape.New(size),
					Size = size,
					Mass = 2,
					AutomaticMass = false,
					Friction = 0.7,
					Restitution = 0,
				}
			)
		end
	end

	end_zone()
end

if enabled_zones.pit then
	local origin = begin_zone("pit")
	local half = 6
	local container = {}

	for _, part in ipairs{
		{Vec3(0, -0.5, 0), Vec3(half * 2 + 2, 1, half * 2 + 2)},
		{Vec3(-half - 0.5, 6, 0), Vec3(1, 12, half * 2 + 2)},
		{Vec3(half + 0.5, 6, 0), Vec3(1, 12, half * 2 + 2)},
		{Vec3(0, 6, -half - 0.5), Vec3(half * 2 + 2, 12, 1)},
		{Vec3(0, 6, half + 0.5), Vec3(half * 2 + 2, 12, 1)},
	} do
		container[#container + 1] = {
			ent = spawn(
				origin + part[1],
				{
					Shape = BoxShape.New(part[2]),
					Size = part[2],
					MotionType = "kinematic",
					Friction = 0.8,
				}
			),
			offset = part[1],
		}
	end

	for i = 0, PIT_BODIES - 1 do
		local layer, cell = math.floor(i / 50), i % 50
		spawn_mixed(
			i,
			origin + Vec3(
					(cell % 10 - 4.5) * 1.1 + (rand() - 0.5) * 0.2,
					1.2 + layer * 1.3 + rand() * 0.2,
					(math.floor(cell / 10) - 2) * 1.1 + (rand() - 0.5) * 0.2
				),
			random_quat()
		)
	end

	local tick = 0
	steppers[#steppers + 1] = function()
		tick = tick + 1
		local shake = origin + Vec3(math.sin(tick * DT * 12) * 0.12, 0, math.cos(tick * DT * 9) * 0.12)

		for i = 1, #container do
			container[i].ent.transform:SetPosition(shake + container[i].offset)
		end
	end
	end_zone()
end

if enabled_zones.chains then
	local origin = begin_zone("chains")
	local anchors = {}

	for chain = 0, CHAIN_COUNT - 1 do
		local base = origin + Vec3(chain * 4 - 14, 14, 0)
		local anchor_ent, anchor = spawn(
			base,
			{
				Shape = BoxShape.New(Vec3(0.3, 0.3, 0.3)),
				Size = Vec3(0.3, 0.3, 0.3),
				MotionType = "kinematic",
			}
		)
		local previous = anchor
		anchors[#anchors + 1] = {ent = anchor_ent, base = base, phase = chain * 0.8}

		for link = 1, 20 do
			local heavy = link == 20
			local radius = heavy and 0.5 or 0.12
			local _, body = spawn(
				base + Vec3(0, -link * 0.5, 0),
				{
					Shape = SphereShape.New(radius),
					Radius = radius,
					Mass = heavy and 15 or 1,
					AutomaticMass = false,
					Friction = 0.5,
				}
			)
			constraints.BallSocket(previous, body, base + Vec3(0, -(link - 0.5) * 0.5, 0))
			previous = body
		end
	end

	local tick = 0
	steppers[#steppers + 1] = function()
		tick = tick + 1

		for i = 1, #anchors do
			local anchor = anchors[i]
			anchor.ent.transform:SetPosition(
				anchor.base + Vec3(
						math.sin(tick * DT * 1.5 + anchor.phase) * 2,
						0,
						math.cos(tick * DT * 1.1 + anchor.phase) * 2
					)
			)
		end
	end
	end_zone()
end

if enabled_zones.drum then
	local origin = begin_zone("drum")
	local radius, height, sides, thickness = 4, 6, 12, 0.5
	local center = origin + Vec3(0, 5, 0)
	local side = 2 * (radius + thickness) * math.tan(math.pi / sides) + 0.1
	local cap = radius * 2 + thickness * 2 + 1
	local cap_y = height * 0.5 + thickness * 0.5
	local children = {}

	for i = 0, sides - 1 do
		local phi = i / sides * math.pi * 2
		local r = radius + thickness * 0.5
		children[#children + 1] = {
			Shape = BoxShape.New(Vec3(side, height, thickness)),
			Position = Vec3(math.sin(phi) * r, 0, math.cos(phi) * r),
			Rotation = yaw_quat(phi),
		}
	end

	children[#children + 1] = {
		Shape = BoxShape.New(Vec3(cap, thickness, cap)),
		Position = Vec3(0, -cap_y, 0),
		Rotation = Quat(0, 0, 0, 1),
	}
	children[#children + 1] = {
		Shape = BoxShape.New(Vec3(cap, thickness, cap)),
		Position = Vec3(0, cap_y, 0),
		Rotation = Quat(0, 0, 0, 1),
	}
	local drum = spawn(
		center,
		{
			Shape = CompoundShape.New(children),
			MotionType = "kinematic",
			Friction = 0.8,
			Restitution = 0,
		}
	)

	for i = 0, DRUM_BODIES - 1 do
		local angle = rand() * math.pi * 2
		local r = rand() * (radius - 1.2)
		spawn_mixed(
			i,
			center + Vec3(math.sin(angle) * r, (rand() - 0.5) * (height - 2), math.cos(angle) * r),
			random_quat()
		)
	end

	local tick = 0
	steppers[#steppers + 1] = function()
		tick = tick + 1
		drum.transform:SetRotation(yaw_quat(3 * math.min(tick / 120, 1) * DT * tick))
	end
	end_zone()
end

local projectile_zone

if enabled_zones.projectiles then
	local origin = begin_zone("projectiles")
	local size = Vec3(1, 1, 1)

	for y = 0, PROJECTILE_WALL_H - 1 do
		for x = 0, 9 do
			spawn(
				origin + Vec3((x - 5 + (y % 2) * 0.5) * 1.01, 0.5 + y, 0),
				{
					Shape = BoxShape.New(size),
					Size = size,
					Mass = 2,
					AutomaticMass = false,
					Friction = 0.7,
					Restitution = 0,
				}
			)
		end
	end

	projectile_zone = {origin = origin, live = {}}
	local tick = 0
	steppers[#steppers + 1] = function()
		tick = tick + 1

		if tick % 40 == 0 then
			local ent, body = spawn(
				origin + Vec3((rand() - 0.5) * 8, 1 + rand() * 6, 30),
				{
					Shape = SphereShape.New(0.25),
					Radius = 0.25,
					Mass = 4,
					AutomaticMass = false,
					Friction = 0.4,
					Restitution = 0.1,
				}
			)
			body:SetVelocity(Vec3((rand() - 0.5) * 2, 4 + rand() * 4, -(60 + rand() * 20)))
			projectile_zone.live[#projectile_zone.live + 1] = {ent = ent, born = tick}
		end

		local live = projectile_zone.live

		while live[1] and tick - live[1].born > 300 do
			live[1].ent:Remove()
			table.remove(live, 1)
		end
	end
	end_zone()
end

local step_index = 0
local TRACK_EVERY = tonumber(os.getenv("TRACK") or "0")

local function step()
	for i = 1, #steppers do
		steppers[i]()
	end

	world.Step(DT)
	step_index = step_index + 1

	if TRACK_EVERY > 0 and step_index % TRACK_EVERY == 0 then
		local awake, max_speed, max_spin, dynamic = 0, 0, 0, 0
		local fast_y, fast_x, fast_z = 0, 0, 0

		for _, body in ipairs(RigidBody.Instances) do
			if body:HasSolverMass() then
				dynamic = dynamic + 1

				if body:GetAwake() then
					awake = awake + 1

					if body:GetVelocity():GetLength() > max_speed then
						max_speed = body:GetVelocity():GetLength()
						fast_y, fast_x, fast_z = body:GetPosition().y, body:GetPosition().x, body:GetPosition().z
					end

					max_spin = math.max(max_spin, body:GetAngularVelocity():GetLength())
				end
			end
		end

		print(
			string.format(
				"[TRACK] step %d awake %d/%d max_speed %.3f max_spin %.3f at y=%.2f x=%.2f z=%.2f",
				step_index,
				awake,
				dynamic,
				max_speed,
				max_spin,
				fast_y,
				fast_x,
				fast_z
			)
		)
	end
end

local function checksum()
	local sum_x, sum_y, sum_z, awake, dynamic = 0, 0, 0, 0, 0

	for _, body in ipairs(RigidBody.Instances) do
		if body:HasSolverMass() then
			local p = body:GetPosition()
			sum_x = sum_x + p.x
			sum_y = sum_y + p.y
			sum_z = sum_z + p.z
			dynamic = dynamic + 1

			if body:GetAwake() then awake = awake + 1 end
		end
	end

	return sum_x, sum_y, sum_z, awake, dynamic
end

local function pair_stat()
	local seen, active, contacts, idle, empty = {}, 0, 0, 0, 0
	local solver = world.solver

	for _, row in pairs(solver.PersistentManifolds) do
		for _, m in pairs(row) do
			if not seen[m] then
				seen[m] = true

				if m.last_warm_step == solver.StepStamp then
					active = active + 1
					contacts = contacts + (m.n or 0)

					if m.idle then idle = idle + 1 end

					if (m.n or 0) == 0 then empty = empty + 1 end
				end
			end
		end
	end

	print(
		string.format(
			"[PAIRSTAT] active manifolds %d contacts %d idle %d empty %d",
			active,
			contacts,
			idle,
			empty
		)
	)
end

local total_bodies = #RigidBody.Instances
local parts = {}

for _, zone in ipairs(zone_body_counts) do
	parts[#parts + 1] = zone.name .. "=" .. zone.count
end

print(
	string.format(
		"physics stress: %d bodies, %d constraints (%s)",
		total_bodies,
		#world.GetConstraints(),
		table.concat(parts, " ")
	)
)
local abort_counts, abort_started, abort_stopped = {}, 0, 0

local function attach_abort_log()
	local jit_util = require("jit.util")
	local vmdef = require("jit.vmdef")
	local roots = {}

	jit.attach(
		function(what, tr, func, pc, otr, oex)
			if what == "start" then
				local info = jit_util.funcinfo(func, pc)
				roots[tr] = (
						otr and
						otr > 0 and
						roots[otr]
					)
					or
					(
						(
							info.source or
							"?"
						):gsub("^@", "") .. ":" .. (
							info.currentline or
							0
						)
					)
				abort_started = abort_started + 1
			elseif what == "stop" then
				abort_stopped = abort_stopped + 1
			elseif what == "abort" then
				local info = jit_util.funcinfo(func, pc)
				local reason = (vmdef.traceerr[otr] or tostring(otr)):gsub("%%d", tostring(oex))
				local key = reason .. " @ " .. (
						info.source or
						"?"
					):gsub("^@", "") .. ":" .. (
						info.currentline or
						info.linedefined or
						0
					) .. " <- " .. tostring(roots[tr])
				abort_counts[key] = (abort_counts[key] or 0) + 1
			end
		end,
		"trace"
	)
end

if os.getenv("ABORTS") == "early" then attach_abort_log() end

local settle_start = system.GetTime()

for _ = 1, WARMUP_STEPS do
	step()
end

local settle_ms = (system.GetTime() - settle_start) * 1000 / math.max(WARMUP_STEPS, 1)

if os.getenv("PAIRSTAT") then pair_stat() end

local tw

if os.getenv("TIMEWRAP") then
	tw = import("tmp/phys_timewrap.lua")
	local MF = import("goluwa/physics/manifold.lua")
	local CS = import("goluwa/physics/contact_solver.lua")
	local CR = import("goluwa/physics/contact_resolution.lua")

	for _, row in pairs(world.solver.PairHandlers) do
		for _, handler in pairs(row) do
			tw.wrap(handler, "callback", "  " .. handler.name)
		end
	end

	tw.wrap(
		world.solver,
		"SolveRigidBodyPairs",
		"Solver.SolveRigidBodyPairs (collect+prepare+solve)"
	)
	tw.wrap(world.solver, "RelaxRigidBodyPairs", "Solver.RelaxRigidBodyPairs")
	tw.wrap(world.solver, "FinishRigidBodyPairs", "Solver.FinishRigidBodyPairs")
	tw.wrap(CR, "EnqueueManifold", "EnqueueManifold")
	tw.wrap(CR, "FinishManifold", "FinishManifold")
	tw.wrap(CR, "MarkPairGrounding", "  MarkPairGrounding")
	tw.wrap(MF, "RebuildContacts", "  RebuildContacts")
	tw.wrap(CS, "Add", "  contact_solver.Add")
	tw.wrap(CS, "Prepare", "contact_solver.Prepare")
	tw.wrap(CS, "Reload", "contact_solver.Reload")
	tw.wrap(CS, "Solve", "contact_solver.Solve")
	tw.wrap(CS, "Store", "contact_solver.Store")
	tw.wrap(
		import("goluwa/physics/pair_solver_helpers.lua"),
		"TryInvokePairHandler",
		"TryInvokePairHandler"
	)
	tw.wrap(
		import("goluwa/physics/pair_solver_helpers.lua"),
		"DispatchColliderPairs",
		"DispatchColliderPairs"
	)
end

collectgarbage()

if os.getenv("PROF") then
	PROF.Start(
		"physics_stress",
		{
			trace_recorder = false,
			shutdown = false,
			path = os.getenv("PROF_PATH") or "tmp/physics_stress.glwp",
		}
	)
end

if os.getenv("ABORTS") == "1" then attach_abort_log() end

local samples = {}
local window_ms = {}
local window_sum, window_count = 0, 0

for i = 1, MEASURE_STEPS do
	local t = system.GetTime()
	step()
	t = (system.GetTime() - t) * 1000
	samples[i] = t
	window_sum = window_sum + t
	window_count = window_count + 1

	if window_count == WINDOW_STEPS then
		window_ms[#window_ms + 1] = window_sum / window_count
		window_sum, window_count = 0, 0
	end
end

if tw then tw.report(MEASURE_STEPS) end

if os.getenv("JITINFO") then
	local jit_util = require("jit.util")
	local live = 0

	for i = 1, 65535 do
		if jit_util.traceinfo(i) then live = live + 1 end
	end

	local _, _, _, mcode = jit_util.tracemc and 0, 0, 0, 0
	print(string.format("[JITINFO] live traces %d  status %s", live, tostring(jit.status())))
end

if os.getenv("ABORTS") then
	jit.attach(function() end)

	local list = {}

	for k, v in pairs(abort_counts) do
		if k:find("physics") then list[#list + 1] = {k, v} end
	end

	table.sort(list, function(a, b)
		return a[2] > b[2]
	end)

	print(string.format("[ABORT] traces started=%d stopped(ok)=%d", abort_started, abort_stopped))

	for i = 1, math.min(tonumber(os.getenv("TOP") or "25"), #list) do
		print(string.format("[ABORT] %4d %s", list[i][2], list[i][1]))
	end
end

if os.getenv("PROF") then
	PROF.Stop()
	print(
		PROF.Summary(
			os.getenv("PROF_PATH") or "tmp/physics_stress.glwp",
			{top_n = tonumber(os.getenv("PROF_TOP") or "40")}
		)
	)
	os.exit(0)
end

collectgarbage()
collectgarbage("stop")
local gc_start = collectgarbage("count")

for _ = 1, ALLOC_STEPS do
	step()
end

local alloc_kb = (collectgarbage("count") - gc_start) / ALLOC_STEPS
collectgarbage("restart")

if os.getenv("STATS") then
	stats:Enable()

	for _ = 1, 200 do
		step()
	end

	print(stats:Summary())
	stats:Disable()
end

local sum = 0

for i = 1, #samples do
	sum = sum + samples[i]
end

local mean = sum / #samples
local window_mean, window_dev = 0, 0

for i = 1, #window_ms do
	window_mean = window_mean + window_ms[i]
end

window_mean = window_mean / #window_ms

for i = 1, #window_ms do
	window_dev = window_dev + (window_ms[i] - window_mean) ^ 2
end

window_dev = math.sqrt(window_dev / math.max(#window_ms - 1, 1))
table.sort(samples)
local median = samples[math.floor(#samples / 2)]
local p95 = samples[math.floor(#samples * 0.95)]
local p99 = samples[math.floor(#samples * 0.99)]
local max = samples[#samples]
local sx, sy, sz, awake, dynamic = checksum()
print(
	string.format(
		"step ms: mean %.3f (window stddev %.3f)  median %.3f  p95 %.3f  p99 %.3f  max %.3f  | %.0f KB/step garbage",
		mean,
		window_dev,
		median,
		p95,
		p99,
		max,
		alloc_kb
	)
)

for i = 1, #window_ms do
	window_ms[i] = string.format("%.2f", window_ms[i])
end

print("windows: " .. table.concat(window_ms, " "))
print(
	string.format(
		"settle phase (%d steps, includes JIT warmup): %.3f ms/step",
		WARMUP_STEPS,
		settle_ms
	)
)
print(string.format("state: awake=%d/%d  sum=(%.9f, %.9f, %.9f)", awake, dynamic, sx, sy, sz))
local results = benchmark_results.New("physics_stress")
results:Add("settle step mean", settle_ms, settle_ms * 0.1, "ms")
results:Add("step mean", mean, window_dev, "ms")
results:Add("step median", median, window_dev, "ms")
results:Add("step p95", p95, window_dev * 2, "ms")
results:Add("garbage per step", alloc_kb, alloc_kb * 0.05, "KB")
results:AddFingerprint("awake bodies", awake)
results:Finish()
system.ShutDown(0)
