local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local stats = import("goluwa/physics/stats.lua")
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
local look_ahead_position = Vec3()
local entry_aabb_scratch_ahead = AABB(0, 0, 0, 0, 0, 0)
local CANDIDATE_PAD = 0.04

local function build_entry_bounds(body, out, look_ahead)
	local bounds = body:GetBroadphaseAABB(nil, nil, entry_aabb_scratch_current)
	local previous_bounds = body:GetBroadphaseAABB(
		body:GetPreviousPosition(),
		body:GetPreviousRotation(),
		entry_aabb_scratch_previous
	)

	if not out then out = AABB(0, 0, 0, 0, 0, 0) end

	AABB.Union(out, previous_bounds, bounds)

	if look_ahead > 0 then
		look_ahead_position.x = body.Position.x + body.Velocity.x * look_ahead
		look_ahead_position.y = body.Position.y + body.Velocity.y * look_ahead
		look_ahead_position.z = body.Position.z + body.Velocity.z * look_ahead
		AABB.Union(
			out,
			out,
			body:GetBroadphaseAABB(look_ahead_position, nil, entry_aabb_scratch_ahead)
		)
	end

	out.min_x = out.min_x - CANDIDATE_PAD
	out.min_y = out.min_y - CANDIDATE_PAD
	out.min_z = out.min_z - CANDIDATE_PAD
	out.max_x = out.max_x + CANDIDATE_PAD
	out.max_y = out.max_y + CANDIDATE_PAD
	out.max_z = out.max_z + CANDIDATE_PAD
	return out
end

local function store_entry_pose(entry, body)
	local p = body.Position
	local r = body.Rotation
	local pp = body.PreviousPosition
	local pr = body.PreviousRotation
	entry.px, entry.py, entry.pz = p.x, p.y, p.z
	entry.rx, entry.ry, entry.rz, entry.rw = r.x, r.y, r.z, r.w
	entry.ppx, entry.ppy, entry.ppz = pp.x, pp.y, pp.z
	entry.prx, entry.pry, entry.prz, entry.prw = pr.x, pr.y, pr.z, pr.w
end

local function is_entry_pose_current(entry, body)
	local p = body.Position
	local r = body.Rotation
	local pp = body.PreviousPosition
	local pr = body.PreviousRotation
	return entry.px == p.x and
		entry.py == p.y and
		entry.pz == p.z and
		entry.rx == r.x and
		entry.ry == r.y and
		entry.rz == r.z and
		entry.rw == r.w and
		entry.ppx == pp.x and
		entry.ppy == pp.y and
		entry.ppz == pp.z and
		entry.prx == pr.x and
		entry.pry == pr.y and
		entry.prz == pr.z and
		entry.prw == pr.w
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
	entry.overflow_hits = nil
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
		cell_keys = {},
		index = #self.Entries + 1,
		last_seen_step = self.StepStamp,
		overflow_dirty = true,
	}
	self.Entries[entry.index] = entry
	self.BodyEntries[body] = entry
	build_entry_bounds(body, entry.bounds, self.LookAhead)
	assign_entry_cells(self, entry, entry.bounds)
	return entry
end

local function destroy_entry(self, entry)
	remove_entry_from_spatial_index(self, entry)
	entry.overflow_hits = nil
	self.TopologyChanged = true

	for i = 1, #self.OverflowEntries do
		local hits = self.OverflowEntries[i].overflow_hits

		if hits then hits[entry.id] = nil end
	end

	self.BodyEntries[entry.body] = nil
	stats:Count("broadphase_entries_removed")
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
			ChangedEntries = {},
			ChangedConsumed = true,
			StepStamp = 0,
			LookAhead = 0,
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
	self.ChangedEntries = {}
	self.ChangedConsumed = true
	self.TopologyChanged = false
	self.LastPairs = nil
	self.StepStamp = 0
	self.LookAhead = 0
	self.QueryStamp = 0
	self.NextEntryId = 0
	return self
end

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
	local changed = self.ChangedEntries

	if self.ChangedConsumed then
		list.clear(changed)
		self.ChangedConsumed = false
	end

	for _, body in ipairs(bodies or {}) do
		local entry = self.BodyEntries[body]

		if
			entry and
			body.SyncSettled and
			not body.PoseDirty and
			(
				body.MotionType == "static" or
				not body.Awake
			)
			and
			body.CollisionEnabled
		then
			entry.last_seen_step = self.StepStamp
		elseif is_candidate_body(physics, body) then
			body.PoseDirty = false

			if entry and is_entry_pose_current(entry, body) then
				entry.last_seen_step = self.StepStamp
			else
				if entry then
					build_entry_bounds(body, entry.bounds, self.LookAhead)
					store_entry_pose(entry, body)
					entry.last_seen_step = self.StepStamp
					entry.overflow_dirty = true
					changed[#changed + 1] = entry
					stats:Count("broadphase_bounds_updates")

					if not is_same_spatial_assignment(self, entry, entry.bounds) then
						assign_entry_cells(self, entry, entry.bounds)
						stats:Count("broadphase_invalidations")
					end
				else
					local new_entry = create_entry(self, body)
					store_entry_pose(new_entry, body)
					changed[#changed + 1] = new_entry
					stats:Count("broadphase_entries_added")
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

	if #self.ChangedEntries == 0 and not self.TopologyChanged and self.LastPairs == out then
		self.ChangedConsumed = true
		return out
	end

	self.TopologyChanged = false
	self.LastPairs = out
	local count = 0
	local overflow_entries = self.OverflowEntries
	local pair_lookup = self.PairKeyLookup

	if not pair_lookup then
		pair_lookup = {}
		self.PairKeyLookup = pair_lookup
		self.PairKeyScratch = {}
	end

	local used_keys = self.PairKeyScratch

	for _, pair in pairs(self.Pairs) do
		if pair.entry_a.bounds:IsBoxIntersecting(pair.entry_b.bounds) then
			count = count + 1
			out[count] = pair
		end
	end

	local entries = self.Entries
	local changed = self.ChangedEntries

	for i = 1, #overflow_entries do
		local entry = overflow_entries[i]
		local hits = entry.overflow_hits

		if not hits then
			hits = {}
			entry.overflow_hits = hits
			entry.overflow_dirty = true
		end

		local bounds = entry.bounds

		if entry.overflow_dirty then
			entry.overflow_dirty = false
			table.clear(hits)

			for j = 1, #entries do
				local other = entries[j]

				if other ~= entry and bounds:IsBoxIntersecting(other.bounds) then
					hits[other.id] = {
						entry_a = other.id < entry.id and other or entry,
						entry_b = other.id < entry.id and entry or other,
					}
				end
			end
		else
			for j = 1, #changed do
				local other = changed[j]

				if other ~= entry then
					if bounds:IsBoxIntersecting(other.bounds) then
						if not hits[other.id] then
							hits[other.id] = {
								entry_a = other.id < entry.id and other or entry,
								entry_b = other.id < entry.id and entry or other,
							}
						end
					else
						hits[other.id] = nil
					end
				end
			end
		end

		for _, pair in pairs(hits) do
			local key = get_pair_key(pair.entry_a, pair.entry_b)

			if not pair_lookup[key] then
				count = count + 1
				out[count] = pair
				pair_lookup[key] = true
				used_keys[#used_keys + 1] = key
			end
		end
	end

	self.ChangedConsumed = true

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
	stats:Gauge("broadphase_overflow", #self.OverflowEntries)
	return self:GetCandidatePairs(out)
end

return broadphase
