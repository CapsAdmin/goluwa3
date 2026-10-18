local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local ViewPriority = import("goluwa/render3d/view_priority.lua")
local terrain_shadow = import("goluwa/render3d/terrain_shadow.lua")
local tiles = import("goluwa/terrain/tiles.lua")
local TerrainPhysics = import("goluwa/terrain/physics.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local Terrain = {}
Terrain.__index = Terrain

-- scatter needs a render device when it is loaded, and a terrain can be built without one (the tests): a tile only has a
-- scatter entry when its material has a scatter set, which needs one
local function get_scatter()
	return import("goluwa/render3d/scatter.lua")
end

local function build_chunk_key(request)
	return string.format(
		"%d:%d:%d:%s:%s:%s:%s",
		request.min_x,
		request.min_z,
		request.size,
		tostring(request.samples),
		tostring(request.detail_size),
		tostring(request.splat_size),
		tostring(request.color_size)
	)
end

function Terrain.New(config)
	local self = setmetatable({}, Terrain)
	self.Name = config.Name or "terrain"
	self.Source = config.Source
	self.Levels = config.Levels or 7
	self.BaseChunkSize = config.BaseChunkSize or 64
	-- the chunks per side of a level. the next finer level fills the middle half, so the ring around it is GridSize / 4
	-- chunks thick, and it has to be at least 2 or the finer level can poke out of it when the two snap differently
	self.GridSize = config.GridSize or 8
	self.Samples = config.Samples or 65
	self.DetailSize = config.DetailSize or 256
	self.SplatSize = config.SplatSize or 128
	self.ColorSize = config.ColorSize
	self.ShadowLevels = config.ShadowLevels or self.Levels
	-- the finest levels that are in the scene bvh (gi, reflections, soup shadows). a tile costs a cpu sah build of its
	-- triangles, which is the most expensive thing about a tile
	self.BVHLevels = config.BVHLevels or self.Levels
	-- a tile enters the bvh once it has been wanted for this many seconds: flying fast makes tiles that are gone before
	-- their bvh is built, and building it is the most expensive thing about a tile
	self.BVHDelay = config.BVHDelay or 1.5
	-- and at most this many enter it in a frame, the nearest first: a tile takes about 10 ms of cpu to build, a jump makes hundreds that
	-- are due at the same moment, and the scene bvh builds all of them in one frame when it sees that many changes
	self.BVHPerFrame = config.BVHPerFrame or 1
	-- the scene bvh uses every stride:th sample of the tile, the finest level a smaller stride
	self.BVHStride = config.BVHStride or 4
	self.BVHNearStride = config.BVHNearStride or 2
	self.BVHDue = {}
	-- the terrain's shadow on everything past the shadow maps comes from a height field of this many meters around the
	-- camera (see terrain_shadow.lua), baked at ShadowSamples squared samples and baked again when the camera is more
	-- than ShadowRecenter of the extent from its center. nil is off
	self.ShadowExtent = config.ShadowExtent
	self.ShadowSamples = config.ShadowSamples or 1024
	self.ShadowRecenter = config.ShadowRecenter or 0.2
	-- the frames a tile that is replaced waits for the vegetation of its replacements to be baked, so that it does not go
	-- before there is anything to replace its vegetation with
	self.ScatterWaitFrames = config.ScatterWaitFrames or 120
	self.ViewPriority = ViewPriority.New{PredictSeconds = config.PredictSeconds, OutsidePenalty = config.OutsidePenalty}
	self.BuildsPerFrame = config.BuildsPerFrame or 2
	-- while the terrain holds the scene load nothing is flying yet, so the first tiles are built in bulk
	self.LoadBuildsPerFrame = config.LoadBuildsPerFrame or 16
	self.ScatterSet = config.ScatterSet
	-- the frames a chunk's textures live on after its tile is removed: the culling and the frames in flight can still draw
	-- the tile, and a texture that is released is an error texture or another chunk's texture in the bindless array
	self.ReleaseFrames = config.ReleaseFrames or 12
	self.PendingReleases = {}
	self.ReleaseHead = 1
	self.ReleaseTail = 0
	self.ReleasesPerFrame = config.ReleasesPerFrame or 8
	self.PriorityScratch = {}
	self.RetiringList = {}
	self.HiddenScratch = {}
	self.CoveredScratch = {}
	self.FirstChunkX = {}
	self.FirstChunkZ = {}
	self.ChunkSizes = {}

	for level = 0, self.Levels - 1 do
		self.ChunkSizes[level] = self.BaseChunkSize * 2 ^ level
	end

	self.Stats = {requested = 0, built = 0, wasted = 0, latency = 0, max_latency = 0}
	self.UpdateInterval = config.UpdateInterval or 0.05
	self.PhysicsConfig = config.Physics
	self.Chunks = {}
	self.Tiles = {}
	self.Desired = {}
	self.BuildQueue = {}
	self.QueuedTiles = {}
	self.Root = nil
	self.Physics = nil
	self.time_until_update = 0
	self.UpdateId = self.Name .. "_update"
	return self
end

function Terrain:AcquireChunk(request, callback, priority)
	local key = build_chunk_key(request)
	local entry = self.Chunks[key]

	if not entry then
		entry = {
			key = key,
			request = request,
			refs = 0,
			waiters = {},
			chunk = nil,
			queued = false,
		}
		self.Chunks[key] = entry
	end

	entry.refs = entry.refs + 1

	if entry.chunk then
		callback(entry.chunk)
		return key
	end

	entry.waiters[#entry.waiters + 1] = callback

	if not entry.queued then
		entry.queued = true
		entry.priority = priority or 0
		self.BuildQueue[#self.BuildQueue + 1] = entry
	elseif priority and priority < (entry.priority or 0) then
		entry.priority = priority
	end

	return key
end

function Terrain:SetChunkPriority(key, priority)
	local entry = self.Chunks[key]

	if entry and entry.queued then entry.priority = priority end
end

function Terrain:ReleaseChunk(key)
	local entry = self.Chunks[key]

	if not entry then return end

	entry.refs = entry.refs - 1

	if entry.refs > 0 then return end

	self.Chunks[key] = nil

	if entry.chunk then
		self.ReleaseTail = self.ReleaseTail + 1
		self.PendingReleases[self.ReleaseTail] = {frame = self:GetFrame(), chunk = entry.chunk}
	else
		entry.cancelled = true
	end
end

function Terrain:ProcessBuildQueue()
	local queue = self.BuildQueue
	local count = 0

	-- entries of chunks that were released while they waited are dropped here
	for i = 1, #queue do
		local entry = queue[i]

		if entry.cancelled then
			entry.queued = false
		else
			count = count + 1
			queue[count] = entry
		end
	end

	for i = #queue, count + 1, -1 do
		queue[i] = nil
	end

	local built = 0
	local builds_per_frame = self.holding_scene_load and self.LoadBuildsPerFrame or self.BuildsPerFrame

	while built < builds_per_frame and count > 0 do
		local best = 1

		for i = 2, count do
			if queue[i].priority < queue[best].priority then best = i end
		end

		local entry = queue[best]
		queue[best] = queue[count]
		queue[count] = nil
		count = count - 1
		entry.queued = false

		do
			built = built + 1
			entry.loading = true
			entry.requested_at = system.GetElapsedTime()
			self.Stats.requested = self.Stats.requested + 1

			self.Source:RequestChunk(entry.request, function(chunk)
				local stats = self.Stats
				local latency = system.GetElapsedTime() - entry.requested_at
				entry.loading = false

				if entry.cancelled then
					stats.wasted = stats.wasted + 1
					self.Source:ReleaseChunk(chunk)
					return
				end

				stats.built = stats.built + 1
				stats.latency = stats.latency == 0 and latency or stats.latency * 0.9 + latency * 0.1
				stats.max_latency = math.max(stats.max_latency, latency)

				entry.chunk = chunk
				local waiters = entry.waiters
				entry.waiters = {}

				for i = 1, #waiters do
					waiters[i](chunk)
				end
			end)
		end
	end

	self.Source:Submit()
end

function Terrain:GetLevelChunkSize(level)
	return self.ChunkSizes[level]
end

function Terrain:GetLevelOrigin(level, position)
	local chunk_size = self:GetLevelChunkSize(level)
	local snap = chunk_size * 2
	local offset = (self.GridSize / 2 - 1) * chunk_size
	return math.floor((position.x - offset) / snap) * snap, math.floor((position.z - offset) / snap) * snap
end

function Terrain:GetLevelSkirtDepth(level)
	local spacing = self:GetLevelChunkSize(level) / (self.Samples - 1)
	return spacing * 1.5 + 2
end

function Terrain:BuildTileRequest(level, chunk_x, chunk_z)
	local chunk_size = self:GetLevelChunkSize(level)
	local detail_divisor = 2 ^ math.max(level - 2, 0)
	return {
		min_x = chunk_x * chunk_size,
		min_z = chunk_z * chunk_size,
		size = chunk_size,
		samples = self.Samples,
		detail_size = math.max(math.floor(self.DetailSize / detail_divisor), 32),
		splat_size = math.max(math.floor(self.SplatSize / detail_divisor), 16),
		color_size = self.ColorSize and
			math.max(math.floor(self.ColorSize / detail_divisor), 16) or
			nil,
	}
end

function Terrain:GatherDesiredTiles(position)
	local desired = {}
	local previous_min_x, previous_min_z, previous_max_x, previous_max_z

	for level = 0, self.Levels - 1 do
		local chunk_size = self:GetLevelChunkSize(level)
		local origin_x, origin_z = self:GetLevelOrigin(level, position)
		local first_x = origin_x / chunk_size
		local first_z = origin_z / chunk_size
		self.FirstChunkX[level] = first_x
		self.FirstChunkZ[level] = first_z

		local grid = self.GridSize
		local center = (grid - 1) / 2

		for dz = 0, grid - 1 do
			for dx = 0, grid - 1 do
				local chunk_x = first_x + dx
				local chunk_z = first_z + dz
				local min_x = chunk_x * chunk_size
				local min_z = chunk_z * chunk_size
				local inside_hole = previous_min_x and
					min_x >= previous_min_x and
					min_x + chunk_size <= previous_max_x and
					min_z >= previous_min_z and
					min_z + chunk_size <= previous_max_z

				if not inside_hole then
					local key = level .. ":" .. chunk_x .. ":" .. chunk_z
					desired[key] = {
						key = key,
						level = level,
						chunk_x = chunk_x,
						chunk_z = chunk_z,
						min_x = min_x,
						min_z = min_z,
						max_x = min_x + chunk_size,
						max_z = min_z + chunk_size,
						priority = level * 16 + math.abs(dx - center) + math.abs(dz - center),
					}
				end
			end
		end

		previous_min_x = origin_x
		previous_min_z = origin_z
		previous_max_x = origin_x + chunk_size * grid
		previous_max_z = origin_z + chunk_size * grid
	end

	return desired
end

function Terrain:CreateTile(want, chunk)
	local level = want.level
	local chunk_size = self:GetLevelChunkSize(level)
	local entity = Entity.New{
		Name = string.format("%s_tile_%d_%d_%d", self.Name, level, want.chunk_x, want.chunk_z),
		Parent = self.Root,
	}
	local transform = entity:AddComponent("transform")
	transform:SetPosition(Vec3(want.chunk_x * chunk_size, 0, want.chunk_z * chunk_size))
	local visual = entity:AddComponent("visual")
	visual:SetCastShadows(level < self.ShadowLevels)
	visual:SetInSceneBVH(false)
	visual:SetUseOcclusionCulling(false)
	visual:SetCullDistance(1e8)
	local primitive_entity = Entity.New{
		Name = entity:GetName() .. "_primitive",
		Parent = entity,
	}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	local polygon = tiles.BuildPolygon(chunk, self:GetLevelSkirtDepth(level), 1)
	primitive:SetPolygon3D(polygon)
	primitive:SetMaterial(tiles.CreateMaterial(chunk, chunk.layers or self.Source:GetLayers(), self.ScatterSet, self.Source))
	visual:BuildAABB()
	return {
		key = want.key,
		level = level,
		entity = entity,
		polygon = polygon,
		material = primitive:GetMaterial(),
	}
end

-- the scene bvh is built from a coarser, rays only copy of the tile: a bvh of the 8448 triangles of the tile costs
-- about 10 ms of cpu, a few hundred triangles are not worth the nearest few meters of detail to rays
function Terrain:CreateBVHEntity(tile)
	local entity = Entity.New{
		Name = tile.entity:GetName() .. "_bvh",
		Parent = self.Root,
	}
	entity:AddComponent("transform"):SetPosition(tile.entity.transform:GetPosition())
	local visual = entity:AddComponent("visual")
	visual:SetRaysOnly(true)
	visual:SetCastShadows(false)
	visual:SetReceivesDecals(false)
	visual:SetUseOcclusionCulling(false)
	visual:SetCullDistance(1e8)
	visual:SetVisible(not tile.hidden)
	local primitive_entity = Entity.New{Name = entity:GetName() .. "_primitive", Parent = entity}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	primitive:SetPolygon3D(
		tiles.BuildPolygon(
			tile.chunk,
			self:GetLevelSkirtDepth(tile.level),
			tile.level == 0 and self.BVHNearStride or self.BVHStride,
			"host"
		)
	)
	primitive:SetMaterial(tile.material)
	visual:BuildAABB()
	tile.bvh_entity = entity
end

function Terrain:RemoveTile(tile)
	tile.removed = true

	if tile.entity and tile.entity:IsValid() then tile.entity:Remove() end

	if tile.bvh_entity then
		tile.bvh_entity:Remove()
		tile.bvh_entity = nil
	end

	if tile.chunk_key then self:ReleaseChunk(tile.chunk_key) end
end

local function tiles_overlap(a, b)
	return a.min_x < b.max_x and b.min_x < a.max_x and a.min_z < b.max_z and b.min_z < a.max_z
end

local function set_tile_hidden(self, tile, hidden)
	tile.hidden = hidden

	if not hidden then tile.shown = self:GetFrame() end

	if tile.bvh_entity then tile.bvh_entity.visual:SetVisible(not hidden) end

	if not tile.entity or not tile.entity.visual then return end

	tile.entity.visual:SetVisible(not hidden)
	tile.entity.visual:SetCastShadows(not hidden and tile.level < self.ShadowLevels)
end

-- the desired tiles that overlap a retiring tile are worked out when the desired tiles change (UpdateTiles)
function Terrain:IsTileReplaced(tile)
	local keys = tile.replacement_keys

	for i = 1, #keys do
		local current = self.Tiles[keys[i]]

		if not current or not current.entity then return false end
	end

	-- everything that replaces it is built, now the vegetation: the replacements are hidden until it is, and they are
	-- looked at by scatter anyway (scatter.Preload), so it bakes while the old tile and its vegetation are still there
	local frame = self:GetFrame()
	tile.scatter_wait = tile.scatter_wait or frame

	if frame - tile.scatter_wait < self.ScatterWaitFrames then
		for i = 1, #keys do
			local entry = self.Tiles[keys[i]].scatter_entry

			if entry and not get_scatter().IsSurfaceReady(entry) then return false end
		end
	end

	return true
end

function Terrain:GetFrame()
	return system.GetFrameNumber()
end

-- a tile is drawn once the culling that is drawn was dispatched after the tile was shown
function Terrain:IsTileDrawn(tile)
	if not tile.entity or tile.hidden or not tile.shown then return false end

	return not gpu_culling.IsEnabled() or gpu_culling.GetDrawnCullFrame() >= tile.shown
end

function Terrain:AreReplacementsDrawn(tile)
	local keys = tile.replacement_keys

	for i = 1, #keys do
		if not self:IsTileDrawn(self.Tiles[keys[i]]) then return false end
	end

	return true
end

-- the oldest first, a few per frame: a teleport releases hundreds of chunks at once and freeing their textures is slow
function Terrain:ProcessPendingReleases()
	local pending = self.PendingReleases
	local frame = self:GetFrame()
	local released = 0

	while released < self.ReleasesPerFrame and pending[self.ReleaseHead] do
		local release = pending[self.ReleaseHead]

		if frame - release.frame < self.ReleaseFrames then break end

		self.Source:ReleaseChunk(release.chunk)
		pending[self.ReleaseHead] = nil
		self.ReleaseHead = self.ReleaseHead + 1
		released = released + 1
	end
end

-- a tile is blocked while a retiring tile that overlaps it is not yet replaced. the retiring tiles are those of the last
-- UpdateTiles, a tile that is built later looks at them once (FindBlockers) and its list is refreshed every update
function Terrain:FindBlockers(tile)
	local blockers = tile.blockers or {}
	local retiring = self.RetiringList
	table.clear(blockers)

	for i = 1, #retiring do
		local other = retiring[i]

		if other ~= tile and tiles_overlap(tile, other) then blockers[#blockers + 1] = other end
	end

	tile.blockers = blockers
end

function Terrain:IsTileBlocked(tile)
	local blockers = tile.blockers

	for i = 1, #blockers do
		local other = blockers[i]

		if other.retiring and not other.removed and not other.replaced_frame then return true end
	end

	return false
end

function Terrain:RetireTiles()
	local frame = self:GetFrame()

	for key, tile in pairs(self.Tiles) do
		if tile.retiring then
			if not tile.entity then
				self:RemoveTile(tile)
				self.Tiles[key] = nil
			elseif self:IsTileReplaced(tile) then
				-- what replaces it can be shown now (it is no longer blocked by it), it goes when they are drawn
				tile.replaced_frame = tile.replaced_frame or frame

				if self:AreReplacementsDrawn(tile) then
					self:RemoveTile(tile)
					self.Tiles[key] = nil
				end
			else
				tile.replaced_frame = nil
			end
		end
	end

	local now = system.GetElapsedTime()
	local due = self.BVHDue

	for _, tile in pairs(self.Tiles) do
		if tile.hidden and not tile.retiring and not self:IsTileBlocked(tile) then
			set_tile_hidden(self, tile, false)
		end

		if tile.bvh_time and not tile.retiring and now >= tile.bvh_time then due[#due + 1] = tile end
	end

	local min_height, max_height = self.Source.MinHeight, self.Source.MaxHeight

	for _ = 1, math.min(self.holding_scene_load and #due or self.BVHPerFrame, #due) do
		local best, best_rank, best_index = nil, math.huge

		for i = 1, #due do
			local rank = self.ViewPriority:Rank(due[i].min_x, min_height, due[i].min_z, due[i].max_x, max_height, due[i].max_z)

			if rank < best_rank then best, best_rank, best_index = due[i], rank, i end
		end

		best.bvh_time = nil
		self:CreateBVHEntity(best)
		due[best_index] = due[#due]
		due[#due] = nil
	end

	table.clear(due)
end

-- the keys of the desired tiles that overlap a tile, by looking at the part of every level's grid that it covers
function Terrain:GatherOverlappingDesired(tile, keys)
	local desired = self.Desired
	local last = self.GridSize - 1
	table.clear(keys)

	for level = 0, self.Levels - 1 do
		local size = self.ChunkSizes[level]
		local first_x = self.FirstChunkX[level]
		local first_z = self.FirstChunkZ[level]
		local x0 = math.max(math.floor(tile.min_x / size), first_x)
		local x1 = math.min(math.ceil(tile.max_x / size) - 1, first_x + last)
		local z0 = math.max(math.floor(tile.min_z / size), first_z)
		local z1 = math.min(math.ceil(tile.max_z / size) - 1, first_z + last)

		for chunk_z = z0, z1 do
			for chunk_x = x0, x1 do
				local key = level .. ":" .. chunk_x .. ":" .. chunk_z

				if desired[key] then keys[#keys + 1] = key end
			end
		end
	end
end

-- forward is the camera's forward and half_angle the horizontal half of what it sees (plus a margin), in radians
function Terrain:UpdateTiles(position, forward, half_angle)
	local desired = self:GatherDesiredTiles(position)
	self.Desired = desired

	for key, tile in pairs(self.Tiles) do
		local retiring = not desired[key]

		if tile.scatter_entry and tile.retiring ~= retiring then
			get_scatter().SetRetiring(tile.entity.visual, retiring)
		end

		tile.retiring = retiring

		if not tile.retiring then
			tile.replaced_frame = nil
			tile.scatter_wait = nil
		end
	end

	for key, want in pairs(desired) do
		if not self.Tiles[key] then
			local tile = {
				key = key,
				level = want.level,
				chunk_x = want.chunk_x,
				chunk_z = want.chunk_z,
				min_x = want.min_x,
				min_z = want.min_z,
				max_x = want.max_x,
				max_z = want.max_z,
				replacement_keys = {},
			}
			self.Tiles[key] = tile
			tile.chunk_key = self:AcquireChunk(
				self:BuildTileRequest(want.level, want.chunk_x, want.chunk_z),
				function(chunk)
					if self.Tiles[key] ~= tile or not self.Root or not self.Root:IsValid() then
						return
					end

					local built = self:CreateTile(want, chunk)
					tile.entity = built.entity
					tile.polygon = built.polygon
					tile.chunk = chunk
					tile.material = built.material

					-- while the scene loads nothing flies, the tile is wanted for good and the first bvh build takes it along
					if tile.level < self.BVHLevels then
						tile.bvh_time = system.GetElapsedTime() + (self.holding_scene_load and 0 or self.BVHDelay)
					end

					if tile.material:GetScatterSet() then
						tile.scatter_entry = tile.entity.visual:GetRenderEntries()[1]
					end

					self:FindBlockers(tile)

					if self:IsTileBlocked(tile) then
						if tile.scatter_entry then get_scatter().Preload(tile.entity.visual) end

						set_tile_hidden(self, tile, true)
					else
						tile.shown = self:GetFrame()
					end
				end,
				want.priority
			)
		end
	end

	local retiring_list = self.RetiringList
	local hidden_list = self.HiddenScratch
	local covered = self.CoveredScratch
	table.clear(retiring_list)
	table.clear(hidden_list)
	table.clear(covered)

	for _, tile in pairs(self.Tiles) do
		if tile.entity then
			if tile.retiring then retiring_list[#retiring_list + 1] = tile end

			if tile.hidden then
				hidden_list[#hidden_list + 1] = tile
				table.clear(tile.blockers)
			end
		end
	end

	-- what a retiring tile waits for, and what blocks a hidden tile, only changes with the desired tiles
	for i = 1, #retiring_list do
		local tile = retiring_list[i]
		local keys = tile.replacement_keys
		self:GatherOverlappingDesired(tile, keys)

		for j = 1, #keys do
			local key = keys[j]
			local other = self.Tiles[key]
			covered[key] = true

			if other.hidden then other.blockers[#other.blockers + 1] = tile end
		end
	end

	local priorities = self.PriorityScratch
	-- a lower priority is built first, and the queue is as old as the position it was filled at, so it is worked out
	-- again every update. what has nothing drawn under it comes before what only makes a drawn tile finer, and inside
	-- that nearest first, from the nearer of where the camera is and where it will be in PredictSeconds, with what is
	-- out of view (looking mostly down is everything) counting as up to 5 times as far
	local view_priority = self.ViewPriority
	view_priority:Update(position, forward, half_angle)
	local min_height, max_height = self.Source.MinHeight, self.Source.MaxHeight

	for key, want in pairs(desired) do
		local tile = self.Tiles[key]

		if not tile.entity then
			local priority = view_priority:Rank(want.min_x, min_height, want.min_z, want.max_x, max_height, want.max_z)

			local under = covered[key]

			for level = want.level + 1, self.Levels - 1 do
				if under then break end

				local coarse_size = self.ChunkSizes[level]
				local coarse = self.Tiles[level .. ":" .. math.floor(want.min_x / coarse_size) .. ":" .. math.floor(want.min_z / coarse_size)]
				under = coarse and coarse.entity
			end

			if under then priority = priority + 1e7 end

			priorities[key] = priority
		end
	end

	-- a retiring tile only goes once everything that replaces it is built, and the replacements that are built wait hidden
	-- until then. so the replacements of a retiring tile are built together, at the priority of the one that is first
	for i = 1, #retiring_list do
		local keys = retiring_list[i].replacement_keys
		local best = math.huge

		for j = 1, #keys do
			local priority = priorities[keys[j]]

			if priority and priority < best then best = priority end
		end

		for j = 1, #keys do
			if priorities[keys[j]] then priorities[keys[j]] = best end
		end
	end

	for key, priority in pairs(priorities) do
		self:SetChunkPriority(self.Tiles[key].chunk_key, priority)
	end

	table.clear(priorities)
	self:RetireTiles()
end

function Terrain:UpdateShadowField(position)
	local field = self.shadow_field

	if self.shadow_field_loading then return end

	local extent = self.ShadowExtent
	local step = extent / (self.ShadowSamples - 1)

	if
		field and
		math.abs(position.x - field.center_x) < extent * self.ShadowRecenter and
		math.abs(position.z - field.center_z) < extent * self.ShadowRecenter
	then
		return
	end

	local min_x = math.floor(position.x / step + 0.5) * step - extent / 2
	local min_z = math.floor(position.z / step + 0.5) * step - extent / 2
	self.shadow_field_loading = true
	self.Source:RequestChunk({min_x = min_x, min_z = min_z, size = extent, samples = self.ShadowSamples}, function(chunk)
		self.shadow_field_loading = false

		if not self.Root then
			self.Source:ReleaseChunk(chunk)
			return
		end

		terrain_shadow.SetHeightField(chunk.heights, self.ShadowSamples, min_x, min_z, step, chunk.max_height, self.GridSize / 2 * self:GetLevelChunkSize(self.ShadowLevels - 1))
		self.shadow_field = {center_x = min_x + extent / 2, center_z = min_z + extent / 2}
		self.Source:ReleaseChunk(chunk)
	end)
end

function Terrain:Update(dt)
	self.Source:Update()
	self:ProcessPendingReleases()
	self:RetireTiles()
	self:ProcessBuildQueue()
	self.time_until_update = self.time_until_update - dt

	if self.time_until_update > 0 then return end

	self.time_until_update = self.UpdateInterval
	local camera = render3d.GetCamera()

	if not camera then return end

	local position = camera:GetPosition()

	if self.ShadowExtent then self:UpdateShadowField(position) end

	self:UpdateTiles(position, camera:GetRotation():GetForward(), ViewPriority.GetHalfAngle(camera))

	if self.Physics then self.Physics:Update(position) end

	if self.holding_scene_load and next(self.Desired) then
		for _, tile in pairs(self.Tiles) do
			if not tile.entity and self.Desired[tile.key] then return end
		end

		self.holding_scene_load = false
		scene_loading.End()
	end
end

local active_terrains = setmetatable({}, {__mode = "k"})
Terrain.Active = active_terrains

-- what is up with the tiles, for when some are not there that should be: every tile that exists is listed with what
-- keeps it from being drawn, and whether the scene has it
function Terrain:GetDebugReport()
	local lines = {}
	local counts = {tiles = 0, with_entity = 0, hidden = 0, retiring = 0, swapping = 0}

	for key, tile in pairs(self.Tiles) do
		counts.tiles = counts.tiles + 1

		if tile.entity and tile.entity:IsValid() then counts.with_entity = counts.with_entity + 1 end

		if tile.hidden then counts.hidden = counts.hidden + 1 end

		if tile.retiring then counts.retiring = counts.retiring + 1 end

		if tile.replaced_frame then counts.swapping = counts.swapping + 1 end

		if tile.entity and tile.entity:IsValid() and not tile.retiring then
			local visual = tile.entity.visual
			local problems = {}

			if tile.hidden and not self:IsTileBlocked(tile) then problems[#problems + 1] = "hidden and not blocked" end

			if not visual.Visible and not tile.hidden then problems[#problems + 1] = "not visible" end

			if visual.Visible and not visual.main_gpu_entry_offset then problems[#problems + 1] = "not in the gpu dataset" end

			if visual.scene_removed then problems[#problems + 1] = "removed from the scene" end

			if problems[1] then
				lines[#lines + 1] = string.format("  tile %s: %s", key, table.concat(problems, ", "))
			end
		end
	end

	for key, want in pairs(self.Desired) do
		local tile = self.Tiles[key]

		if not tile then
			lines[#lines + 1] = "  desired tile " .. key .. " has no tile"
		elseif not tile.entity then
			lines[#lines + 1] = "  desired tile " .. key .. " is not built yet"
		end
	end

	table.insert(
		lines,
		1,
		string.format(
			"%s: %d tiles, %d built, %d hidden, %d retiring, %d swapping, %d chunks, %d queued",
			self.Name,
			counts.tiles,
			counts.with_entity,
			counts.hidden,
			counts.retiring,
			counts.swapping,
			table.count(self.Chunks),
			#self.BuildQueue
		)
	)
	return table.concat(lines, "\n")
end

-- what the terrain is doing, for the overlay: counts of the tiles per level and of the build jobs
function Terrain:GetStats()
	local levels = {}

	for level = 0, self.Levels - 1 do
		levels[level] = {desired = 0, built = 0, drawn = 0, waiting = 0, hidden = 0, retiring = 0, queued = 0, loading = 0}
	end

	local totals = {tiles = 0, built = 0, hidden = 0, retiring = 0, waiting = 0, queued = 0, loading = 0, needed = 0, scatter_waiting = 0}

	for key, tile in pairs(self.Tiles) do
		local row = levels[tile.level]
		local entry = tile.chunk_key and self.Chunks[tile.chunk_key]
		totals.tiles = totals.tiles + 1

		if self.Desired[key] then row.desired = row.desired + 1 end

		if tile.entity then
			row.built = row.built + 1
			totals.built = totals.built + 1

			if tile.hidden then
				row.hidden = row.hidden + 1
				totals.hidden = totals.hidden + 1
			elseif self:IsTileDrawn(tile) then
				row.drawn = row.drawn + 1
			else
				row.waiting = row.waiting + 1
				totals.waiting = totals.waiting + 1
			end
		elseif entry and entry.loading then
			row.loading = row.loading + 1
			totals.loading = totals.loading + 1
		elseif entry and entry.queued then
			row.queued = row.queued + 1
			totals.queued = totals.queued + 1

			if entry.priority < 1e7 then totals.needed = totals.needed + 1 end
		end

		if tile.retiring then
			row.retiring = row.retiring + 1
			totals.retiring = totals.retiring + 1

			if tile.scatter_wait and not tile.replaced_frame then totals.scatter_waiting = totals.scatter_waiting + 1 end
		end
	end

	return {
		levels = levels,
		totals = totals,
		queue = #self.BuildQueue,
		chunks = table.count(self.Chunks),
		pending_releases = self.ReleaseTail - self.ReleaseHead + 1,
		colliders = self.Physics and table.count(self.Physics.Colliders) or 0,
		build = self.Stats,
	}
end

commands.Add("terrain_tiles", function()
	for terrain in pairs(active_terrains) do
		print(terrain:GetDebugReport())
	end
end)

function Terrain:Start()
	self:Stop()
	active_terrains[self] = true
	self.Root = Entity.New{Name = self.Name}
	self.Root:SetTransient(true)
	self.Root:AddComponent("transform")

	if self.PhysicsConfig then
		self.Physics = TerrainPhysics.New(self, type(self.PhysicsConfig) == "table" and self.PhysicsConfig or {})
	end

	event.AddListener("Update", self.UpdateId, function(dt)
		if not self.Root or not self.Root:IsValid() then
			event.RemoveListener("Update", self.UpdateId)
			return
		end

		self:Update(dt)
	end)

	self.time_until_update = 0
	self.holding_scene_load = true
	scene_loading.Begin()
	self:Update(0)
	return self
end

function Terrain:Stop()
	active_terrains[self] = nil
	event.RemoveListener("Update", self.UpdateId)

	if self.holding_scene_load then
		self.holding_scene_load = false
		scene_loading.End()
	end

	if self.Physics then
		self.Physics:Remove()
		self.Physics = nil
	end

	if self.shadow_field then
		terrain_shadow.Clear()
		self.shadow_field = nil
	end

	for key, tile in pairs(self.Tiles) do
		self:RemoveTile(tile)
		self.Tiles[key] = nil
	end

	for i = self.ReleaseHead, self.ReleaseTail do
		self.Source:ReleaseChunk(self.PendingReleases[i].chunk)
	end

	self.PendingReleases = {}
	self.ReleaseHead = 1
	self.ReleaseTail = 0

	for key, entry in pairs(self.Chunks) do
		if entry.chunk then self.Source:ReleaseChunk(entry.chunk) end

		entry.cancelled = true
		self.Chunks[key] = nil
	end

	self.BuildQueue = {}
	self.Source:Finish()

	if self.Root and self.Root:IsValid() then self.Root:Remove() end

	self.Root = nil
	return self
end

return Terrain
