local ffi = require("ffi")
local prototype = require("prototype")
local render = require("render.render")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Quat = require("structs.quat")
local ShadowMap = require("render3d.shadow_map")
local event = require("event")
local Light = prototype.CreateTemplate("light")
Light.Events = {"PreFrame"}
Light:GetSet("LightType", "directional")
Light:GetSet("Color", Color(1.0, 1.0, 1.0, 1.0))
Light:GetSet("Intensity", 1.0)
Light:GetSet("Range", 10.0)
Light:GetSet("InnerCone", 0.9)
Light:GetSet("OuterCone", 0.8)
Light:GetSet("Enabled", true)
Light:GetSet("CastShadows", false)
Light:GetSet("ShadowMap", nil)

function Light:Initialize()
	self:AddEvent("PreFrame")
end

function Light:SetLightType(light_type)
	self.LightType = light_type

	if light_type == "sun" then
		self:SetName("sun")
		self:SetCastShadows({
			ortho_size = 5,
			near_plane = 1,
			far_plane = 500,
		})
	end
end

function Light:OnPreFrame(dt)
	if not self:GetCastShadows() then return end

	self:RenderShadows()
end

function Light:SetCastShadows(config)
	if not config then
		self.CastShadows = false
		self.ShadowMap = nil
		return
	end

	self.CastShadows = config

	if self.LightType == "directional" or self.LightType == "sun" then
		self.ShadowMap = ShadowMap.New(
			{
				size = config.size,
				ortho_size = config.ortho_size or 50.0,
				near_plane = config.near_plane or 1.0,
				far_plane = config.far_plane or 200.0,
			}
		)
	elseif self.LightType == "point" then
		error("NYI point light", 2)
		self.CastShadows = false
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

	self.ShadowMap:UpdateCascadeLightMatrices(self.Owner.transform:GetRotation())
end

function Light:RenderShadows()
	if not self:GetCastShadows() then return end

	self:UpdateShadowMap()

	for cascade_idx = 1, self.ShadowMap:GetCascadeCount() do
		local shadow_cmd = self.ShadowMap:Begin(cascade_idx)
		event.Call("DrawAllShadows", shadow_cmd, self.ShadowMap, cascade_idx)
		self.ShadowMap:End(cascade_idx)
	end
end

return Light:Register()
