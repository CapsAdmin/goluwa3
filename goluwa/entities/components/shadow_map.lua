local objects = import("goluwa/objects/objects.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local ShadowMapObject = import("goluwa/render3d/shadow_map.lua")
local ShadowMap = objects.CreateTemplate("shadow_map")

-- property callbacks fire during AddComponent, before Initialize has built
-- the map. the initial value is already picked up by BuildMapConfig, so only
-- live changes after Initialize need to reach the map
local function after_map(callback)
	return function(self, value)
		if self.Map then callback(self, value) end
	end
end

ShadowMap:StartStorable()
ShadowMap:GetSet("Enabled", true, {callback = after_map(function(self, value)
	self.Map:SetEnabled(value)
end)})
ShadowMap:GetSet("Size", Vec2(512, 512), {callback = after_map(function(self)
	self:RebuildMap()
end)})
ShadowMap:GetSet("Format", "d32_sfloat", {
	enums = {"d32_sfloat", "d16_unorm"},
	callback = after_map(function(self)
		self:RebuildMap()
	end),
})
ShadowMap:GetSet("UpdateMode", "auto", {
	enums = {"auto", "on_move", "continuous"},
	callback = after_map(function(self, value)
		if value == "auto" then
			self.Map.policy.shadow_update_mode = nil
		else
			self.Map.policy.shadow_update_mode = value
		end
	end),
})
ShadowMap:GetSet("UpdateInterval", 1, {
	validate = "integer",
	callback = after_map(function(self, value)
		self.Map.policy.shadow_update_interval = value
	end),
})
ShadowMap:GetSet("PositionEpsilon", 0, {callback = after_map(function(self, value)
	self.Map.policy.shadow_position_epsilon = value
end)})
ShadowMap:GetSet("RotationEpsilon", 0, {callback = after_map(function(self, value)
	self.Map.policy.shadow_rotation_epsilon = value
end)})
ShadowMap:EndStorable()

ShadowMap.AfterMap = after_map

function ShadowMap:BuildUpdatePolicy()
	local update_mode

	if self.UpdateMode ~= "auto" then update_mode = self.UpdateMode end

	return {
		shadow_update_mode = update_mode,
		shadow_update_interval = self.UpdateInterval,
		shadow_position_epsilon = self.PositionEpsilon,
		shadow_rotation_epsilon = self.RotationEpsilon,
	}
end

function ShadowMap:BuildMapConfig()
	local config = {
		mode = self.Mode,
		size = self.Size,
		format = self.Format,
		policy = self:BuildUpdatePolicy(),
	}
	self:BuildModeConfig(config)
	return config
end

function ShadowMap:Initialize()
	self:RebuildMap()
end

function ShadowMap:RebuildMap()
	local map = self.Map

	if map then
		map:Remove()
		-- the old map's textures and pipelines are only freed by the garbage
		-- collector, reclaim them before the replacement map allocates its own
		collectgarbage("collect")
	end

	local map = ShadowMapObject.New(self:BuildMapConfig())
	map:SetLightSource(self.Owner)
	self.Map = map
	return map
end

function ShadowMap:GetMap()
	return self.Map
end

function ShadowMap:OnRemove()
	local map = self.Map
	self.Map = nil

	if map then map:Remove() end
end

return ShadowMap:Register()
