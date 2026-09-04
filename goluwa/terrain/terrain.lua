local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local tiles = import("goluwa/terrain/tiles.lua")
local TerrainPhysics = import("goluwa/terrain/physics.lua")
local Terrain = {}
Terrain.__index = Terrain

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
	self.Levels = config.Levels or 8
	self.BaseChunkSize = config.BaseChunkSize or 64
	self.Samples = config.Samples or 65
	self.DetailSize = config.DetailSize or 256
	self.SplatSize = config.SplatSize or 128
	self.ColorSize = config.ColorSize
	self.ShadowLevels = config.ShadowLevels or 3
	self.BuildsPerUpdate = config.BuildsPerUpdate or 2
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

function Terrain:ReleaseChunk(key)
	local entry = self.Chunks[key]

	if not entry then return end

	entry.refs = entry.refs - 1

	if entry.refs > 0 then return end

	self.Chunks[key] = nil

	if entry.chunk then
		self.Source:ReleaseChunk(entry.chunk)
	else
		entry.cancelled = true
	end
end

local function sort_build_queue(a, b)
	return a.priority < b.priority
end

function Terrain:ProcessBuildQueue()
	local queue = self.BuildQueue

	if #queue == 0 then return end

	table.sort(queue, sort_build_queue)
	local built = 0

	while built < self.BuildsPerUpdate and #queue > 0 do
		local entry = table.remove(queue, 1)
		entry.queued = false

		if not entry.cancelled then
			built = built + 1

			self.Source:RequestChunk(entry.request, function(chunk)
				if entry.cancelled then
					self.Source:ReleaseChunk(chunk)
					return
				end

				entry.chunk = chunk
				local waiters = entry.waiters
				entry.waiters = {}

				for i = 1, #waiters do
					waiters[i](chunk)
				end
			end)
		end
	end
end

function Terrain:GetLevelChunkSize(level)
	return self.BaseChunkSize * 2 ^ level
end

function Terrain:GetLevelOrigin(level, position)
	local chunk_size = self:GetLevelChunkSize(level)
	local snap = chunk_size * 2
	return math.floor((position.x - chunk_size) / snap) * snap,
	math.floor((position.z - chunk_size) / snap) * snap
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

		for dz = 0, 3 do
			for dx = 0, 3 do
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
						priority = level * 16 + math.abs(dx - 1.5) + math.abs(dz - 1.5),
					}
				end
			end
		end

		previous_min_x = origin_x
		previous_min_z = origin_z
		previous_max_x = origin_x + chunk_size * 4
		previous_max_z = origin_z + chunk_size * 4
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
	visual:SetUseOcclusionCulling(false)
	visual:SetCullDistance(1e8)
	local primitive_entity = Entity.New{
		Name = entity:GetName() .. "_primitive",
		Parent = entity,
	}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	local normal_texture = tiles.BakeNormalTexture(chunk)
	local polygon = tiles.BuildPolygon(chunk, self:GetLevelSkirtDepth(level))
	primitive:SetPolygon3D(polygon)
	primitive:SetMaterial(tiles.CreateMaterial(chunk, normal_texture, self.Source:GetLayers()))
	visual:BuildAABB()
	return {
		key = want.key,
		level = level,
		entity = entity,
		polygon = polygon,
		normal_texture = normal_texture,
		material = primitive:GetMaterial(),
	}
end

function Terrain:RemoveTile(tile)
	if tile.entity and tile.entity:IsValid() then tile.entity:Remove() end

	if tile.normal_texture then tile.normal_texture:Remove() end

	if tile.chunk_key then self:ReleaseChunk(tile.chunk_key) end
end

local function tile_bounds(self, tile)
	local size = self:GetLevelChunkSize(tile.level)
	local min_x = tile.chunk_x * size
	local min_z = tile.chunk_z * size
	return min_x, min_z, min_x + size, min_z + size
end

local function tiles_overlap(self, a, b)
	local a_min_x, a_min_z, a_max_x, a_max_z = tile_bounds(self, a)
	local b_min_x, b_min_z, b_max_x, b_max_z = tile_bounds(self, b)
	return a_min_x < b_max_x and b_min_x < a_max_x and a_min_z < b_max_z and b_min_z < a_max_z
end

local function set_tile_hidden(self, tile, hidden)
	tile.hidden = hidden

	if not tile.entity or not tile.entity.visual then return end

	tile.entity.visual:SetVisible(not hidden)
	tile.entity.visual:SetCastShadows(not hidden and tile.level < self.ShadowLevels)
end

--[[
	When the camera moves, tiles that are no longer wanted keep rendering until
	every wanted tile overlapping their area has been built, so no holes open.
	Meanwhile the newly built tiles stay hidden, because the levels differ in
	height and overlapping them would z-fight and cast stray shadows. Once the
	last replacement is built, the old tile goes and the new ones appear in
	the same update.
]]
function Terrain:IsTileReplaced(tile)
	for key, want in pairs(self.Desired) do
		if tiles_overlap(self, tile, want) then
			local current = self.Tiles[key]

			if not current or not current.entity then return false end
		end
	end

	return true
end

function Terrain:IsTileBlocked(tile)
	for _, other in pairs(self.Tiles) do
		if other.retiring and other.entity and other ~= tile and tiles_overlap(self, tile, other) then
			return true
		end
	end

	return false
end

function Terrain:RetireTiles()
	for key, tile in pairs(self.Tiles) do
		if tile.retiring and (not tile.entity or self:IsTileReplaced(tile)) then
			self:RemoveTile(tile)
			self.Tiles[key] = nil
		end
	end

	for _, tile in pairs(self.Tiles) do
		if tile.hidden and not tile.retiring and not self:IsTileBlocked(tile) then
			set_tile_hidden(self, tile, false)
		end
	end
end

function Terrain:UpdateTiles(position)
	local desired = self:GatherDesiredTiles(position)
	self.Desired = desired

	for key, tile in pairs(self.Tiles) do
		tile.retiring = not desired[key]
	end

	for key, want in pairs(desired) do
		if not self.Tiles[key] then
			local tile = {
				key = key,
				level = want.level,
				chunk_x = want.chunk_x,
				chunk_z = want.chunk_z,
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
					tile.normal_texture = built.normal_texture
					tile.material = built.material

					if self:IsTileBlocked(tile) then set_tile_hidden(self, tile, true) end
				end,
				want.priority
			)
		end
	end

	self:RetireTiles()
end

function Terrain:Update(dt)
	self.time_until_update = self.time_until_update - dt

	if self.time_until_update > 0 then return end

	self.time_until_update = self.UpdateInterval
	local camera = render3d.GetCamera()

	if not camera then return end

	local position = camera:GetPosition()
	self:UpdateTiles(position)

	if self.Physics then self.Physics:Update(position) end

	self:ProcessBuildQueue()
	self:RetireTiles()
end

function Terrain:Start()
	self:Stop()
	self.Root = Entity.New{Name = self.Name}
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
	self:Update(0)
	return self
end

function Terrain:Stop()
	event.RemoveListener("Update", self.UpdateId)

	if self.Physics then
		self.Physics:Remove()
		self.Physics = nil
	end

	for key, tile in pairs(self.Tiles) do
		self:RemoveTile(tile)
		self.Tiles[key] = nil
	end

	for key, entry in pairs(self.Chunks) do
		if entry.chunk then self.Source:ReleaseChunk(entry.chunk) end

		entry.cancelled = true
		self.Chunks[key] = nil
	end

	self.BuildQueue = {}

	if self.Root and self.Root:IsValid() then self.Root:Remove() end

	self.Root = nil
	return self
end

return Terrain
