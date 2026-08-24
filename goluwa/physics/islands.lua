local stats = import("goluwa/physics/stats.lua")
local islands = {}
-- Persistent simulation islands.
--
-- Island objects survive across substeps instead of being rebuilt from scratch
-- every substep. Island membership is maintained incrementally:
-- - a new link (candidate pair or constraint) between bodies of different
--   islands merges the islands
-- - a removed link marks the island dirty
-- - a dirty island is re-partitioned (union-find) and split if its
--   connectivity actually changed
--
-- Island identity is stable: the root is the dynamic member with the lowest
-- creation rank. Dynamic bodies belong to exactly one island (tracked in a
-- weak body_island map); anchors (static/kinematic/removed-mass bodies) may
-- belong to many islands, matching the old DFS rebuild where an anchor joined
-- every island whose dynamic bodies it touched.
-- packed pair key limit, same scheme as broadphase
local PAIR_KEY_ID_LIMIT = 2097152
local active_islands = {}
local island_pos = {} -- island -> index in active_islands
local body_island = table.weak("k") -- dynamic member body -> island
local prev_pair_links = {} -- pair key -> {a = body, b = body}
local prev_constraints = {} -- constraint -> true
local next_body_rank = 0
local constraint_body_seen = {}
local constraint_body_stamp = 0
local anchor_comp_seen = {}
local anchor_comp_stamp = 0
local moved_anchor_seen = table.weak("k")
local prepare_stamp = 0

local function get_pair_key(entry_a, entry_b)
	local id_a = entry_a.id
	local id_b = entry_b.id

	if id_b < id_a then id_a, id_b = id_b, id_a end

	if id_a >= PAIR_KEY_ID_LIMIT or id_b >= PAIR_KEY_ID_LIMIT then
		return id_a .. "_" .. id_b
	end

	return id_a * PAIR_KEY_ID_LIMIT + id_b
end

local function is_dynamic_body(body)
	return body and body:IsDynamic() and body:HasSolverMass()
end

local function is_anchor_body(body)
	return body and not is_dynamic_body(body)
end

local function is_body_transform_moving(body)
	if not body then return false end

	local previous_position = body:GetPreviousPosition()
	local current_position = body:GetPosition()

	if (current_position - previous_position):GetLength() > 0.0001 then
		return true
	end

	local previous_rotation = body:GetPreviousRotation()
	local current_rotation = body:GetRotation()
	local dot = math.min(1, math.max(-1, math.abs(previous_rotation:Dot(current_rotation))))

	if 1 - dot > 0.0001 then return true end

	return false
end

local function get_body_rank(body)
	local rank = body.IslandRank

	if not rank then
		next_body_rank = next_body_rank + 1
		rank = next_body_rank
		body.IslandRank = rank
	end

	return rank
end

local function add_member(island, body)
	if island.body_set[body] then return end

	island.body_set[body] = true
	island.bodies[#island.bodies + 1] = body

	if is_dynamic_body(body) then
		body_island[body] = island
		island.dynamic_bodies[#island.dynamic_bodies + 1] = body
		local rank = get_body_rank(body)

		if rank < island.root_rank then
			island.root_rank = rank
			island.root = body
		end
	end
end

local function remove_member(island, body)
	if not island.body_set[body] then return end

	island.body_set[body] = nil
	local bodies = island.bodies

	for i = 1, #bodies do
		if bodies[i] == body then
			local last = bodies[#bodies]
			bodies[i] = last
			bodies[#bodies] = nil

			break
		end
	end

	local dynamic_bodies = island.dynamic_bodies

	for i = 1, #dynamic_bodies do
		if dynamic_bodies[i] == body then
			local last = dynamic_bodies[#dynamic_bodies]
			dynamic_bodies[i] = last
			dynamic_bodies[#dynamic_bodies] = nil

			break
		end
	end

	if is_dynamic_body(body) and island.root == body then
		local root = nil
		local root_rank = nil

		for i = 1, #dynamic_bodies do
			local candidate = dynamic_bodies[i]
			local rank = get_body_rank(candidate)

			if not root or rank < root_rank then
				root, root_rank = candidate, rank
			end
		end

		if root then
			island.root = root
			island.root_rank = root_rank
		end
	end
end

local function create_island(root_body)
	local island = {
		root = root_body,
		root_rank = get_body_rank(root_body),
		bodies = {},
		body_set = {},
		dynamic_bodies = {},
		pair_links = {},
		pair_slot = {},
		pair_keys = {},
		pairs = {},
		constraint_set = {},
		constraints = {},
		awake_dynamic_bodies = {},
		constraint_dynamic_bodies = {},
	}
	active_islands[#active_islands + 1] = island
	island_pos[island] = #active_islands
	add_member(island, root_body)
	stats:Count("island_created")
	return island
end

local function destroy_island(island)
	for body in pairs(island.body_set) do
		body_island[body] = nil
	end

	island.body_set = {}
	local pos = island_pos[island]

	if pos then
		island_pos[island] = nil
		local last = active_islands[#active_islands]
		active_islands[pos] = last
		active_islands[#active_islands] = nil

		if last ~= island then island_pos[last] = pos end
	end

	stats:Count("island_destroyed")
end

local function add_pair_slot(island, key, pair)
	local pairs = island.pairs
	local slot = #pairs + 1
	pairs[slot] = pair
	island.pair_slot[key] = slot
	island.pair_keys[slot] = key
end

local function remove_pair_slot(island, key)
	local slot = island.pair_slot[key]

	if not slot then return end

	island.pair_slot[key] = nil
	local pairs = island.pairs
	local last_index = #pairs

	if slot ~= last_index then
		local last_key = island.pair_keys[last_index]
		pairs[slot] = pairs[last_index]
		island.pair_keys[slot] = last_key
		island.pair_slot[last_key] = slot
	end

	pairs[last_index] = nil
	island.pair_keys[last_index] = nil
end

local function remove_constraint_from_island(island, constraint)
	if not island.constraint_set[constraint] then return end

	island.constraint_set[constraint] = nil
	local constraints = island.constraints

	for i = 1, #constraints do
		if constraints[i] == constraint then
			local last = constraints[#constraints]
			constraints[i] = last
			constraints[#constraints] = nil

			break
		end
	end

	island.needs_constraint_refresh = true
	island.dirty = true
end

local function merge_islands(island_a, island_b)
	local main, other

	if island_a.root_rank <= island_b.root_rank then
		main, other = island_a, island_b
	else
		main, other = island_b, island_a
	end

	for body in pairs(other.body_set) do
		add_member(main, body)
	end

	for key, link in pairs(other.pair_links) do
		main.pair_links[key] = link
		local slot = other.pair_slot[key]

		if slot then add_pair_slot(main, key, other.pairs[slot]) end
	end

	for constraint in pairs(other.constraint_set) do
		if not main.constraint_set[constraint] then
			main.constraint_set[constraint] = true
			main.constraints[#main.constraints + 1] = constraint
			main.needs_constraint_refresh = true
		end
	end

	other.pair_links = {}
	other.pair_slot = {}
	other.pair_keys = {}
	other.pairs = {}
	other.constraint_set = {}
	other.constraints = {}
	other.bodies = {}
	other.dynamic_bodies = {}
	other.body_set = {}
	destroy_island(other)
	stats:Count("island_merge")
	return main
end

-- attach a body to an island and return the island it now belongs to. Dynamic
-- bodies belong to exactly one island, so attaching one that belongs elsewhere
-- merges the islands; anchors may belong to many islands and are simply
-- (re)added
local function attach_body(island, body)
	if not body then return island end

	if is_dynamic_body(body) then
		local mapped = body_island[body]

		if mapped and mapped ~= island then
			island = merge_islands(mapped, island)
		end

		if body_island[body] ~= island then add_member(island, body) end

		return island
	end

	if not island.body_set[body] then add_member(island, body) end

	return island
end

-- link two bodies into a shared island. Anchors never bridge two dynamic
-- islands; they simply join the island of the dynamic side
local function link_bodies(body_a, body_b)
	local dynamic_a = is_dynamic_body(body_a)
	local dynamic_b = is_dynamic_body(body_b)

	if not dynamic_a and not dynamic_b then return nil end

	local island = dynamic_a and body_island[body_a] or nil

	if not island then
		island = dynamic_b and
			body_island[body_b] or
			create_island(dynamic_a and body_a or body_b)
	end

	island = attach_body(island, body_a)
	island = attach_body(island, body_b)
	return island
end

local function refresh_constraint_summary(island)
	local out = island.constraint_dynamic_bodies
	list.clear(out)
	constraint_body_stamp = constraint_body_stamp + 1
	local stamp = constraint_body_stamp

	for constraint in pairs(island.constraint_set) do
		local body_a = constraint.Body0

		if is_dynamic_body(body_a) and constraint_body_seen[body_a] ~= stamp then
			constraint_body_seen[body_a] = stamp
			out[#out + 1] = body_a
		end

		local body_b = constraint.Body1

		if is_dynamic_body(body_b) and constraint_body_seen[body_b] ~= stamp then
			constraint_body_seen[body_b] = stamp
			out[#out + 1] = body_b
		end
	end

	island.has_constraints = next(island.constraint_set) ~= nil
end

local function clear_membership(island)
	for body in pairs(island.body_set) do
		-- a non-kept dynamic may have been re-mapped to a fresh island above
		if body_island[body] == island then body_island[body] = nil end
	end

	island.body_set = {}
	list.clear(island.bodies)
	list.clear(island.dynamic_bodies)
end

local function find_root_index(parent, i)
	while parent[i] ~= i do
		parent[i] = parent[parent[i]]
		i = parent[i]
	end

	return i
end

local function union(parent, i, j)
	i, j = find_root_index(parent, i), find_root_index(parent, j)

	if i ~= j then parent[j] = i end
end

-- re-partition a dirty island; components other than the root's spawn new
-- islands, anchors re-attach to every component a live link connects them to
local function split_island(island)
	island.dirty = false
	local dynamics = island.dynamic_bodies
	local dynamic_count = #dynamics

	if dynamic_count == 0 then
		destroy_island(island)
		return
	end

	local index_of = {}

	for i = 1, dynamic_count do
		index_of[dynamics[i]] = i
	end

	local parent = {}

	for i = 1, dynamic_count do
		parent[i] = i
	end

	for _, link in pairs(island.pair_links) do
		if island.body_set[link.a] and island.body_set[link.b] then
			local i = index_of[link.a]
			local j = index_of[link.b]

			if i and j then union(parent, i, j) end
		end
	end

	for constraint in pairs(island.constraint_set) do
		local i = constraint.Body0 and index_of[constraint.Body0] or nil
		local j = constraint.Body1 and index_of[constraint.Body1] or nil

		if i and j then union(parent, i, j) end
	end

	local components = {}
	local component_count = 0

	for i = 1, dynamic_count do
		local r = find_root_index(parent, i)
		local comp = components[r]

		if not comp then
			comp = {dynamics = {}, anchors = {}}
			components[r] = comp
			component_count = component_count + 1
		end

		comp.dynamics[#comp.dynamics + 1] = dynamics[i]
	end

	local dropped_anchor_count = 0

	for i = 1, #island.bodies do
		local body = island.bodies[i]

		if not index_of[body] then
			anchor_comp_stamp = anchor_comp_stamp + 1
			local comp_stamp = anchor_comp_stamp
			local attached_any = false

			for _, link in pairs(island.pair_links) do
				local other

				if link.a == body then
					other = link.b
				elseif link.b == body then
					other = link.a
				end

				local j = other and index_of[other] or nil

				if j then
					local r = find_root_index(parent, j)

					if anchor_comp_seen[r] ~= comp_stamp then
						anchor_comp_seen[r] = comp_stamp
						local comp = components[r]
						comp.anchors[#comp.anchors + 1] = body
					end

					attached_any = true
				end
			end

			if not attached_any then
				for constraint in pairs(island.constraint_set) do
					local other

					if constraint.Body0 == body then
						other = constraint.Body1
					elseif constraint.Body1 == body then
						other = constraint.Body0
					end

					local j = other and index_of[other] or nil

					if j then
						local r = find_root_index(parent, j)

						if anchor_comp_seen[r] ~= comp_stamp then
							anchor_comp_seen[r] = comp_stamp
							local comp = components[r]
							comp.anchors[#comp.anchors + 1] = body
						end

						attached_any = true
					end
				end
			end

			if not attached_any then
				dropped_anchor_count = dropped_anchor_count + 1
			end
		end
	end

	-- connectivity is intact: nothing to do
	if component_count == 1 and dropped_anchor_count == 0 then return end

	local root_index = index_of[island.root]
	local keep_root = root_index and find_root_index(parent, root_index) or nil
	local kept = keep_root and components[keep_root] or nil

	if not kept then
		-- root is gone; keep the first component found
		for r, comp in pairs(components) do
			keep_root = r
			kept = comp

			break
		end
	end

	-- copy the links of every other component into fresh islands before
	-- pruning the root island
	for r, comp in pairs(components) do
		if r ~= keep_root then
			local new_island = create_island(comp.dynamics[1])

			for i = 2, #comp.dynamics do
				add_member(new_island, comp.dynamics[i])
			end

			for i = 1, #comp.anchors do
				add_member(new_island, comp.anchors[i])
			end

			for key, link in pairs(island.pair_links) do
				if new_island.body_set[link.a] and new_island.body_set[link.b] then
					new_island.pair_links[key] = link
					local slot = island.pair_slot[key]

					if slot then add_pair_slot(new_island, key, island.pairs[slot]) end
				end
			end

			for constraint in pairs(island.constraint_set) do
				local body_a = constraint.Body0
				local body_b = constraint.Body1

				if new_island.body_set[body_a] and new_island.body_set[body_b] then
					new_island.constraint_set[constraint] = true
					new_island.constraints[#new_island.constraints + 1] = constraint
					new_island.needs_constraint_refresh = true
				end
			end
		end
	end

	if component_count > 1 then stats:Count("island_split") end

	-- rebuild the root island from its component
	clear_membership(island)

	for i = 1, #kept.dynamics do
		add_member(island, kept.dynamics[i])
	end

	for i = 1, #kept.anchors do
		add_member(island, kept.anchors[i])
	end

	for key, link in pairs(island.pair_links) do
		if not (island.body_set[link.a] and island.body_set[link.b]) then
			island.pair_links[key] = nil
			remove_pair_slot(island, key)
		end
	end

	for constraint in pairs(island.constraint_set) do
		local body_a = constraint.Body0
		local body_b = constraint.Body1

		if not (island.body_set[body_a] and island.body_set[body_b]) then
			island.constraint_set[constraint] = nil
			local constraints = island.constraints

			for i = 1, #constraints do
				if constraints[i] == constraint then
					local last = constraints[#constraints]
					constraints[i] = last
					constraints[#constraints] = nil

					break
				end
			end

			island.needs_constraint_refresh = true
		end
	end

	island.dirty = false
end

function islands.UpdateSimulationIslands(bodies, candidate_pairs, constraints, solver)
	constraints = constraints or {}
	candidate_pairs = candidate_pairs or {}

	for i = 1, #bodies do
		local body = bodies[i]

		if is_dynamic_body(body) and body_island[body] == nil then
			create_island(body)
		end
	end

	local curr_links = {}

	for i = 1, #candidate_pairs do
		local pair = candidate_pairs[i]
		local body_a = pair.entry_a.body
		local body_b = pair.entry_b.body

		if not (is_dynamic_body(body_a) or is_dynamic_body(body_b)) then
			goto continue_pair
		end

		if solver and not solver:IslandPairFilter(pair) then goto continue_pair end

		local key = get_pair_key(pair.entry_a, pair.entry_b)

		if prev_pair_links[key] then
			local island

			if is_dynamic_body(body_a) then
				island = body_island[body_a]
			elseif is_dynamic_body(body_b) then
				island = body_island[body_b]
			end

			if island then
				local link = prev_pair_links[key]

				if link.a ~= body_a or link.b ~= body_b then
					link.a = body_a
					link.b = body_b
				end

				-- mark the link as current so the removal pass keeps it
				curr_links[key] = link
				local slot = island.pair_slot[key]

				if slot and island.pairs[slot] ~= pair then
					-- the pair object was recreated (overflow entries); replace in place
					island.pairs[slot] = pair
				elseif not slot then
					island.pair_links[key] = link
					add_pair_slot(island, key, pair)
				end

				island = attach_body(island, body_a)
				island = attach_body(island, body_b)
			end
		else
			curr_links[key] = {a = body_a, b = body_b}
			local island = link_bodies(body_a, body_b)

			if island then
				island.pair_links[key] = curr_links[key]
				add_pair_slot(island, key, pair)
			end
		end

		::continue_pair::
	end

	for key, link in pairs(prev_pair_links) do
		if curr_links[key] == nil then
			local island

			if is_dynamic_body(link.a) then
				island = body_island[link.a]
			elseif is_dynamic_body(link.b) then
				island = body_island[link.b]
			end

			if island and island.pair_links[key] then
				island.pair_links[key] = nil
				remove_pair_slot(island, key)
				island.dirty = true
			end
		end
	end

	prev_pair_links = curr_links
	local curr_constraints = {}

	for i = 1, #constraints do
		local constraint = constraints[i]

		if constraint and constraint.Enabled ~= false and constraint:IsValid() then
			curr_constraints[constraint] = true

			if prev_constraints[constraint] == nil then
				local body_a = constraint.Body0
				local body_b = constraint.Body1
				-- a constraint outlives its bodies; a body removed since the
				-- constraint was created must not be (re)linked into an island
				local bodies_valid = (not body_a or body_a:IsValid()) and (not body_b or body_b:IsValid())

				if bodies_valid and (is_dynamic_body(body_a) or is_dynamic_body(body_b)) then
					local island = link_bodies(body_a, body_b)

					if island and not island.constraint_set[constraint] then
						island.constraint_set[constraint] = true
						island.constraints[#island.constraints + 1] = constraint
						island.needs_constraint_refresh = true
					end
				end
			end
		end
	end

	for constraint in pairs(prev_constraints) do
		if curr_constraints[constraint] == nil then
			local island = body_island[constraint.Body0] or body_island[constraint.Body1]

			if island and island.constraint_set[constraint] then
				remove_constraint_from_island(island, constraint)
			end
		end
	end

	prev_constraints = curr_constraints
	local island_count = #active_islands

	for i = island_count, 1, -1 do
		local island = active_islands[i]

		if island.dirty then split_island(island) end
	end

	for i = 1, #active_islands do
		local island = active_islands[i]

		if island.needs_constraint_refresh then
			island.needs_constraint_refresh = nil
			refresh_constraint_summary(island)
		end
	end

	return active_islands
end

local function wake_dynamic_body(body, awake_dynamic_bodies, newly_awoken_bodies)
	if not is_dynamic_body(body) then return false end

	if body:GetAwake() then return false end

	body:Wake()
	awake_dynamic_bodies[#awake_dynamic_bodies + 1] = body
	newly_awoken_bodies[#newly_awoken_bodies + 1] = body
	return true
end

function islands.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)
	newly_awoken_bodies = newly_awoken_bodies or {}
	list.clear(newly_awoken_bodies)
	local woke_any = false
	prepare_stamp = prepare_stamp + 1
	local stamp = prepare_stamp

	for island_index = 1, #(simulation_islands or {}) do
		local island = simulation_islands[island_index]
		local dynamic_bodies = island.dynamic_bodies
		local awake_dynamic_bodies = island.awake_dynamic_bodies
		local active_dynamic_count = 0
		list.clear(awake_dynamic_bodies)
		island.awake_dynamic_bodies = awake_dynamic_bodies

		for body_index = 1, #dynamic_bodies do
			local body = dynamic_bodies[body_index]

			if body:GetAwake() then
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

			if not body:GetAwake() and body:GetGrounded() then
				local ground_body = body.GroundBody

				if
					ground_body and
					ground_body ~= body and
					(
						is_body_transform_moving(ground_body) or
						(
							is_dynamic_body(ground_body) and
							ground_body:GetAwake()
						)
					)
				then
					if wake_dynamic_body(body, awake_dynamic_bodies, newly_awoken_bodies) then
						stats:Count("wake_ground")
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
				moved_anchor_seen[body_b]
			then
				if wake_dynamic_body(body_a, awake_dynamic_bodies, newly_awoken_bodies) then
					stats:Count("wake_anchor")
					active_dynamic_count = active_dynamic_count + 1
					woke_any = true
				end
			end

			if
				is_dynamic_body(body_b) and
				not body_b:GetAwake()
				and
				moved_anchor_seen[body_a]
			then
				if wake_dynamic_body(body_b, awake_dynamic_bodies, newly_awoken_bodies) then
					stats:Count("wake_anchor")
					active_dynamic_count = active_dynamic_count + 1
					woke_any = true
				end
			end
		end

		if active_dynamic_count > 0 and island.has_constraints then
			for body_index = 1, #(island.constraint_dynamic_bodies or {}) do
				local body = island.constraint_dynamic_bodies[body_index]

				if wake_dynamic_body(body, awake_dynamic_bodies, newly_awoken_bodies) then
					stats:Count("wake_constraint")
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

-- remove a body from island membership. Dynamic bodies leave their single
-- island; anchors are removed from every island they belong to
local function detach_body_from_island(island, body)
	remove_member(island, body)

	for key, link in pairs(island.pair_links) do
		if link.a == body or link.b == body then
			island.pair_links[key] = nil
			remove_pair_slot(island, key)
			island.dirty = true
		end
	end

	for constraint in pairs(island.constraint_set) do
		if constraint.Body0 == body or constraint.Body1 == body then
			remove_constraint_from_island(island, constraint)
			-- so the next constraint diff re-evaluates the link instead of
			-- treating it as unchanged
			prev_constraints[constraint] = nil
		end
	end
end

function islands.RemoveBody(body)
	if not body then return end

	local island = body_island[body]

	if is_dynamic_body(body) then
		if not island then return end

		body_island[body] = nil
		detach_body_from_island(island, body)

		if #island.dynamic_bodies == 0 then destroy_island(island) end

		return
	end

	-- a body that just lost its dynamic-ness still maps to its old island
	body_island[body] = nil

	for i = #active_islands, 1, -1 do
		local island = active_islands[i]

		if island.body_set[body] then
			detach_body_from_island(island, body)

			if #island.dynamic_bodies == 0 then destroy_island(island) end
		end
	end
end

function islands.ResetState()
	for island in pairs(island_pos) do
		island_pos[island] = nil
	end

	list.clear(active_islands)
	body_island = table.weak("k")
	prev_pair_links = {}
	prev_constraints = {}
	next_body_rank = 0
end

islands.ResetState()
return islands
