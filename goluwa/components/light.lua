local ffi = require("ffi")
local prototype = require("prototype")
local ecs = require("ecs")
local Vec3 = require("structs.vec3")
local Quat = require("structs.quat")
local ShadowMap = require("graphics.shadow_map")
local render3d = require("graphics.render3d")
local Model = require("components.model")
local META = prototype.CreateTemplate("component", "light")
META.ComponentName = "light"
-- Light requires transform component
META.Require = {"transform"}
META.Events = {"PreFrame"} -- Subscribe to PreFrame for shadow rendering
-- Light types
META.TYPE_DIRECTIONAL = 0
META.TYPE_POINT = 1
META.TYPE_SPOT = 2
META:GetSet("LightType", 0) -- TYPE_DIRECTIONAL
META:GetSet("Rotation", Quat(0, 0, 0, 1))
META:GetSet("Color", {1.0, 1.0, 1.0})
META:GetSet("Intensity", 1.0)
META:GetSet("Range", 10.0)
META:GetSet("InnerCone", 0.9) -- cos(angle) for spot lights
META:GetSet("OuterCone", 0.8)
META:GetSet("Enabled", true)
META:GetSet("IsSun", false)
META:GetSet("CastShadows", false)
META:GetSet("ShadowMap", nil)

function META:Initialize(config)
	config = config or {}

	if config.type then self:SetLightType(config.type) end

	if config.rotation then self:SetRotation(config.rotation) end

	if config.color then self:SetColor(config.color) end

	if config.intensity then self:SetIntensity(config.intensity) end

	if config.range then self:SetRange(config.range) end

	if config.inner_cone then self:SetInnerCone(config.inner_cone) end

	if config.outer_cone then self:SetOuterCone(config.outer_cone) end

	if config.enabled ~= nil then self:SetEnabled(config.enabled) end

	if config.is_sun ~= nil then self:SetIsSun(config.is_sun) end

	if config.cast_shadows then self:EnableShadows(config.shadow_config) end
end

function META:OnAdd(entity) -- Nothing special needed
end

-- PreFrame event handler - renders shadows automatically
function META:OnPreFrame(dt)
	if not self:HasShadows() then return end

	self:RenderShadows()

	if self.IsSun then self:UpdateShadowUBO() end
end

function META:GetDirection()
	return self.Rotation:GetForward()
end

-- Return color in format expected by render3d (with .r, .g, .b properties)
function META:GetColor()
	return {r = self.Color[1], g = self.Color[2], b = self.Color[3]}
end

function META:GetPosition()
	if self.Entity and self.Entity:HasComponent("transform") then
		return self.Entity.transform:GetPosition()
	end

	return Vec3(0, 0, 0)
end

function META:EnableShadows(config)
	config = config or {}
	self.CastShadows = true

	if self.LightType == META.TYPE_DIRECTIONAL then
		self.ShadowMap = ShadowMap.New(
			{
				size = config.size,
				ortho_size = config.ortho_size or 50.0,
				near_plane = config.near_plane or 1.0,
				far_plane = config.far_plane or 200.0,
			}
		)
	elseif self.LightType == META.TYPE_POINT then
		print("Warning: Point light shadows not yet implemented")
		self.CastShadows = false
	end
end

function META:DisableShadows()
	self.CastShadows = false
	self.ShadowMap = nil
end

function META:HasShadows()
	return self.CastShadows and self.ShadowMap ~= nil
end

function META:UpdateShadowMap()
	if not self.ShadowMap then return end

	self.ShadowMap:UpdateCascadeLightMatrices(self.Rotation)
end

-- Render shadow maps for this light, drawing all model components
function META:RenderShadows()
	if not self:HasShadows() then return end

	local shadow_map = self.ShadowMap
	self:UpdateShadowMap()

	for cascade_idx = 1, shadow_map:GetCascadeCount() do
		local shadow_cmd = shadow_map:Begin(cascade_idx)
		Model.DrawAllShadows(shadow_cmd, shadow_map, cascade_idx)
		shadow_map:End(cascade_idx)
	end
end

function META:UpdateShadowUBO()
	if not self:HasShadows() then return end

	local shadow_map = self.ShadowMap
	local cascade_count = shadow_map:GetCascadeCount()

	-- Copy all cascade light space matrices
	for i = 1, cascade_count do
		local matrix_data = shadow_map:GetLightSpaceMatrix(i):GetFloatCopy()
		ffi.copy(render3d.light_ubo_data.shadow.light_space_matrices[i - 1], matrix_data, ffi.sizeof("float") * 16)
	end

	-- Copy cascade splits
	local cascade_splits = shadow_map:GetCascadeSplits()

	for i = 1, 4 do
		render3d.light_ubo_data.shadow.cascade_splits[i - 1] = cascade_splits[i] or 0
	end

	render3d.light_ubo_data.shadow.cascade_count = cascade_count
end

function META:GetGPUData()
	local data = render3d.LightData()

	if self.LightType == META.TYPE_DIRECTIONAL then
		local dir = self.Rotation:GetForward()
		data.position[0] = dir.x
		data.position[1] = dir.y
		data.position[2] = dir.z
	else
		local pos = self:GetPosition()
		data.position[0] = pos.x
		data.position[1] = pos.y
		data.position[2] = pos.z
	end

	data.position[3] = self.LightType
	data.color[0] = self.Color[1]
	data.color[1] = self.Color[2]
	data.color[2] = self.Color[3]
	data.color[3] = self.Intensity
	data.params[0] = self.Range
	data.params[1] = self.InnerCone
	data.params[2] = self.OuterCone
	data.params[3] = 0
	return data
end

META:Register()
ecs.RegisterComponent(META)
-----------------------------------------------------------
-- Static helpers for scene light management
-----------------------------------------------------------
local Light = {}
Light.Component = META
-- Re-export constants
Light.TYPE_DIRECTIONAL = META.TYPE_DIRECTIONAL
Light.TYPE_POINT = META.TYPE_POINT
Light.TYPE_SPOT = META.TYPE_SPOT

-- Create a directional light entity
function Light.CreateDirectional(config)
	config = config or {}
	config.type = META.TYPE_DIRECTIONAL
	local entity = ecs.CreateEntity(config.name or "directional_light")
	entity:AddComponent("transform")
	local light = entity:AddComponent("light", config)
	return light, entity
end

-- Create a point light entity
function Light.CreatePoint(config)
	config = config or {}
	config.type = META.TYPE_POINT
	local entity = ecs.CreateEntity(config.name or "point_light")
	entity:AddComponent("transform", {position = config.position})
	local light = entity:AddComponent("light", config)
	return light, entity
end

-- Create a spot light entity
function Light.CreateSpot(config)
	config = config or {}
	config.type = META.TYPE_SPOT
	local entity = ecs.CreateEntity(config.name or "spot_light")
	entity:AddComponent("transform", {position = config.position})
	local light = entity:AddComponent("light", config)
	return light, entity
end

-- Get all light components in the scene
function Light.GetSceneLights()
	return ecs.GetComponents("light")
end

-- Get enabled lights
function Light.GetEnabledLights()
	local lights = Light.GetSceneLights()
	local enabled = {}

	for _, light in ipairs(lights) do
		if light.Enabled then table.insert(enabled, light) end
	end

	return enabled
end

-- Find primary directional light (for sun/shadows)
function Light.GetPrimaryDirectional()
	local lights = Light.GetSceneLights()

	for _, light in ipairs(lights) do
		if light.Enabled and light.LightType == META.TYPE_DIRECTIONAL then
			return light
		end
	end

	return nil
end

return Light
