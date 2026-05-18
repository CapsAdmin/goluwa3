local ProceduralTerrainTileCache = {}
ProceduralTerrainTileCache.__index = ProceduralTerrainTileCache
local GENERATORS = {
	height = "GenerateHeightTile",
	displacement = "GenerateDisplacementTile",
	albedo = "GenerateAlbedoTile",
	normal = "GenerateNormalTile",
	material = "GenerateMaterialTile",
}

local function round_key_number(value)
	return string.format("%.6f", tonumber(value) or 0)
end

local function build_tile_key(attachment, config)
	return table.concat(
		{
			attachment,
			tostring(config.width or config.size or 0),
			tostring(config.height or config.size or 0),
			round_key_number(config.min_x),
			round_key_number(config.min_z),
			round_key_number(config.span_x or config.world_size or config.size_x),
			round_key_number(
				config.span_z or
					config.world_size or
					config.size_z or
					config.span_x or
					config.world_size or
					config.size_x
			),
			round_key_number(config.normal_strength),
		},
		"|"
	)
end

local function copy_config(config)
	local out = {}

	for key, value in pairs(config or {}) do
		out[key] = value
	end

	return out
end

function ProceduralTerrainTileCache.New(config)
	config = config or {}
	local self = setmetatable({}, ProceduralTerrainTileCache)
	self.Source = assert(config.Source, "ProceduralTerrainTileCache requires Source")
	self.Tiles = {}
	self.Stats = {
		hits = 0,
		misses = 0,
		generated = 0,
	}
	return self
end

function ProceduralTerrainTileCache:GetTile(attachment, config)
	local generator_name = GENERATORS[attachment]
	assert(generator_name, "unknown terrain attachment: " .. tostring(attachment))
	assert(self.Source[generator_name], "source is missing generator: " .. generator_name)
	local key = build_tile_key(attachment, config or {})
	local cached = self.Tiles[key]

	if cached then
		self.Stats.hits = self.Stats.hits + 1
		return cached
	end

	self.Stats.misses = self.Stats.misses + 1
	local samples, width, height = self.Source[generator_name](self.Source, config or {})
	local tile = {
		key = key,
		attachment = attachment,
		config = copy_config(config or {}),
		samples = samples,
		width = width,
		height = height,
	}
	self.Tiles[key] = tile
	self.Stats.generated = self.Stats.generated + 1
	return tile
end

function ProceduralTerrainTileCache:GetHeightTile(config)
	return self:GetTile("height", config)
end

function ProceduralTerrainTileCache:GetDisplacementTile(config)
	return self:GetTile("displacement", config)
end

function ProceduralTerrainTileCache:GetAlbedoTile(config)
	return self:GetTile("albedo", config)
end

function ProceduralTerrainTileCache:GetNormalTile(config)
	return self:GetTile("normal", config)
end

function ProceduralTerrainTileCache:GetMaterialTile(config)
	return self:GetTile("material", config)
end

function ProceduralTerrainTileCache:InvalidateTile(attachment, config)
	self.Tiles[build_tile_key(attachment, config or {})] = nil
	return self
end

function ProceduralTerrainTileCache:Clear()
	self.Tiles = {}
	return self
end

function ProceduralTerrainTileCache:GetStats()
	return {
		hits = self.Stats.hits,
		misses = self.Stats.misses,
		generated = self.Stats.generated,
		cached = table.count and table.count(self.Tiles) or 0,
	}
end

return ProceduralTerrainTileCache
