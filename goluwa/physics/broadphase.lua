local AABB = import("goluwa/structs/aabb.lua")
local broadphase = {}
local Broadphase = {}
Broadphase.__index = Broadphase
local DEFAULT_CELL_SIZE = 2
local MIN_CELL_SIZE = 0.5
local DEFAULT_MAX_CELLS_PER_ENTRY = 64

local function is_candidate_body(physics, body)
	return body and body.CollisionEnabled
end

local entry_aabb_scratch_current = AABB(0, 0, 0, 0, 0, 0)
local entry_aabb_scratch_previous = AABB(0, 0, 0, 0, 0, 0)

-- writes the swept broadphase bounds into out (allocating a new AABB when out
-- is nil); the per-pose shape aabbs are written into module scratch boxes
local function build_entry_bounds(body, out)
	local bounds = body:GetBroadphaseAABB(nil, nil, entry_aabb_scratch_current)
	local previous_bounds = body:GetBroadphaseAABB(
		body:GetPreviousPosition(),
		body:GetPreviousRotation(),
		entry_aabb_scratch_previous
	)

	if not out then out = AABB(0, 0, 0, 0, 0, 0) end

	AABB.Union(out, previous_bounds, bounds)
	return out
end

local function store_entry_pose(entry, body)
	entry.pose_position = body:GetPosition()
	entry.pose_rotation = body:GetRotation()
	entry.pose_prev_position = body:GetPreviousPosition()
	entry.pose_prev_rotation = body:GetPreviousRotation()
end

local function is_entry_pose_current(entry, body)
	return entry.pose_position == body:GetPosition() and
		entry.pose_rotation == body:GetRotation()
		and
		entry.pose_prev_position == body:GetPreviousPosition()
		and
		entry.pose_prev_rotation == body:GetPreviousRotation()
end

local function get_cell_index(value, cell_size)
	return math.floor(value / cell_size)
end

local function get_cell_range(bounds, cell_size)
	local min_x = get_cell_index(bounds.min_x, cell_size)
	local min_y = get_cell_index(bounds.min_y, cell_size)
	local min_z = get_cell_index(bounds.min_z, cell_size)
	local max_x = get_cell_index(bounds.max_x, cell_size)
	local max_y = get_cell_index(bounds.max_y, cell_size)
	local max_z = get_cell_index(bounds.max_z, cell_size)
	return min_x, min_y, min_z, max_x, max_y, max_z
end

-- packed integer cell keys: exact in a double (max ~5.5e11 < 2^53) for
-- indices within +/- CELL_KEY_RANGE, no string allocation. Out-of-range
-- indices fall back to string keys rather than risk a collision.
local CELL_KEY_RANGE = 4095
local CELL_KEY_STRIDE = 8192
local CELL_KEY_STRIDE2 = CELL_KEY_STRIDE * CELL_KEY_STRIDE

local function get_cell_key(x, y, z)
	if
		x >= -CELL_KEY_RANGE and
		x < CELL_KEY_RANGE and
		y >= -CELL_KEY_RANGE and
		y < CELL_KEY_RANGE and
		z >= -CELL_KEY_RANGE and
		z < CELL_KEY_RANGE
	then
		return (
				x + CELL_KEY_RANGE
			) * CELL_KEY_STRIDE2 + (
				y + CELL_KEY_RANGE
			) * CELL_KEY_STRIDE + (
				z + CELL_KEY_RANGE
			)
	end

	return x .. ":" .. y .. ":" .. z
end

local function get_cell_span_count(min_x, min_y, min_z, max_x, max_y, max_z)
	return (max_x - min_x + 1) * (max_y - min_y + 1) * (max_z - min_z + 1)
end

-- packed numeric pair keys: exact in a double while both ids stay under
-- 2^21 (ids are per-broadphase and small); falls back to string keys beyond
local PAIR_KEY_ID_LIMIT = 2097152

local function get_pair_key(entry_a, entry_b)
	local id_a = entry_a.id
	local id_b = entry_b.id

	if id_a >= PAIR_KEY_ID_LIMIT or id_b >= PAIR_KEY_ID_LIMIT then
		if id_a < id_b then return id_a .. ":" .. id_b end

		return id_b .. ":" .. id_a
	end

	if id_a < id_b then return id_a * PAIR_KEY_ID_LIMIT + id_b end

	return id_b * PAIR_KEY_ID_LIMIT + id_a
end

local function remove_entry_from_overflow(self, entry)
	if not entry.is_overflow then return end

	local index = entry.overflow_index
	local last = self.OverflowEntries[#self.OverflowEntries]
	self.OverflowEntries[index] = last
	self.OverflowEntries[#self.OverflowEntries] = nil

	if last and last ~= entry then last.overflow_index = index end

	entry.is_overflow = false
	entry.overflow_index = nil
end

local function get_or_create_cell(self, key)
	local cell = self.Cells[key]

	if cell then return cell end

	cell = {
		entries = {},
		indices = {},
	}
	self.Cells[key] = cell
	return cell
end

local function register_pair(self, entry_a, entry_b)
	if entry_a == entry_b then return end

	local key = get_pair_key(entry_a, entry_b)
	local pair = self.Pairs[key]

	if pair then
		pair.shared_cells = pair.shared_cells + 1
		return pair
	end

	if entry_b.id < entry_a.id then entry_a, entry_b = entry_b, entry_a end

	pair = {
		entry_a = entry_a,
		entry_b = entry_b,
		shared_cells = 1,
	}
	self.Pairs[key] = pair
	return pair
end

local function unregister_pair(self, entry_a, entry_b)
	if entry_a == entry_b then return end

	local key = get_pair_key(entry_a, entry_b)
	local pair = self.Pairs[key]

	if not pair then return end

	pair.shared_cells = pair.shared_cells - 1

	if pair.shared_cells <= 0 then self.Pairs[key] = nil end
end

local function remove_entry_from_cell(self, entry, key)
	local cell = self.Cells[key]

	if not cell then return end

	for i = 1, #cell.entries do
		local other = cell.entries[i]

		if other ~= entry then unregister_pair(self, entry, other) end
	end

	local index = cell.indices[entry.id]

	if index then
		local last = cell.entries[#cell.entries]
		cell.entries[index] = last
		cell.entries[#cell.entries] = nil
		cell.indices[entry.id] = nil

		if last and last ~= entry then cell.indices[last.id] = index end
	end

	if #cell.entries == 0 then self.Cells[key] = nil end
end

local function add_entry_to_cell(self, entry, key)
	local cell = get_or_create_cell(self, key)

	for i = 1, #cell.entries do
		register_pair(self, entry, cell.entries[i])
	end

	cell.indices[entry.id] = #cell.entries + 1
	cell.entries[#cell.entries + 1] = entry
	entry.cell_keys[#entry.cell_keys + 1] = key
end

local function remove_entry_from_cells(self, entry)
	for i = 1, #entry.cell_keys do
		remove_entry_from_cell(self, entry, entry.cell_keys[i])
	end

	list.clear(entry.cell_keys)
end

local function remove_entry_from_spatial_index(self, entry)
	if entry.is_overflow then
		remove_entry_from_overflow(self, entry)
	else
		remove_entry_from_cells(self, entry)
	end
end

local function add_entry_to_overflow(self, entry)
	remove_entry_from_cells(self, entry)
	entry.is_overflow = true
	entry.overflow_index = #self.OverflowEntries + 1
	self.OverflowEntries[entry.overflow_index] = entry
end

local function assign_entry_cells(self, entry, bounds)
	remove_entry_from_spatial_index(self, entry)
	local min_x, min_y, min_z, max_x, max_y, max_z = get_cell_range(bounds, self.CellSize)
	local cell_count = get_cell_span_count(min_x, min_y, min_z, max_x, max_y, max_z)
	entry.cell_min_x = min_x
	entry.cell_min_y = min_y
	entry.cell_min_z = min_z
	entry.cell_max_x = max_x
	entry.cell_max_y = max_y
	entry.cell_max_z = max_z
	entry.cell_count = cell_count

	if cell_count > self.MaxCellsPerEntry then
		add_entry_to_overflow(self, entry)
		return
	end

	for cell_x = min_x, max_x do
		for cell_y = min_y, max_y do
			for cell_z = min_z, max_z do
				add_entry_to_cell(self, entry, get_cell_key(cell_x, cell_y, cell_z))
			end
		end
	end
end

local function is_same_spatial_assignment(self, entry, bounds)
	if not entry.cell_min_x then return false end

	local min_x, min_y, min_z, max_x, max_y, max_z = get_cell_range(bounds, self.CellSize)
	local cell_count = get_cell_span_count(min_x, min_y, min_z, max_x, max_y, max_z)
	local should_overflow = cell_count > self.MaxCellsPerEntry

	if entry.is_overflow ~= should_overflow then return false end

	if should_overflow then return true end

	return entry.cell_min_x == min_x and
		entry.cell_min_y == min_y and
		entry.cell_min_z == min_z and
		entry.cell_max_x == max_x and
		entry.cell_max_y == max_y and
		entry.cell_max_z == max_z
end

local function create_entry(self, body)
	self.NextEntryId = self.NextEntryId + 1
	local entry = {
		id = self.NextEntryId,
		body = body,
		bounds = AABB(0, 0, 0, 0, 0, 0),
		center = body:GetPosition(),
		cell_keys = {},
		index = #self.Entries + 1,
		last_seen_step = self.StepStamp,
	}
	self.Entries[entry.index] = entry
	self.BodyEntries[body] = entry
	build_entry_bounds(body, entry.bounds)
	assign_entry_cells(self, entry, entry.bounds)
	return entry
end

local function destroy_entry(self, entry)
	remove_entry_from_spatial_index(self, entry)
	self.BodyEntries[entry.body] = nil
	local index = entry.index
	local last = self.Entries[#self.Entries]
	self.Entries[index] = last
	self.Entries[#self.Entries] = nil

	if last and last ~= entry then last.index = index end
end

function broadphase.New(config)
	config = config or {}
	return setmetatable(
		{
			physics = config.physics,
			CellSize = math.max(config.cell_size or DEFAULT_CELL_SIZE, MIN_CELL_SIZE),
			MaxCellsPerEntry = math.max(config.max_cells_per_entry or DEFAULT_MAX_CELLS_PER_ENTRY, 1),
			Entries = {},
			OverflowEntries = {},
			BodyEntries = table.weak("k"),
			Cells = {},
			Pairs = {},
			StepStamp = 0,
			QueryStamp = 0,
			NextEntryId = 0,
		},
		Broadphase
	)
end

function Broadphase:ResetState()
	self.Entries = {}
	self.OverflowEntries = {}
	self.BodyEntries = table.weak("k")
	self.Cells = {}
	self.Pairs = {}
	self.StepStamp = 0
	self.QueryStamp = 0
	self.NextEntryId = 0
	return self
end

-- split out of QueryAABB so the JIT can compile it (the combined loop body
-- aborts with register coalescing too complex and runs interpreted)
local function query_cell_entries(cell, stamp, out, count)
	for i = 1, #cell.entries do
		local entry = cell.entries[i]

		if entry.query_stamp ~= stamp then
			entry.query_stamp = stamp
			count = count + 1
			out[count] = entry
		end
	end

	return count
end

-- packed cell keys are contiguous along z: walk each (x, y) row as a single
-- key range instead of a nested z loop with per-cell key packing
local function query_packed_range(cells, stamp, out, count, min_x, min_y, min_z, max_x, max_y, max_z)
	local z_span = max_z - min_z

	for cell_x = min_x, max_x do
		for cell_y = min_y, max_y do
			local key = get_cell_key(cell_x, cell_y, min_z)
			local key_end = key + z_span

			while key <= key_end do
				local cell = cells[key]

				if cell then count = query_cell_entries(cell, stamp, out, count) end

				key = key + 1
			end
		end
	end

	return count
end

local function query_cell_range(cells, stamp, out, count, min_x, min_y, min_z, max_x, max_y, max_z)
	for cell_x = min_x, max_x do
		for cell_y = min_y, max_y do
			for cell_z = min_z, max_z do
				local cell = cells[get_cell_key(cell_x, cell_y, cell_z)]

				if cell then count = query_cell_entries(cell, stamp, out, count) end
			end
		end
	end

	return count
end

-- spatial query: returns entries whose cells overlap the given aabb, without
-- per-query allocations (dedup via a stamp on the entries)
function Broadphase:QueryAABB(aabb, out)
	out = out or {}
	local cells = self.Cells
	self.QueryStamp = self.QueryStamp + 1
	local stamp = self.QueryStamp
	local min_x, min_y, min_z, max_x, max_y, max_z = get_cell_range(aabb, self.CellSize)
	local count = 0

	if
		min_x >= -CELL_KEY_RANGE and
		min_x < CELL_KEY_RANGE and
		min_y >= -CELL_KEY_RANGE and
		min_y < CELL_KEY_RANGE and
		min_z >= -CELL_KEY_RANGE and
		min_z < CELL_KEY_RANGE and
		max_x >= -CELL_KEY_RANGE and
		max_x < CELL_KEY_RANGE and
		max_y >= -CELL_KEY_RANGE and
		max_y < CELL_KEY_RANGE and
		max_z >= -CELL_KEY_RANGE and
		max_z < CELL_KEY_RANGE
	then
		-- the whole range uses packed keys: rows are contiguous in key space
		count = query_packed_range(cells, stamp, out, count, min_x, min_y, min_z, max_x, max_y, max_z)
	else
		count = query_cell_range(cells, stamp, out, count, min_x, min_y, min_z, max_x, max_y, max_z)
	end

	for i = count + 1, #out do
		out[i] = nil
	end

	return out
end

function Broadphase:GetEntries(out)
	out = out or {}

	for i = 1, #self.Entries do
		out[i] = self.Entries[i]
	end

	for i = #self.Entries + 1, #out do
		out[i] = nil
	end

	return out
end

function Broadphase:TrackBodies(bodies, physics_override)
	local physics = physics_override or self.physics

	if not physics then return self end

	self.StepStamp = self.StepStamp + 1

	for _, body in ipairs(bodies or {}) do
		local entry = self.BodyEntries[body]

		if is_candidate_body(physics, body) then
			-- unchanged pose (static/sleeping bodies): keep the cached bounds
			-- and skip the per-vertex AABB rebuild
			if entry and is_entry_pose_current(entry, body) then
				entry.last_seen_step = self.StepStamp
			else
				if entry then
					-- mutate the entry's own AABB in place; no per-substep allocation
					build_entry_bounds(body, entry.bounds)
					entry.center = body:GetPosition()
					store_entry_pose(entry, body)
					entry.last_seen_step = self.StepStamp

					if not is_same_spatial_assignment(self, entry, entry.bounds) then
						assign_entry_cells(self, entry, entry.bounds)
					end
				else
					local new_entry = create_entry(self, body)
					store_entry_pose(new_entry, body)
				end
			end
		elseif entry then
			destroy_entry(self, entry)
		end
	end

	for i = #self.Entries, 1, -1 do
		local entry = self.Entries[i]

		if entry.last_seen_step ~= self.StepStamp then destroy_entry(self, entry) end
	end

	return self
end

function Broadphase:GetCandidatePairs(out)
	out = out or {}
	local count = 0
	local overflow_entries = self.OverflowEntries
	-- recycled lookup of packed pair keys so the per-substep call allocates
	-- neither the lookup table nor the string keys
	local pair_lookup = self.PairKeyLookup

	if not pair_lookup then
		pair_lookup = {}
		self.PairKeyLookup = pair_lookup
		self.PairKeyScratch = {}
	end

	local used_keys = self.PairKeyScratch

	for _, pair in pairs(self.Pairs) do
		if pair.entry_a.bounds:IsBoxIntersecting(pair.entry_b.bounds) then
			local key = get_pair_key(pair.entry_a, pair.entry_b)
			count = count + 1
			out[count] = pair
			pair_lookup[key] = true
			used_keys[#used_keys + 1] = key
		end
	end

	for i = 1, #overflow_entries do
		local entry = overflow_entries[i]

		for j = 1, #self.Entries do
			local other = self.Entries[j]

			if other ~= entry then
				local key = get_pair_key(entry, other)

				if not pair_lookup[key] and entry.bounds:IsBoxIntersecting(other.bounds) then
					count = count + 1
					out[count] = {
						entry_a = other.id < entry.id and other or entry,
						entry_b = other.id < entry.id and entry or other,
					}
					pair_lookup[key] = true
					used_keys[#used_keys + 1] = key
				end
			end
		end
	end

	for i = #used_keys, 1, -1 do
		pair_lookup[used_keys[i]] = nil
		used_keys[i] = nil
	end

	for i = count + 1, #out do
		out[i] = nil
	end

	return out
end

function Broadphase:BuildCandidatePairs(bodies, out, physics_override)
	self:TrackBodies(bodies, physics_override)
	return self:GetCandidatePairs(out)
end

return broadphase
