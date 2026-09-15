local objects = import("goluwa/objects/objects.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local ShadowMapObject = import("goluwa/render3d/shadow_map.lua")
local ShadowMap = objects.CreateTemplate("shadow_map")
import.loaded["goluwa/entities/components/shadow_map.lua"] = ShadowMap
local RECREATE_PROPERTIES = {
	Mode = true,
	Size = true,
	Format = true,
	CascadeCount = true,
}
ShadowMap:StartStorable()
ShadowMap:GetSet("Enabled", true, {callback = "OnPropertyChanged"})
ShadowMap:GetSet(
	"Mode",
	"sun",
	{enums = {"sun", "directional", "point"}, callback = "OnPropertyChanged"}
)
ShadowMap:GetSet(
	"Role",
	"cascades",
	{enums = {"cascades", "inset"}, callback = "OnPropertyChanged"}
)
ShadowMap:GetSet(
	"Size",
	Vec2(512, 512),
	{
		validate = function(value)
			if type(value) == "number" then return Vec2(value, value) end

			if value.w then return value end

			return Vec2(value.x, value.y)
		end,
		callback = "OnPropertyChanged",
	}
)
ShadowMap:GetSet(
	"Format",
	"d32_sfloat",
	{
		enums = {"d32_sfloat", "d16_unorm"},
		callback = "OnPropertyChanged",
	}
)
ShadowMap:GetSet("CascadeCount", 3, {validate = "integer", callback = "OnPropertyChanged"})
ShadowMap:GetSet(
	"DirectionalProjectionMode",
	"lispsm_or_orthographic",
	{
		enums = {"lispsm_or_orthographic", "orthographic"},
		callback = "OnPropertyChanged",
	}
)
ShadowMap:GetSet("PerspectiveFov", 70, {callback = "OnPropertyChanged"})
ShadowMap:GetSet("NearPlane", 0.1, {callback = "OnPropertyChanged"})
ShadowMap:GetSet("FarPlane", 100, {callback = "OnPropertyChanged"})
ShadowMap:GetSet("OrthoSize", 50, {callback = "OnPropertyChanged"})
ShadowMap:GetSet("CascadeSplitLambda", 0.75, {callback = "OnPropertyChanged"})
ShadowMap:GetSet("MaxShadowDistance", 500, {callback = "OnPropertyChanged"})
ShadowMap:GetSet("MinCasterTexelSize", 0, {callback = "OnPropertyChanged"})
ShadowMap:GetSet("SceneBoundsMargin", 16, {callback = "OnPropertyChanged"})
ShadowMap:GetSet(
	"UpdateMode",
	"auto",
	{
		enums = {"auto", "on_move", "continuous"},
		callback = "OnPropertyChanged",
	}
)
ShadowMap:GetSet("UpdateInterval", 1, {validate = "integer", callback = "OnPropertyChanged"})
ShadowMap:GetSet("PositionEpsilon", 0, {callback = "OnPropertyChanged"})
ShadowMap:GetSet("RotationEpsilon", 0, {callback = "OnPropertyChanged"})
ShadowMap:EndStorable()
local LIVE_PROPERTIES = {
	Enabled = function(map, value)
		map:SetEnabled(value)
	end,
	Role = function(map, value)
		map:SetRole(value)
	end,
	DirectionalProjectionMode = function(map, value)
		map.directional_projection_mode = value
	end,
	PerspectiveFov = function(map, value)
		map.perspective_fov = math.rad(value)
	end,
	NearPlane = function(map, value)
		map.near_plane = value
	end,
	FarPlane = function(map, value)
		map.far_plane = value
	end,
	OrthoSize = function(map, value)
		map.ortho_size = value
	end,
	CascadeSplitLambda = function(map, value)
		map.cascade_split_lambda = value
	end,
	MaxShadowDistance = function(map, value)
		map.max_shadow_distance = value
	end,
	MinCasterTexelSize = function(map, value)
		map.min_caster_texel_size = value
	end,
	SceneBoundsMargin = function(map, value)
		map.scene_bounds_margin = value
	end,
	UpdateMode = function(map, value)
		if value == "auto" then
			map.policy.shadow_update_mode = nil
		else
			map.policy.shadow_update_mode = value
		end
	end,
	UpdateInterval = function(map, value)
		map.policy.shadow_update_interval = value
	end,
	PositionEpsilon = function(map, value)
		map.policy.shadow_position_epsilon = value
	end,
	RotationEpsilon = function(map, value)
		map.policy.shadow_rotation_epsilon = value
	end,
}

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
	local cascade_count

	if self.Mode ~= "point" then cascade_count = self.CascadeCount end

	return {
		mode = self.Mode,
		size = self.Size,
		format = self.Format,
		cascade_count = cascade_count,
		near_plane = self.NearPlane,
		far_plane = self.FarPlane,
		ortho_size = self.OrthoSize,
		cascade_split_lambda = self.CascadeSplitLambda,
		max_shadow_distance = self.MaxShadowDistance,
		min_caster_texel_size = self.MinCasterTexelSize,
		scene_bounds_margin = self.SceneBoundsMargin,
		role = self.Role,
		directional_projection_mode = self.DirectionalProjectionMode,
		perspective_fov = math.rad(self.PerspectiveFov),
		policy = self:BuildUpdatePolicy(),
	}
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

function ShadowMap:OnPropertyChanged(var_name, old_value, new_value)
	local map = self.Map

	if not map then return end

	if RECREATE_PROPERTIES[var_name] then
		self:RebuildMap()
		return
	end

	local apply = LIVE_PROPERTIES[var_name]

	if apply then apply(map, new_value) end
end

return ShadowMap:Register()
