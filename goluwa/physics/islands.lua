local islands = {}
-- persistent per-body link lists, reused across builds (weak: bodies die)
local pair_link_lists = setmetatable({}, {__mode = "k"})
local constraint_link_lists = setmetatable({}, {__mode = "k"})
local EMPTY_LINKS = {}
-- stamp based dedup: seen[x] == stamp means x was visited for this island/build
local body_seen = setmetatable({}, {__mode = "k"})
local pair_seen = setmetatable({}, {__mode = "k"})
local constraint_seen = setmetatable({}, {__mode = "k"})
local constraint_body_seen = setmetatable({}, {__mode = "k"})
local awake_seen = setmetatable({}, {__mode = "k"})
local moved_anchor_seen = setmetatable({}, {__mode = "k"})
local visited_dynamic = setmetatable({}, {__mode = "k"})
local island_stamp = 0
local build_stamp = 0
local prepare_stamp = 0
local stack = {}
-- island tables are pooled: the previous build's tables are dead by the time
-- the next build starts (islands are consumed within a single substep)
local pool = {}
local pool_count = 0
local last_build_tables = nil
local build_table_count = 0

local function take_table()
	pool_count = pool_count - 1
	local t = pool[pool_count]

	if t == nil then return {} end

	pool[pool_count] = nil
	list.clear(t)
	return t
end

local function record_build_table(t)
	build_table_count = build_table_count + 1
	last_build_tables[build_table_count] = t
end

local function is_dynamic_body(body)
	return body and body:IsDynamic() and body:HasSolverMass()
end

local function is_anchor_body(body)
	return body and not is_dynamic_body(body)
end

local function is_body_transform_moving(body)
	if not body then return false end

	local previous_position = body.GetPreviousPosition and body:GetPreviousPosition() or body.PreviousPosition
	local current_position = body.GetPosition and body:GetPosition() or body.Position

	if
		previous_position and
		current_position and
		(
			current_position - previous_position
		):GetLength() > 0.0001
	then
		return true
	end

	local previous_rotation = body.GetPreviousRotation and body:GetPreviousRotation() or body.PreviousRotation
	local current_rotation = body.GetRotation and body:GetRotation() or body.Rotation

	if previous_rotation and current_rotation then
		local dot = math.min(1, math.max(-1, math.abs(previous_rotation:Dot(current_rotation))))

		if 1 - dot > 0.0001 then return true end
	end

	return false
end

local function add_island_body(island_bodies, island_dynamic_bodies, stamp, body)
	if body_seen[body] == stamp then return end

	body_seen[body] = stamp
	island_bodies[#island_bodies + 1] = body

	if is_dynamic_body(body) then
		island_dynamic_bodies[#island_dynamic_bodies + 1] = body
	end
end

local function register_link(map, body, value)
	if not body then return end

	local list = map[body]

	if not list then
		list = {}
		map[body] = list
	end

	list[#list + 1] = value
end

local function get_pair_other_body(pair, body)
	if pair.entry_a.body == body then return pair.entry_b.body end

	if pair.entry_b.body == body then return pair.entry_a.body end

	return nil
end

local function get_constraint_other_body(constraint, body)
	if constraint.Body0 == body then return constraint.Body1 end

	if constraint.Body1 == body then return constraint.Body0 end

	return nil
end

local function wake_dynamic_body(stamp, body, awake_dynamic_bodies, newly_awoken_bodies)
	if not (is_dynamic_body(body) and awake_seen[body] ~= stamp) then
		return false
	end

	body:Wake()
	awake_seen[body] = stamp
	awake_dynamic_bodies[#awake_dynamic_bodies + 1] = body
	newly_awoken_bodies[#newly_awoken_bodies + 1] = body
	return true
end

function islands.BuildSimulationIslands(bodies, body_pairs, constraints)
	bodies = bodies or {}
	body_pairs = body_pairs or {}
	constraints = constraints or {}
	-- the previous build's tables are no longer referenced
	pool = last_build_tables or pool
	pool_count = #pool
	last_build_tables = {}
	build_table_count = 0

	for body in pairs(pair_link_lists) do
		list.clear(pair_link_lists[body])
	end

	for body in pairs(constraint_link_lists) do
		list.clear(constraint_link_lists[body])
	end

	build_stamp = build_stamp + 1

	for i = 1, #body_pairs do
		local pair = body_pairs[i]
		local body_a = pair.entry_a.body
		local body_b = pair.entry_b.body
		register_link(pair_link_lists, body_a, pair)
		register_link(pair_link_lists, body_b, pair)
	end

	for i = 1, #constraints do
		local constraint = constraints[i]

		if constraint and constraint.Enabled ~= false then
			register_link(constraint_link_lists, constraint.Body0, constraint)
			register_link(constraint_link_lists, constraint.Body1, constraint)
		end
	end

	local built_islands = {}

	for i = 1, #bodies do
		local root = bodies[i]

		if is_dynamic_body(root) and visited_dynamic[root] ~= build_stamp then
			island_stamp = island_stamp + 1
			local stamp = island_stamp
			local island = take_table()
			local island_bodies = take_table()
			local island_dynamic_bodies = take_table()
			local island_awake_dynamic_bodies = take_table()
			local island_constraint_dynamic_bodies = take_table()
			local island_pairs = take_table()
			local island_constraints = take_table()
			island.bodies = island_bodies
			island.dynamic_bodies = island_dynamic_bodies
			island.awake_dynamic_bodies = island_awake_dynamic_bodies
			island.constraint_dynamic_bodies = island_constraint_dynamic_bodies
			island.pairs = island_pairs
			island.constraints = island_constraints
			island.has_constraints = false
			record_build_table(island)
			record_build_table(island_bodies)
			record_build_table(island_dynamic_bodies)
			record_build_table(island_awake_dynamic_bodies)
			record_build_table(island_constraint_dynamic_bodies)
			record_build_table(island_pairs)
			record_build_table(island_constraints)
			visited_dynamic[root] = build_stamp
			stack[1] = root
			local stack_size = 1

			while stack_size > 0 do
				local body = stack[stack_size]
				stack[stack_size] = nil
				stack_size = stack_size - 1
				add_island_body(island_bodies, island_dynamic_bodies, stamp, body)
				local body_pairs = pair_link_lists[body] or EMPTY_LINKS

				for pair_index = 1, #body_pairs do
					local pair = body_pairs[pair_index]

					if pair_seen[pair] ~= stamp then
						pair_seen[pair] = stamp
						island_pairs[#island_pairs + 1] = pair
					end

					local other = get_pair_other_body(pair, body)

					if is_dynamic_body(other) then
						add_island_body(island_bodies, island_dynamic_bodies, stamp, other)

						if visited_dynamic[other] ~= build_stamp then
							visited_dynamic[other] = build_stamp
							stack_size = stack_size + 1
							stack[stack_size] = other
						end
					elseif is_anchor_body(other) then
						add_island_body(island_bodies, island_dynamic_bodies, stamp, other)
					end
				end

				local body_constraints = constraint_link_lists[body] or EMPTY_LINKS

				for constraint_index = 1, #body_constraints do
					local constraint = body_constraints[constraint_index]

					if constraint_seen[constraint] ~= stamp then
						constraint_seen[constraint] = stamp
						island_constraints[#island_constraints + 1] = constraint
						island.has_constraints = true

						if
							is_dynamic_body(constraint.Body0) and
							constraint_body_seen[constraint.Body0] ~= stamp
						then
							constraint_body_seen[constraint.Body0] = stamp
							island_constraint_dynamic_bodies[#island_constraint_dynamic_bodies + 1] = constraint.Body0
						end

						if
							is_dynamic_body(constraint.Body1) and
							constraint_body_seen[constraint.Body1] ~= stamp
						then
							constraint_body_seen[constraint.Body1] = stamp
							island_constraint_dynamic_bodies[#island_constraint_dynamic_bodies + 1] = constraint.Body1
						end
					end

					local other = get_constraint_other_body(constraint, body)

					if is_dynamic_body(other) then
						add_island_body(island_bodies, island_dynamic_bodies, stamp, other)

						if visited_dynamic[other] ~= build_stamp then
							visited_dynamic[other] = build_stamp
							stack_size = stack_size + 1
							stack[stack_size] = other
						end
					elseif is_anchor_body(other) then
						add_island_body(island_bodies, island_dynamic_bodies, stamp, other)
					end
				end
			end

			built_islands[#built_islands + 1] = island
		end
	end

	return built_islands
end

function islands.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)
	newly_awoken_bodies = newly_awoken_bodies or {}
	list.clear(newly_awoken_bodies)
	local woke_any = false

	for island_index = 1, #(simulation_islands or {}) do
		local island = simulation_islands[island_index]
		local dynamic_bodies = island.dynamic_bodies
		local awake_dynamic_bodies = island.awake_dynamic_bodies
		local active_dynamic_count = 0
		prepare_stamp = prepare_stamp + 1
		local stamp = prepare_stamp
		list.clear(awake_dynamic_bodies)
		island.awake_dynamic_bodies = awake_dynamic_bodies

		for body_index = 1, #dynamic_bodies do
			local body = dynamic_bodies[body_index]

			if body:GetAwake() then
				awake_seen[body] = stamp
				awake_dynamic_bodies[#awake_dynamic_bodies + 1] = body
				active_dynamic_count = active_dynamic_count + 1
			end
		end

		island.active_dynamic_count = active_dynamic_count
		island.sleeping = active_dynamic_count == 0

		for body_index = 1, #(island.bodies or {}) do
			local body = island.bodies[body_index]

			if is_anchor_body(body) and is_body_transform_moving(body) then
				moved_anchor_seen[body] = stamp
			end
		end

		for body_index = 1, #dynamic_bodies do
			local body = dynamic_bodies[body_index]

			if not body:GetAwake() and body.GetGrounded and body:GetGrounded() then
				local ground_body = body.GetGroundBody and body:GetGroundBody() or body.GroundBody

				if
					ground_body and
					ground_body ~= body and
					(
						is_body_transform_moving(ground_body) or
						(
							is_dynamic_body(ground_body) and
							ground_body.GetAwake and
							ground_body:GetAwake()
						)
					)
				then
					if wake_dynamic_body(stamp, body, awake_dynamic_bodies, newly_awoken_bodies) then
						active_dynamic_count = active_dynamic_count + 1
						woke_any = true
					end
				end
			end
		end

		for pair_index = 1, #(island.pairs or {}) do
			local pair = island.pairs[pair_index]
			local body_a = pair.entry_a.body
			local body_b = pair.entry_b.body

			if
				is_dynamic_body(body_a) and
				not body_a:GetAwake()
				and
				moved_anchor_seen[body_b] == stamp
			then
				if wake_dynamic_body(stamp, body_a, awake_dynamic_bodies, newly_awoken_bodies) then
					active_dynamic_count = active_dynamic_count + 1
					woke_any = true
				end
			end

			if
				is_dynamic_body(body_b) and
				not body_b:GetAwake()
				and
				moved_anchor_seen[body_a] == stamp
			then
				if wake_dynamic_body(stamp, body_b, awake_dynamic_bodies, newly_awoken_bodies) then
					active_dynamic_count = active_dynamic_count + 1
					woke_any = true
				end
			end
		end

		if active_dynamic_count > 0 and island.has_constraints then
			for body_index = 1, #(island.constraint_dynamic_bodies or {}) do
				local body = island.constraint_dynamic_bodies[body_index]

				if wake_dynamic_body(stamp, body, awake_dynamic_bodies, newly_awoken_bodies) then
					active_dynamic_count = active_dynamic_count + 1
					woke_any = true
				end
			end
		end

		island.active_dynamic_count = active_dynamic_count
		island.sleeping = active_dynamic_count == 0
	end

	return woke_any, newly_awoken_bodies
end

function islands.FinalizeSimulationIslands(simulation_islands)
	local slept_any = false

	for island_index = 1, #(simulation_islands or {}) do
		local island = simulation_islands[island_index]

		if island.has_constraints then
			local dynamic_bodies = island.dynamic_bodies
			local has_awake_dynamic_body = false
			local can_sleep_island = #dynamic_bodies > 1

			for body_index = 1, #dynamic_bodies do
				local body = dynamic_bodies[body_index]

				if body:GetAwake() then has_awake_dynamic_body = true end

				if not body:CanSleepNow() then
					can_sleep_island = false

					break
				end
			end

			if has_awake_dynamic_body and can_sleep_island then
				for body_index = 1, #dynamic_bodies do
					local body = dynamic_bodies[body_index]

					if body:GetAwake() then body:Sleep() end
				end

				if island.awake_dynamic_bodies then list.clear(island.awake_dynamic_bodies) end

				island.active_dynamic_count = 0
				island.sleeping = true
				slept_any = true
			end
		end
	end

	return slept_any
end

function islands.IsSleepingIsland(island)
	return island and island.sleeping == true or false
end

return islands
