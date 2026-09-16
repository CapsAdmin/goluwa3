local objects = import("goluwa/objects/objects.lua")
local ShadowMap = import("goluwa/entities/components/shadow_map.lua")
local after_map = ShadowMap.AfterMap
local ShadowMapDirectional = objects.CreateTemplate("shadow_map_directional")
ShadowMapDirectional.Base = ShadowMap
ShadowMapDirectional.Mode = "directional"
ShadowMapDirectional:StartStorable()
ShadowMapDirectional:GetSet(
	"NearPlane",
	0.1,
	{
		callback = after_map(function(self, value)
			self.Map.near_plane = value
		end),
	}
)
ShadowMapDirectional:GetSet(
	"FarPlane",
	100,
	{
		callback = after_map(function(self, value)
			self.Map.far_plane = value
		end),
	}
)
ShadowMapDirectional:GetSet(
	"OrthoSize",
	50,
	{
		callback = after_map(function(self, value)
			self.Map.ortho_size = value
		end),
	}
)
ShadowMapDirectional:GetSet(
	"DirectionalProjectionMode",
	"perspective",
	{
		enums = {"perspective", "orthographic"},
		callback = after_map(function(self, value)
			self.Map.directional_projection_mode = value
		end),
	}
)
ShadowMapDirectional:GetSet(
	"PerspectiveFov",
	70,
	{
		callback = after_map(function(self, value)
			self.Map.perspective_fov = math.rad(value)
		end),
	}
)
ShadowMapDirectional:GetSet(
	"SceneBoundsMargin",
	16,
	{
		callback = after_map(function(self, value)
			self.Map.scene_bounds_margin = value
		end),
	}
)
ShadowMapDirectional:GetSet(
	"MinCasterTexelSize",
	0,
	{
		callback = after_map(function(self, value)
			self.Map.min_caster_texel_size = value
		end),
	}
)
ShadowMapDirectional:EndStorable()

function ShadowMapDirectional:BuildModeConfig(config)
	config.near_plane = self.NearPlane
	config.far_plane = self.FarPlane
	config.ortho_size = self.OrthoSize
	config.directional_projection_mode = self.DirectionalProjectionMode
	config.perspective_fov = math.rad(self.PerspectiveFov)
	config.scene_bounds_margin = self.SceneBoundsMargin
	config.min_caster_texel_size = self.MinCasterTexelSize
end

return ShadowMapDirectional:Register()
