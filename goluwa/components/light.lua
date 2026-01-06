local ffi = require("ffi")
local prototype = require("prototype")
local ecs = require("ecs")
local render = require("render.render")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Quat = require("structs.quat")
local ShadowMap = require("render3d.shadow_map")
local Light = {}
local META = prototype.CreateTemplate("component", "light")
META.ComponentName = "light"
META.Require = {"transform"}
META.Events = {"PreFrame"}
META:GetSet("LightType", "directional")
META:GetSet("Color", Color(1.0, 1.0, 1.0, 1.0))
META:GetSet("Intensity", 1.0)
META:GetSet("Range", 10.0)
META:GetSet("InnerCone", 0.9)
META:GetSet("OuterCone", 0.8)
META:GetSet("Enabled", true)
META:GetSet("CastShadows", false)
META:GetSet("ShadowMap", nil)

function META:SetLightType(light_type)
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

function META:OnAdd(entity) -- Nothing special needed
end

-- PreFrame event handler - renders shadows automatically
function META:OnPreFrame(dt)
	if not self:GetCastShadows() then return end

	self:RenderShadows()
end

function META:SetCastShadows(config)
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

function META:UpdateShadowMap()
	if not self.ShadowMap then return end

	self.ShadowMap:UpdateCascadeLightMatrices(self.Entity.transform:GetRotation())
end

local Model = nil

function META:RenderShadows()
	Model = Model or require("components.model")

	if not self:GetCastShadows() then return end

	self:UpdateShadowMap()

	for cascade_idx = 1, self.ShadowMap:GetCascadeCount() do
		local shadow_cmd = self.ShadowMap:Begin(cascade_idx)
		Model.DrawAllShadows(shadow_cmd, self.ShadowMap, cascade_idx)
		self.ShadowMap:End(cascade_idx)
	end
end

META:Register()
ecs.RegisterComponent(META)
Light.Component = META
return Light
