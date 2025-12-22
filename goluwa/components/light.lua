local ffi = require("ffi")
local prototype = require("prototype")
local ecs = require("ecs")
local render = require("render.render")
local Vec3 = require("structs.vec3")
local Quat = require("structs.quat")
local ShadowMap = require("render3d.shadow_map")
require("components.transform")
local ShadowUBO = ffi.typeof([[
	struct {
		float light_space_matrices[4][16];
		float cascade_splits[4];
		int shadow_map_indices[4];
		int cascade_count;
		float _pad[3];
	}
]])
local LightData = ffi.typeof([[
	struct {
		float position[4];
		float color[4];
		float params[4];
	}
]])
local LightUBO = ffi.typeof([[
	struct {
		$ shadow;
		$ lights[32];
	}
]], ShadowUBO, LightData)
local Light = {}
-- Light types
Light.TYPE_DIRECTIONAL = 0
Light.TYPE_POINT = 1
Light.TYPE_SPOT = 2
local META = prototype.CreateTemplate("component", "light")
META.ComponentName = "light"
-- Light requires transform component
META.Require = {"transform"}
META.Events = {"PreFrame"} -- Subscribe to PreFrame for shadow rendering
-- Light types
META.TYPE_DIRECTIONAL = Light.TYPE_DIRECTIONAL
META.TYPE_POINT = Light.TYPE_POINT
META.TYPE_SPOT = Light.TYPE_SPOT
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

local Model = nil

function META:RenderShadows()
	Model = Model or require("components.model")

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

	Light.Initialize()
	local shadow_map = self.ShadowMap
	local cascade_count = shadow_map:GetCascadeCount()

	-- Copy all cascade light space matrices
	for i = 1, cascade_count do
		local matrix_data = shadow_map:GetLightSpaceMatrix(i):GetFloatCopy()
		ffi.copy(Light.ubo_data.shadow.light_space_matrices[i - 1], matrix_data, ffi.sizeof("float") * 16)
	end

	-- Copy cascade splits
	local cascade_splits = shadow_map:GetCascadeSplits()

	for i = 1, 4 do
		Light.ubo_data.shadow.cascade_splits[i - 1] = cascade_splits[i] or 0
	end

	Light.ubo_data.shadow.cascade_count = cascade_count
end

function META:GetGPUData()
	local data = LightData()

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
Light.Component = META
Light.lights = {}
Light.ubo = nil
Light.ubo_data = nil

function Light.Initialize()
	if Light.ubo then return end

	Light.ubo_data = LightUBO()

	-- Initialize with identity matrices for all cascades
	for cascade = 0, 3 do
		for i = 0, 15 do
			Light.ubo_data.shadow.light_space_matrices[cascade][i] = (i % 5 == 0) and 1.0 or 0.0
		end

		Light.ubo_data.shadow.shadow_map_indices[cascade] = -1
	end

	Light.ubo = render.CreateBuffer(
		{
			data = Light.ubo_data,
			byte_size = ffi.sizeof(LightUBO),
			buffer_usage = {"uniform_buffer"},
			memory_property = {"host_visible", "host_coherent"},
		}
	)
end

function Light.GetUBO()
	if not Light.ubo then Light.Initialize() end

	return Light.ubo
end

function Light.SetLights(lights)
	Light.lights = lights
end

function Light.GetLights()
	return Light.lights
end

function Light.UpdateUBOs(pipeline)
	if not Light.ubo then Light.Initialize() end

	-- Update light UBO
	local count = math.min(#Light.lights, 32)
	local sun_light = nil

	for i = 1, count do
		local light = Light.lights[i]
		Light.ubo_data.lights[i - 1] = light:GetGPUData()

		if light.IsSun and light:HasShadows() then sun_light = light end
	end

	if sun_light then
		local shadow_map = sun_light:GetShadowMap()
		local cascade_count = shadow_map:GetCascadeCount()

		for i = 1, cascade_count do
			Light.ubo_data.shadow.shadow_map_indices[i - 1] = pipeline:RegisterTexture(shadow_map:GetDepthTexture(i))
		end

		-- Fill remaining slots with -1
		for i = cascade_count + 1, 4 do
			Light.ubo_data.shadow.shadow_map_indices[i - 1] = -1
		end
	else
		for i = 0, 3 do
			Light.ubo_data.shadow.shadow_map_indices[i] = -1
		end
	end

	Light.ubo:CopyData(Light.ubo_data, ffi.sizeof(LightUBO))
end

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
