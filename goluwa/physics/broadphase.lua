local broadphase = {}
local Broadphase = {}
Broadphase.__index = Broadphase
local DEFAULT_CELL_SIZE = 2
local MIN_CELL_SIZE = 0.5
local DEFAULT_MAX_CELLS_PER_ENTRY = 64

local function new_weak_key_table()
	return setmetatable({}, {__mode = "k"})
end

local function merge_swept_bounds(bounds, previous_bounds)
	bounds.min_x = math.min(bounds.min_x, previous_bounds.min_x)
	bounds.min_y = math.min(bounds.min_y, previous_bounds.min_y)
	bounds.min_z = math.min(bounds.min_z, previous_bounds.min_z)
	bounds.max_x = math.max(bounds.max_x, previous_bounds.max_x)
	bounds.max_y = math.max(bounds.max_y, previous_bounds.max_y)
	bounds.max_z = math.max(bounds.max_z, previous_bounds.max_z)
	return bounds
end

local function is_candidate_body(physics, body)
	return body and body.CollisionEnabled
end

local function build_entry_bounds(body)
	local bounds = body:GetBroadphaseAABB()
	local previous_bounds = body:GetBroadphaseAABB(body:GetPreviousPosition(), body:GetPreviousRotation())
	return merge_swept_bounds(bounds, previous_bounds)
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

local function get_cell_key(x, y, z)
	return x .. ":" .. y .. ":" .. z
end

local function get_cell_span_count(min_x, min_y, min_z, max_x, max_y, max_z)
	return (max_x - min_x + 1) * (max_y - min_y + 1) * (max_z - min_z + 1)
end

local function get_entry_extent(bounds)
	return math.max(
		bounds.max_x - bounds.min_x,
		bounds.max_y - bounds.min_y,
		bounds.max_z - bounds.min_z
	)
end

local function estimate_cell_size(entries)
	local extent_sum = 0
	local counted = 0

	for i = 1, #entries do
		local extent = get_entry_extent(entries[i].bounds)

		if extent > 0 then
			extent_sum = extent_sum + extent
			counted = counted + 1
		end
	end

	if counted == 0 then return DEFAULT_CELL_SIZE end

	return math.max(MIN_CELL_SIZE, extent_sum / counted)
end

local function get_pair_key(entry_a, entry_b)
	if entry_a.id < entry_b.id then return entry_a.id .. ":" .. entry_b.id end

	return entry_b.id .. ":" .. entry_a.id
end

local function clear_array(list)
	for i = #list, 1, -1 do
		list[i] = nil
	end
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

	clear_array(entry.cell_keys)
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

local function create_entry(self, body, bounds)
	self.NextEntryId = self.NextEntryId + 1
	local entry = {
		id = self.NextEntryId,
		body = body,
		bounds = bounds,
		center = body:GetPosition(),
		cell_keys = {},
		index = #self.Entries + 1,
		last_seen_step = self.StepStamp,
	}
	self.Entries[entry.index] = entry
	self.BodyEntries[body] = entry
	assign_entry_cells(self, entry, bounds)
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
			BodyEntries = new_weak_key_table(),
			Cells = {},
			Pairs = {},
			StepStamp = 0,
			NextEntryId = 0,
		},
		Broadphase
	)
end

function Broadphase:ResetState()
	self.Entries = {}
	self.OverflowEntries = {}
	self.BodyEntries = new_weak_key_table()
	self.Cells = {}
	self.Pairs = {}
	self.StepStamp = 0
	self.NextEntryId = 0
	return self
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
			local bounds = build_entry_bounds(body)

			if entry then
				entry.body = body
				entry.bounds = bounds
				entry.center = body:GetPosition()
				entry.last_seen_step = self.StepStamp

				if not is_same_spatial_assignment(self, entry, bounds) then
					assign_entry_cells(self, entry, bounds)
				end
			else
				create_entry(self, body, bounds)
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
	local pair_lookup = {}

	for _, pair in pairs(self.Pairs) do
		if pair.entry_a.bounds:IsBoxIntersecting(pair.entry_b.bounds) then
			count = count + 1
			out[count] = pair
			pair_lookup[get_pair_key(pair.entry_a, pair.entry_b)] = true
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

					if other.id < entry.id then
						out[count] = {
							entry_a = other,
							entry_b = entry,
						}
					else
						out[count] = {
							entry_a = entry,
							entry_b = other,
						}
					end

					pair_lookup[key] = true
				end
			end
		end
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

local function append_pair(pairs, pair_lookup, entry_a, entry_b)
	if entry_a == entry_b then return end

	if not entry_a.bounds:IsBoxIntersecting(entry_b.bounds) then return end

	local key = get_pair_key(entry_a, entry_b)

	if pair_lookup[key] then return end

	pair_lookup[key] = true

	if entry_b.id < entry_a.id then entry_a, entry_b = entry_b, entry_a end

	pairs[#pairs + 1] = {
		entry_a = entry_a,
		entry_b = entry_b,
	}
end

function broadphase.BuildEntries(physics, bodies)
	local entries = {}

	for _, body in ipairs(bodies or {}) do
		if is_candidate_body(physics, body) then
			entries[#entries + 1] = {
				id = #entries + 1,
				body = body,
				bounds = build_entry_bounds(body),
				center = body:GetPosition(),
			}
		end
	end

	return entries
end

function broadphase.BuildCandidatePairsFromEntries(entries, options)
	local pairs = {}
	local pair_lookup = {}
	local cells = {}
	local overflow_entries = {}
	options = options or {}
	local cell_size = math.max(options.cell_size or estimate_cell_size(entries), MIN_CELL_SIZE)
	local max_cells_per_entry = math.max(options.max_cells_per_entry or DEFAULT_MAX_CELLS_PER_ENTRY, 1)

	for i = 1, #entries do
		local entry = entries[i]
		local min_x, min_y, min_z, max_x, max_y, max_z = get_cell_range(entry.bounds, cell_size)
		local cell_count = get_cell_span_count(min_x, min_y, min_z, max_x, max_y, max_z)

		if cell_count > max_cells_per_entry then
			overflow_entries[#overflow_entries + 1] = entry
		else
			for cell_x = min_x, max_x do
				for cell_y = min_y, max_y do
					for cell_z = min_z, max_z do
						local key = get_cell_key(cell_x, cell_y, cell_z)
						local occupants = cells[key]

						if not occupants then
							occupants = {}
							cells[key] = occupants
						end

						for occupant_index = 1, #occupants do
							append_pair(pairs, pair_lookup, entry, occupants[occupant_index])
						end

						occupants[#occupants + 1] = entry
					end
				end
			end
		end
	end

	for i = 1, #overflow_entries do
		local entry = overflow_entries[i]

		for j = 1, #entries do
			append_pair(pairs, pair_lookup, entry, entries[j])
		end
	end

	return pairs
end

function broadphase.BuildCandidatePairs(physics, bodies, options)
	local entries = broadphase.BuildEntries(physics, bodies)
	return broadphase.BuildCandidatePairsFromEntries(entries, options)
end

return broadphase
