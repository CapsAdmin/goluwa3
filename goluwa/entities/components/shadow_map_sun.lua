local objects = import("goluwa/objects/objects.lua")
local ShadowMap = import("goluwa/entities/components/shadow_map.lua")
local after_map = ShadowMap.AfterMap
local ShadowMapSun = objects.CreateTemplate("shadow_map_sun")
ShadowMapSun.Base = ShadowMap
ShadowMapSun.Mode = "sun"
ShadowMapSun:StartStorable()
ShadowMapSun:GetSet(
	"Role",
	"cascades",
	{
		enums = {"cascades", "inset"},
		callback = after_map(function(self, value)
			self.Map:SetRole(value)
		end),
	}
)
ShadowMapSun:GetSet(
	"CascadeCount",
	3,
	{
		validate = "integer",
		callback = after_map(function(self)
			self:RebuildMap()
		end),
	}
)
ShadowMapSun:GetSet(
	"CascadeSplitLambda",
	0.75,
	{
		callback = after_map(function(self, value)
			self.Map.cascade_split_lambda = value
		end),
	}
)
ShadowMapSun:GetSet(
	"MaxShadowDistance",
	500,
	{
		callback = after_map(function(self, value)
			self.Map.max_shadow_distance = value
		end),
	}
)
ShadowMapSun:GetSet(
	"SceneBoundsMargin",
	16,
	{
		callback = after_map(function(self, value)
			self.Map.scene_bounds_margin = value
		end),
	}
)
ShadowMapSun:GetSet(
	"MinCasterTexelSize",
	0,
	{
		callback = after_map(function(self, value)
			self.Map.min_caster_texel_size = value
		end),
	}
)
ShadowMapSun:EndStorable()

function ShadowMapSun:BuildModeConfig(config)
	config.role = self.Role
	config.cascade_count = self.CascadeCount
	config.cascade_split_lambda = self.CascadeSplitLambda
	config.max_shadow_distance = self.MaxShadowDistance
	config.scene_bounds_margin = self.SceneBoundsMargin
	config.min_caster_texel_size = self.MinCasterTexelSize
end

return ShadowMapSun:Register()
