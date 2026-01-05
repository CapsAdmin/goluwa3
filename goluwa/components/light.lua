local ffi = require("ffi")
local prototype = require("prototype")
local ecs = require("ecs")
local render = require("render.render")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Quat = require("structs.quat")
local ShadowMap = require("render3d.shadow_map")
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

function META:UpdateShadowUBO()
	if not self:GetCastShadows() then return end

	Light.Initialize()
	local cascade_count = self.ShadowMap:GetCascadeCount()

	-- Copy all cascade light space matrices
	for i = 1, cascade_count do
		local matrix_data = self.ShadowMap:GetLightSpaceMatrix(i):GetFloatCopy()
		ffi.copy(Light.ubo_data.shadow.light_space_matrices[i - 1], matrix_data, ffi.sizeof("float") * 16)
	end

	-- Copy cascade splits
	local cascade_splits = self.ShadowMap:GetCascadeSplits()

	for i = 1, 4 do
		Light.ubo_data.shadow.cascade_splits[i - 1] = cascade_splits[i] or 0
	end

	Light.ubo_data.shadow.cascade_count = cascade_count
end

function META:GetGPUData()
	local data = LightData()

	if self.LightType == "directional" or self.LightType == "sun" then
		self.Entity.transform:GetRotation():GetForward():CopyToFloatPointer(data.position)
	else
		self.Entity.transform:GetPosition():CopyToFloatPointer(data.position)
	end

	if self.LightType == "directional" or self.LightType == "sun" then
		data.position[3] = 0
	elseif self.LightType == "point" then
		data.position[3] = 1
	elseif self.LightType == "spot" then
		data.position[3] = 2
	else
		error("Unknown light type: " .. tostring(self.LightType), 2)
	end

	data.color[0] = self.Color.r
	data.color[1] = self.Color.g
	data.color[2] = self.Color.b
	data.color[3] = self.Intensity
	data.params[0] = self.Range
	data.params[1] = self.InnerCone
	data.params[2] = self.OuterCone
	data.params[3] = 0
	return data
end

META:Register()
ecs.RegisterComponent(META)
Light.Component = META
Light.lights = {}
Light.ubo = nil
Light.ubo_data = nil

function Light.Initialize()
	if Light.ubo then return end

	Light.ubo_data = LightUBO()

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

	local sun = nil

	for i, ent in ipairs(Light.lights) do
		if i > 32 then break end

		Light.ubo_data.lights[i - 1] = ent.light:GetGPUData()

		if
			(
				ent.light.LightType == "sun" or
				ent.light.LightType == "directional"
			)
			and
			ent.light:GetCastShadows()
		then
			sun = ent

			break
		end
	end

	if sun then
		local shadow_map = sun.light:GetShadowMap()
		local cascade_count = shadow_map:GetCascadeCount()

		for i = 1, cascade_count do
			Light.ubo_data.shadow.shadow_map_indices[i - 1] = pipeline:GetTextureIndex(shadow_map:GetDepthTexture(i))
			shadow_map:GetLightSpaceMatrix(i):CopyToFloatPointer(Light.ubo_data.shadow.light_space_matrices[i - 1])
			Light.ubo_data.shadow.cascade_splits[i - 1] = shadow_map:GetCascadeSplits()[i]
		end

		Light.ubo_data.shadow.cascade_count = cascade_count

		-- Fill remaining slots with -1
		for i = cascade_count + 1, 4 do
			Light.ubo_data.shadow.shadow_map_indices[i - 1] = -1
		end
	else
		Light.ubo_data.shadow.cascade_count = 0

		for i = 0, 3 do
			Light.ubo_data.shadow.shadow_map_indices[i] = -1
		end
	end

	Light.ubo:CopyData(Light.ubo_data, ffi.sizeof(LightUBO))
end

return Light
