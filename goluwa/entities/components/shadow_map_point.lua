local objects = import("goluwa/objects/objects.lua")
local ShadowMap = import("goluwa/entities/components/shadow_map.lua")
local after_map = ShadowMap.AfterMap
local ShadowMapPoint = objects.CreateTemplate("shadow_map_point")
ShadowMapPoint.Base = ShadowMap
ShadowMapPoint.Mode = "point"
ShadowMapPoint:StartStorable()
ShadowMapPoint:GetSet(
	"NearPlane",
	0.1,
	{
		callback = after_map(function(self, value)
			self.Map.near_plane = value
		end),
	}
)
ShadowMapPoint:GetSet(
	"FarPlane",
	100,
	{
		callback = after_map(function(self, value)
			self.Map.far_plane = value
		end),
	}
)
ShadowMapPoint:EndStorable()

function ShadowMapPoint:BuildModeConfig(config)
	config.near_plane = self.NearPlane
	config.far_plane = self.FarPlane
end

return ShadowMapPoint:Register()
