local objects = import("goluwa/objects/objects.lua")
local timer = import("goluwa/timer.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local HeightmapSource = import("goluwa/terrain/heightmap_source.lua")
local heightmap_file = import("goluwa/terrain/heightmap_file.lua")
local META = objects.CreateTemplate("terrain")
META:StartStorable()
META:GetSet("Path", "", {asset = "terrains", callback = "Load"})
META:EndStorable()

function META:GetData()
	return self.data
end

function META:Clear()
	if self.renderer then
		self.renderer:Stop()
		self.renderer = nil
	end

	local world = self.Owner.static_world or static_world.Find(self.Owner)

	if world and world.TerrainHeight == self.height_function then
		world.TerrainHeight = nil
	end

	self.height_function = nil
end

-- the terrain of a heightmap source's data, see heightmap_source.lua. Data that is not read from
-- Path is saved by writing it to a file first (heightmap_file.Save) and setting Path.
function META:SetData(data)
	self.data = data
	self.build_id = (self.build_id or 0) + 1
	self:Clear()

	if not RENDER_3D then return end

	local world = self.Owner.static_world or static_world.Find(self.Owner)

	if world then
		self.height_function = function(x, z)
			return HeightmapSource.SampleHeight(data, x, z)
		end
		world.TerrainHeight = self.height_function
	end

	local build_id = self.build_id

	data.color:AddOnReady(function()
		timer.Delay(0, function()
			if self:IsValid() and self.build_id == build_id then self:Build() end
		end)
	end)
end

function META:Build()
	local Terrain = import("goluwa/terrain/terrain.lua")
	local data = self.data
	local source = HeightmapSource.New(data)
	self.renderer = Terrain.New{
		Name = "terrain",
		Source = source,
		Levels = 6,
		GridSize = 4,
		BaseChunkSize = 64,
		Samples = 65,
		DetailSize = 256,
		ColorSize = 256,
		BuildsPerFrame = 2,
		Physics = {chunk_size = 64, samples = 65, radius = 2},
	}:Start()
	self.renderer.Root:SetName("terrain")
	self.Owner:AddChild(self.renderer.Root)
end

function META:Load()
	if self.Path == "" then return end

	self:SetData(heightmap_file.Load(self.Path))
end

function META:OnRemove()
	self.build_id = (self.build_id or 0) + 1
	self:Clear()
end

return META:Register()
