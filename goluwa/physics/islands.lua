local islands = {}

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

local function add_unique(list, lookup, value)
	if not value or lookup[value] then return end

	lookup[value] = true
	list[#list + 1] = value
end

local function add_island_body(island, body_lookup, dynamic_lookup, body)
	add_unique(island.bodies, body_lookup, body)

	if is_dynamic_body(body) then
		add_unique(island.dynamic_bodies, dynamic_lookup, body)
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

local function wake_dynamic_body(body, awake_dynamic_lookup, awake_dynamic_bodies, newly_awoken_bodies)
	if not (is_dynamic_body(body) and not awake_dynamic_lookup[body]) then
		return false
	end

	body:Wake()
	awake_dynamic_bodies[#awake_dynamic_bodies + 1] = body
	awake_dynamic_lookup[body] = true
	newly_awoken_bodies[#newly_awoken_bodies + 1] = body
	return true
end

function islands.BuildSimulationIslands(bodies, pairs, constraints)
	bodies = bodies or {}
	pairs = pairs or {}
	constraints = constraints or {}
	local pair_links = {}
	local constraint_links = {}

	for i = 1, #pairs do
		local pair = pairs[i]
		local body_a = pair.entry_a.body
		local body_b = pair.entry_b.body
		register_link(pair_links, body_a, pair)
		register_link(pair_links, body_b, pair)
	end

	for i = 1, #constraints do
		local constraint = constraints[i]

		if constraint and constraint.Enabled ~= false then
			register_link(constraint_links, constraint.Body0, constraint)
			register_link(constraint_links, constraint.Body1, constraint)
		end
	end

	local built_islands = {}
	local visited_dynamic = {}
	local stack = {}

	for i = 1, #bodies do
		local root = bodies[i]

		if is_dynamic_body(root) and not visited_dynamic[root] then
			local island = {
				bodies = {},
				dynamic_bodies = {},
				awake_dynamic_bodies = {},
				constraint_dynamic_bodies = {},
				pairs = {},
				constraints = {},
				has_constraints = false,
			}
			local body_lookup = {}
			local dynamic_lookup = {}
			local constraint_dynamic_lookup = {}
			local pair_lookup = {}
			local constraint_lookup = {}
			stack[1] = root
			local stack_size = 1
			visited_dynamic[root] = true

			while stack_size > 0 do
				local body = stack[stack_size]
				stack[stack_size] = nil
				stack_size = stack_size - 1
				add_island_body(island, body_lookup, dynamic_lookup, body)

				for _, pair in ipairs(pair_links[body] or {}) do
					if not pair_lookup[pair] then
						pair_lookup[pair] = true
						island.pairs[#island.pairs + 1] = pair
					end

					local other = get_pair_other_body(pair, body)

					if is_dynamic_body(other) then
						add_island_body(island, body_lookup, dynamic_lookup, other)

						if not visited_dynamic[other] then
							visited_dynamic[other] = true
							stack_size = stack_size + 1
							stack[stack_size] = other
						end
					elseif is_anchor_body(other) then
						add_island_body(island, body_lookup, dynamic_lookup, other)
					end
				end

				for _, constraint in ipairs(constraint_links[body] or {}) do
					if not constraint_lookup[constraint] then
						constraint_lookup[constraint] = true
						island.constraints[#island.constraints + 1] = constraint
						island.has_constraints = true

						if is_dynamic_body(constraint.Body0) then
							add_unique(island.constraint_dynamic_bodies, constraint_dynamic_lookup, constraint.Body0)
						end

						if is_dynamic_body(constraint.Body1) then
							add_unique(island.constraint_dynamic_bodies, constraint_dynamic_lookup, constraint.Body1)
						end
					end

					local other = get_constraint_other_body(constraint, body)

					if is_dynamic_body(other) then
						add_island_body(island, body_lookup, dynamic_lookup, other)

						if not visited_dynamic[other] then
							visited_dynamic[other] = true
							stack_size = stack_size + 1
							stack[stack_size] = other
						end
					elseif is_anchor_body(other) then
						add_island_body(island, body_lookup, dynamic_lookup, other)
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
		local awake_dynamic_lookup = {}
		local active_dynamic_count = 0
		list.clear(awake_dynamic_bodies)
		island.awake_dynamic_bodies = awake_dynamic_bodies

		for body_index = 1, #dynamic_bodies do
			local body = dynamic_bodies[body_index]

			if body:GetAwake() then
				awake_dynamic_bodies[#awake_dynamic_bodies + 1] = body
				awake_dynamic_lookup[body] = true
				active_dynamic_count = active_dynamic_count + 1
			end
		end

		island.active_dynamic_count = active_dynamic_count
		island.sleeping = active_dynamic_count == 0
		local moved_anchor_lookup = {}

		for body_index = 1, #(island.bodies or {}) do
			local body = island.bodies[body_index]

			if is_anchor_body(body) and is_body_transform_moving(body) then
				moved_anchor_lookup[body] = true
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
					if
						wake_dynamic_body(body, awake_dynamic_lookup, awake_dynamic_bodies, newly_awoken_bodies)
					then
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
				moved_anchor_lookup[body_b]
			then
				if
					wake_dynamic_body(body_a, awake_dynamic_lookup, awake_dynamic_bodies, newly_awoken_bodies)
				then
					active_dynamic_count = active_dynamic_count + 1
					woke_any = true
				end
			end

			if
				is_dynamic_body(body_b) and
				not body_b:GetAwake()
				and
				moved_anchor_lookup[body_a]
			then
				if
					wake_dynamic_body(body_b, awake_dynamic_lookup, awake_dynamic_bodies, newly_awoken_bodies)
				then
					active_dynamic_count = active_dynamic_count + 1
					woke_any = true
				end
			end
		end

		if active_dynamic_count > 0 and island.has_constraints then
			for body_index = 1, #(island.constraint_dynamic_bodies or {}) do
				local body = island.constraint_dynamic_bodies[body_index]

				if
					wake_dynamic_body(body, awake_dynamic_lookup, awake_dynamic_bodies, newly_awoken_bodies)
				then
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
