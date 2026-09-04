--[[
	A terrain source answers chunk requests. The terrain object never cares
	where the data comes from, so a source can be procedural, a heightmap
	texture, or something fetched over the network.

	request = {
		min_x, min_z, size,  -- world bounds of the square chunk
		samples,             -- CPU height samples per side (nil = none wanted)
		detail_size,         -- GPU height texture size for normal maps (nil = none)
		splat_size,          -- material weight texture size (nil = none)
		color_size,          -- albedo texture size (nil = none)
	}

	The callback receives a chunk:

	chunk = {
		request = request,
		heights = float[samples * samples] in meters, row major, z rows, x columns, inclusive of both edges
		min_height, max_height,
		height_texture = r32_sfloat texture in meters (texel centers), or nil
		splat_texture = rgba8 layer weights, or nil
		color_texture = rgba8 albedo, or nil
	}

	Sources may answer synchronously inside RequestChunk or later.
]]
local TerrainSource = {}
TerrainSource.__index = TerrainSource

function TerrainSource.New(config)
	local self = setmetatable({}, TerrainSource)
	self.MinHeight = config.MinHeight or 0
	self.MaxHeight = config.MaxHeight or 1000
	self.Layers = config.Layers or {}
	return self
end

function TerrainSource:GetInfo()
	return {
		min_height = self.MinHeight,
		max_height = self.MaxHeight,
		layers = self.Layers,
	}
end

function TerrainSource:GetLayers()
	return self.Layers
end

function TerrainSource:RequestChunk(request, callback)
	error("terrain source does not implement RequestChunk")
end

function TerrainSource:ReleaseChunk(chunk)
	if chunk.height_texture then
		chunk.height_texture:Remove()
		chunk.height_texture = nil
	end

	if chunk.splat_texture then
		chunk.splat_texture:Remove()
		chunk.splat_texture = nil
	end

	if chunk.color_texture then
		chunk.color_texture:Remove()
		chunk.color_texture = nil
	end

	chunk.heights = nil
end

return TerrainSource
