local objects = import("goluwa/objects/objects.lua")
local game = import("goluwa/cry_engine/game.lua")
local level = import("goluwa/cry_engine/level.lua")
local cry_engine = import("goluwa/cry_engine/cry_engine.lua")
local timer = import("goluwa/timer.lua")
local HeightPhysics = import("goluwa/terrain/height_physics.lua")
local META = objects.CreateTemplate("cry_level")
META:StartStorable()
META:GetSet("Path", "", {callback = "Load"})
META:EndStorable()

function META:Clear()
	if self.renderer then
		self.renderer:Stop()

		if cry_engine.active_terrain_renderer == self.renderer then
			cry_engine.active_terrain_renderer = nil
		end

		self.renderer = nil
	end
end

function META:Load()
	self:Clear()

	if self.Path == "" then return end

	self.load_id = (self.load_id or 0) + 1
	local load_id = self.load_id
	local level_dir, err = game.ResolveLevelDirectory(self.Path)

	if not level_dir then
		wlog("cry_level: %s", tostring(err))
		return
	end

	game.EnsureLevelMounts(level_dir)

	timer.Delay(0, function()
		if self:IsValid() and self.load_id == load_id then self:Build(level_dir) end
	end)
end

function META:Build(level_dir)
	local data = level.Load(level_dir)

	if RENDER_3D then
		local terrain = import("goluwa/cry_engine/terrain.lua")
		self.renderer = terrain.SpawnTerrain(data, self.Owner)
		cry_engine.active_terrain_renderer = self.renderer
		terrain.ApplyVegetationMaterialState(data)
		return
	end

	local terrain = data.terrain

	if not terrain or not terrain.height_data then return end

	self.renderer = HeightPhysics.New{
		Name = "cry_terrain",
		Height = function(x, z)
			return level.SampleTerrainHeight(terrain, x, z)
		end,
		Physics = {chunk_size = 64, samples = 65, radius = 2},
	}:Start()
	self.renderer.Root.spawned_from_cry_level = true
	self.Owner:AddChild(self.renderer.Root)
end

function META:OnRemove()
	self:Clear()
end

return META:Register()
