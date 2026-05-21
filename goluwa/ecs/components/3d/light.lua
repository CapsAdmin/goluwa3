local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local render = import("goluwa/render/render.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Quat = import("goluwa/structs/quat.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local event = import("goluwa/event.lua")
local Light = prototype.CreateTemplate("light")
Light.Events = {"PreFrame"}
Light:StartStorable()
Light:GetSet("LightType", "directional")
Light:GetSet("Color", Color(1.0, 1.0, 1.0, 1.0))
Light:GetSet("Intensity", 1.0)
Light:GetSet("Range", 10.0)
Light:GetSet("InnerCone", 0.9)
Light:GetSet("OuterCone", 0.8)
Light:GetSet("Enabled", true)
Light:GetSet("CastShadows", false)
Light:GetSet("ShadowMap", nil)
Light:EndStorable()

function Light:Initialize()
	self:AddGlobalEvent("PreFrame")
end

function Light:SetLightType(light_type)
	self.LightType = light_type

	if light_type == "sun" then
		self:SetName("sun")
		self:SetCastShadows{
			ortho_size = 5,
			near_plane = 1,
			far_plane = 500,
		}
	end
end

function Light:OnPreFrame(dt)
	if not self:GetCastShadows() then return end

	self:RenderShadows()
end

local function get_default_shadow_config(self)
	if self.LightType == "sun" then
		return {
			ortho_size = 5,
			near_plane = 1,
			far_plane = 500,
		}
	elseif self.LightType == "directional" then
		return {
			ortho_size = self.Range,
			near_plane = 0.1,
			far_plane = self.Range,
			max_shadow_distance = self.Range,
		}
	elseif self.LightType == "point" then
		return {
			near_plane = 0.05,
			far_plane = self.Range,
			range = self.Range,
		}
	elseif self.LightType == "spot" then
		error("NYI spot light", 2)
	end

	error("Unknown light type: " .. tostring(self.LightType), 2)
end

function Light:SetCastShadows(config)
	if not config then
		self.CastShadows = false
		self.ShadowMap = nil
		self.InsetShadowMap = nil
		return
	end

	if config == true then
		config = type(self.CastShadows) == "table" and
			self.CastShadows or
			get_default_shadow_config(self)
	elseif type(config) ~= "table" then
		error("SetCastShadows expects false, true, or a config table", 2)
	end

	self.CastShadows = config
	local cascade_count = config.cascade_count or (config.cascade_sizes and #config.cascade_sizes) or nil

	if self.LightType == "sun" then
		self.ShadowMap = ShadowMap.New{
			mode = "sun",
			size = config.size,
			cascade_sizes = config.cascade_sizes,
			cascade_zoom_factors = config.cascade_zoom_factors,
			cascade_count = cascade_count,
			cascade_split_lambda = config.cascade_split_lambda,
			max_shadow_distance = config.max_shadow_distance or config.far_plane,
			ortho_size = config.ortho_size or 50.0,
			near_plane = config.near_plane or 1.0,
			far_plane = config.far_plane or 200.0,
		}

		if config.inset_shadows then
			local inset = config.inset_shadows
			self.InsetShadowMap = ShadowMap.New{
				size = inset.size or config.size,
				cascade_count = 1,
				cascade_sizes = {inset.size or config.size},
				cascade_zoom_factors = {inset.zoom_factor or 1},
				cascade_split_lambda = 1,
				max_shadow_distance = inset.distance or 64,
				ortho_size = inset.ortho_size or config.ortho_size or 50.0,
				near_plane = inset.near_plane or config.near_plane or 1.0,
				far_plane = inset.far_plane or inset.distance or config.far_plane or 200.0,
			}
		else
			self.InsetShadowMap = nil
		end
	elseif self.LightType == "directional" then
		self.ShadowMap = ShadowMap.New{
			mode = "directional",
			size = config.size,
			cascade_count = 1,
			cascade_sizes = {config.size},
			ortho_size = config.ortho_size or self.Range,
			near_plane = config.near_plane or 0.1,
			far_plane = config.far_plane or self.Range,
			max_shadow_distance = config.max_shadow_distance or self.Range,
		}
		self.InsetShadowMap = nil
	elseif self.LightType == "point" then
		self.ShadowMap = ShadowMap.New{
			mode = "point",
			size = config.size,
			near_plane = config.near_plane or 0.05,
			far_plane = config.far_plane or config.range or self.Range,
		}
		self.InsetShadowMap = nil
	elseif self.LightType == "spot" then
		error("NYI spot light", 2)
		self.CastShadows = false
	else
		error("Unknown light type: " .. tostring(self.LightType), 2)
		self.CastShadows = false
	end
end

function Light:UpdateShadowMap()
	if not self.ShadowMap then return end

	if self.LightType == "point" then
		self.ShadowMap:UpdatePointLightMatrices(self.Owner.transform:GetPosition())
	elseif self.LightType == "directional" then
		local shadow_rotation = self.Owner.transform:GetRotation() * Quat():SetAngles(Deg3(0, 180, 0))
		self.ShadowMap:UpdateLocalDirectionalLightMatrices(
			self.Owner.transform:GetPosition(),
			shadow_rotation,
			self.Range,
			self.ShadowMap:GetSize().w > 0 and self.ShadowMap.ortho_size or self.Range
		)
	else
		self.ShadowMap:UpdateCascadeLightMatrices(self.Owner.transform:GetRotation())
	end

	if self.InsetShadowMap then
		self.InsetShadowMap:UpdateCascadeLightMatrices(self.Owner.transform:GetRotation())
	end
end

function Light:RenderShadows()
	if not self:GetCastShadows() then return end

	self:UpdateShadowMap()
	event.Call("PrimeAllShadowMaterials", self.ShadowMap)

	if self.InsetShadowMap then
		event.Call("PrimeAllShadowMaterials", self.InsetShadowMap)
	end

	for cascade_idx = 1, self.ShadowMap:GetCascadeCount() do
		local shadow_cmd = self.ShadowMap:Begin(cascade_idx)
		render.PushCommandBuffer(shadow_cmd)
		event.Call("DrawAllShadows", self.ShadowMap, cascade_idx)
		render.PopCommandBuffer()
		self.ShadowMap:End(cascade_idx)
	end

	if self.InsetShadowMap then
		for cascade_idx = 1, self.InsetShadowMap:GetCascadeCount() do
			local shadow_cmd = self.InsetShadowMap:Begin(cascade_idx)
			render.PushCommandBuffer(shadow_cmd)
			event.Call("DrawAllShadows", self.InsetShadowMap, cascade_idx)
			render.PopCommandBuffer()
			self.InsetShadowMap:End(cascade_idx)
		end
	end
end

return Light:Register()
