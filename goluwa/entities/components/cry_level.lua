local objects = import("goluwa/objects/objects.lua")
local steam = import("goluwa/steam/steam.lua")
local crylevel = import("goluwa/steam/crylevel.lua")
local timer = import("goluwa/timer.lua")
local META = objects.CreateTemplate("cry_level")
META:StartStorable()
META:GetSet("Path", "", {callback = "Load"})
META:EndStorable()

function META:Clear()
	if self.renderer then
		self.renderer:Stop()

		if steam.active_cry_terrain_renderer == self.renderer then
			steam.active_cry_terrain_renderer = nil
		end

		self.renderer = nil
	end
end

function META:Load()
	self:Clear()

	if self.Path == "" then return end

	self.load_id = (self.load_id or 0) + 1
	local load_id = self.load_id
	local level_dir, err = crylevel.ResolveLevelDirectory(steam, self.Path)

	if not level_dir then
		wlog("cry_level: %s", tostring(err))
		return
	end

	crylevel.EnsureLevelMounts(steam, level_dir)

	timer.Delay(0, function()
		if self:IsValid() and self.load_id == load_id then self:Build(level_dir) end
	end)
end

function META:Build(level_dir)
	local data = steam.LoadCryLevel(level_dir)
	self.renderer = crylevel.SpawnTerrain(data, self.Owner)
	steam.active_cry_terrain_renderer = self.renderer
	crylevel.ApplyVegetationMaterialState(data)
end

function META:OnRemove()
	self:Clear()
end

return META:Register()
