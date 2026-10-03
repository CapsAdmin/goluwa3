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

function TerrainSource:Submit() end

function TerrainSource:Update() end

function TerrainSource:Finish() end

function TerrainSource:ReleaseChunk(chunk)
	if chunk.normal_texture then
		chunk.normal_texture:Remove()
		chunk.normal_texture = nil
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
