local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local mesh_contact_common = import("goluwa/physics/mesh_contact_common.lua")
local system = import("goluwa/system.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local sphere_shape = SphereShape.New
local box_shape = BoxShape.New
local capsule_shape = CapsuleShape.New
local convex_shape = ConvexShape.New
local DESERT_GRID = Vec2(4, 4)
local TERRAIN_SIZE = Vec2(48, 48)
local TERRAIN_RES = Vec2(32, 32)
local TERRAIN_OFFSET_Y = -6
local TOTAL_BODIES = 20
local GRID_COLUMNS = 5
local GRID_SPACING_X = 5.4
local GRID_SPACING_Z = 4.8
local TYPE_SEQUENCE = {"sphere", "box", "capsule", "convex"}
local FIXED_DT = 1 / 60

local function simulate_physics(steps, dt)
	dt = dt or FIXED_DT

	for _ = 1, steps do
		physics.Update(dt)
	end
end

local function with_fixed_step(fixed_dt, callback)
	local previous_fixed_dt = physics.FixedTimeStep
	local previous_accumulator = physics.FrameAccumulator
	local previous_alpha = physics.InterpolationAlpha
	physics.FixedTimeStep = fixed_dt
	physics.FrameAccumulator = 0
	physics.InterpolationAlpha = 0
	local ok, err = xpcall(callback, debug.traceback)
	physics.FixedTimeStep = previous_fixed_dt
	physics.FrameAccumulator = previous_accumulator or 0
	physics.InterpolationAlpha = previous_alpha or 0

	if not ok then
		error(string.format("[fixed_dt=%.6f] %s", fixed_dt, tostring(err)), 0)
	end
end

local function add_triangle(poly, a, b, c)
	poly:AddVertex{pos = a, uv = Vec2(0, 0)}
	poly:AddVertex{pos = b, uv = Vec2(1, 0)}
	poly:AddVertex{pos = c, uv = Vec2(0.5, 1)}
end

local function terrain_height(x, z)
	local dune_a = math.sin(x * 0.22) * 0.9
	local dune_b = math.cos(z * 0.19) * 0.7
	local cross = math.sin((x + z) * 0.11) * 0.45
	local slope = x * 0.03 + z * 0.015
	return dune_a + dune_b + cross + slope
end

local function build_terrain_chunk(chunk_min, chunk_max)
	local poly = Polygon3D.New()
	local cell_size = TERRAIN_SIZE / TERRAIN_RES
	local half_size = TERRAIN_SIZE / 2

	for x = chunk_min.x, chunk_max.x - 1 do
		for y = chunk_min.y, chunk_max.y - 1 do
			local x0 = -half_size.x + x * cell_size.x
			local x1 = x0 + cell_size.x
			local z0 = -half_size.y + y * cell_size.y
			local z1 = z0 + cell_size.y
			local p00 = Vec3(x0, terrain_height(x0, z0), z0)
			local p10 = Vec3(x1, terrain_height(x1, z0), z0)
			local p01 = Vec3(x0, terrain_height(x0, z1), z1)
			local p11 = Vec3(x1, terrain_height(x1, z1), z1)
			add_triangle(poly, p01, p10, p00)
			add_triangle(poly, p01, p11, p10)
		end
	end

	poly:BuildBoundingBox()
	return poly
end

local function build_chunked_terrain()
	local polygons = {}

	for grid_x = 0, DESERT_GRID.x - 1 do
		local chunk_min_x = math.floor((grid_x * TERRAIN_RES.x) / DESERT_GRID.x)
		local chunk_max_x = math.floor(((grid_x + 1) * TERRAIN_RES.x) / DESERT_GRID.x)

		for grid_y = 0, DESERT_GRID.y - 1 do
			local chunk_min_y = math.floor((grid_y * TERRAIN_RES.y) / DESERT_GRID.y)
			local chunk_max_y = math.floor(((grid_y + 1) * TERRAIN_RES.y) / DESERT_GRID.y)
			polygons[#polygons + 1] = build_terrain_chunk(Vec2(chunk_min_x, chunk_min_y), Vec2(chunk_max_x, chunk_max_y))
		end
	end

	return polygons
end

local function create_box_hull(size)
	local poly = Polygon3D.New()
	local hx = size.x * 0.5
	local hy = size.y * 0.5
	local hz = size.z * 0.5
	local vertices = {
		Vec3(-hx, -hy, -hz),
		Vec3(hx, -hy, -hz),
		Vec3(hx, hy, -hz),
		Vec3(-hx, hy, -hz),
		Vec3(-hx, -hy, hz),
		Vec3(hx, -hy, hz),
		Vec3(hx, hy, hz),
		Vec3(-hx, hy, hz),
	}
	local faces = {
		{1, 2, 3},
		{1, 3, 4},
		{5, 7, 6},
		{5, 8, 7},
		{1, 5, 6},
		{1, 6, 2},
		{4, 3, 7},
		{4, 7, 8},
		{1, 4, 8},
		{1, 8, 5},
		{2, 6, 7},
		{2, 7, 3},
	}

	for _, face in ipairs(faces) do
		add_triangle(poly, vertices[face[1]], vertices[face[2]], vertices[face[3]])
	end

	poly:BuildBoundingBox()
	return convex_hull.BuildFromTriangles(poly)
end

local function create_dynamic_entity(name, position)
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	return ent
end

local function spawn_body(index, entities)
	local column = (index - 1) % GRID_COLUMNS
	local row = math.floor((index - 1) / GRID_COLUMNS)
	local x = (column - (GRID_COLUMNS - 1) * 0.5) * GRID_SPACING_X
	local z = (row - 1.5) * GRID_SPACING_Z
	local y = 9 + row * 1.4 + (column % 2) * 0.35
	local position = Vec3(x, y, z)
	local body_type = TYPE_SEQUENCE[((index - 1) % #TYPE_SEQUENCE) + 1]
	local ent = create_dynamic_entity(string.format("triangle_cache_%s_%02d", body_type, index), position)
	entities[#entities + 1] = ent
	local body = nil

	if body_type == "sphere" then
		local radius = 0.35 + (index % 3) * 0.08
		body = ent:AddComponent(
			"rigid_body",
			{
				Shape = sphere_shape(radius),
				Radius = radius,
				Friction = 0.2,
				Restitution = 0,
				LinearDamping = 0.02,
				AngularDamping = 0.04,
				MaxLinearSpeed = 1000,
				MaxAngularSpeed = 1000,
			}
		)
	elseif body_type == "box" then
		local size = Vec3(
			0.75 + (index % 2) * 0.2,
			0.6 + (index % 3) * 0.16,
			0.75 + ((index + 1) % 2) * 0.2
		)
		body = ent:AddComponent(
			"rigid_body",
			{
				Shape = box_shape(size),
				Friction = 0.45,
				Restitution = 0,
				LinearDamping = 0.025,
				AngularDamping = 0.06,
				MaxLinearSpeed = 1000,
				MaxAngularSpeed = 1000,
			}
		)
	elseif body_type == "capsule" then
		local radius = 0.28 + (index % 2) * 0.07
		local height = math.max(radius * 2, 1.2 + (index % 3) * 0.22)
		body = ent:AddComponent(
			"rigid_body",
			{
				Shape = capsule_shape(radius, height),
				Radius = radius,
				Height = height,
				Friction = 0.24,
				Restitution = 0,
				LinearDamping = 0.02,
				AngularDamping = 0.05,
				MaxLinearSpeed = 1000,
				MaxAngularSpeed = 1000,
			}
		)
	else
		local size = Vec3(
			0.8 + (index % 2) * 0.15,
			0.7 + (index % 3) * 0.14,
			0.8 + ((index + 1) % 2) * 0.15
		)
		local hull = create_box_hull(size)
		body = ent:AddComponent(
			"rigid_body",
			{
				Shape = convex_shape(hull),
				ConvexHull = hull,
				Friction = 0.42,
				Restitution = 0,
				LinearDamping = 0.025,
				AngularDamping = 0.06,
				MaxLinearSpeed = 1000,
				MaxAngularSpeed = 1000,
			}
		)
	end

	local drift = Vec3(0.4 + row * 0.08, 0, ((column % 3) - 1) * 0.18)
	body:SetVelocity(drift)
	return body
end

local function cleanup_entities(entities)
	for i = #entities, 1, -1 do
		local ent = entities[i]

		if ent and ent.IsValid and ent:IsValid() then ent:Remove() end
	end
end

local function run_cache_scenario(cache_enabled, local_space_enabled, config)
	config = config or {}
	local warmup_steps = config.warmup_steps or 240
	local measure_steps = config.measure_steps or 180
	local previous_cache_enabled = mesh_contact_common.GetNarrowPhaseCacheEnabled()
	local previous_local_space_enabled = mesh_contact_common.GetLocalSpaceNarrowPhaseEnabled()
	mesh_contact_common.SetNarrowPhaseCacheEnabled(cache_enabled)
	mesh_contact_common.SetLocalSpaceNarrowPhaseEnabled(local_space_enabled ~= false)
	mesh_contact_common.ClearNarrowPhaseCache()
	local entities = {}
	local bodies = {}
	local started = system.GetTime()
	local ok, result = xpcall(
		function()
			local terrain = Entity.New{
				Name = cache_enabled and "triangle_cache_terrain_on" or "triangle_cache_terrain_off",
			}
			entities[#entities + 1] = terrain
			terrain:AddComponent("transform")
			terrain.transform:SetPosition(Vec3(0, TERRAIN_OFFSET_Y, 0))
			terrain:AddComponent(
				"rigid_body",
				{
					Shape = MeshShape.New({Polygons = build_chunked_terrain()}),
					MotionType = "static",
					WorldGeometry = true,
					Friction = 0.9,
					Restitution = 0,
				}
			)

			for i = 1, TOTAL_BODIES do
				bodies[#bodies + 1] = spawn_body(i, entities)
			end

			simulate_physics(warmup_steps)

			for i, body in ipairs(bodies) do
				local lateral = Vec3(0.28 + (i % 4) * 0.05, 0, (((i + 1) % 3) - 1) * 0.12)
				body:SetVelocity(body:GetVelocity() + lateral)
			end

			simulate_physics(measure_steps)
			return true
		end,
		debug.traceback
	)
	cleanup_entities(entities)
	mesh_contact_common.ClearNarrowPhaseCache()
	mesh_contact_common.SetNarrowPhaseCacheEnabled(previous_cache_enabled)
	mesh_contact_common.SetLocalSpaceNarrowPhaseEnabled(previous_local_space_enabled)

	if not ok then error(result, 0) end

	return {
		ok = result,
		elapsed = system.GetTime() - started,
	}
end

T.Pending("Mesh triangle cache warm-start scenario completes on chunked terrain", function()
	with_fixed_step(FIXED_DT, function()
		local run = run_cache_scenario(true, true)
		T(run.ok)["=="](true)
		T(run.elapsed)[">"](0)
	end)
end)

T.Pending("Mesh triangle cache scenario completes with cache enabled or disabled", function()
	with_fixed_step(FIXED_DT, function()
		local disabled_run = run_cache_scenario(false, true)
		local enabled_run = run_cache_scenario(true, true)
		T(disabled_run.ok)["=="](true)
		T(enabled_run.ok)["=="](true)
		T(disabled_run.elapsed)[">"](0)
		T(enabled_run.elapsed)[">"](0)
	end)
end)
