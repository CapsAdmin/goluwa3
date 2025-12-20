local ffi = require("ffi")
local Vec3 = require("structs.vec3")
local Quat = require("structs.quat")
local Light = {}
Light.__index = Light
-- Light types
Light.TYPE_DIRECTIONAL = 0
Light.TYPE_POINT = 1
Light.TYPE_SPOT = 2
-- Maximum lights that can be passed in push constants
-- We're limited by push constant size (128 bytes typical minimum)
-- Each light needs: type(4) + position/direction(16) + color(16) + params(16) = 52 bytes
-- For push constants we'll keep it simple with 4 lights max
Light.MAX_LIGHTS = 4
-- Light data structure for GPU (matches shader layout)
local LightData = ffi.typeof([[
	struct {
		float position[4];      // xyz = position/direction, w = type (0=dir, 1=point, 2=spot)
		float color[4];         // rgb = color, a = intensity
		float params[4];        // x = range, y = inner_cone, z = outer_cone, w = unused
	}
]])
-- Scene lights collection
local scene_lights = {}
local ambient_color = {0.03, 0.03, 0.03}
-- The sun (primary directional light with shadows)
local sun = nil

function Light.New(config)
	config = config or {}
	local self = setmetatable({}, Light)
	self.type = config.type or Light.TYPE_DIRECTIONAL
	self.position = config.position or Vec3(0, 0, 0)
	self.rotation = config.rotation or Quat(0, 0, 0, 1) --:SetForward(Vec3(0, -1, 0))
	self.color = config.color or {1.0, 1.0, 1.0}
	self.intensity = config.intensity or 1.0
	self.range = config.range or 10.0
	self.inner_cone = config.inner_cone or 0.9 -- cos(angle) for spot lights
	self.outer_cone = config.outer_cone or 0.8
	self.enabled = config.enabled ~= false
	self.name = config.name or "unnamed"
	self.cast_shadows = config.cast_shadows or false
	self.shadow_map = nil
	return self
end

function Light:SetPosition(pos)
	self.position = pos
end

function Light:SetRotation(rotation)
	self.rotation = rotation
end

function Light:GetRotation()
	return self.rotation
end

function Light:GetDirection()
	return self.rotation:GetForward()
end

function Light:GetColor()
	return {r = self.color[1], g = self.color[2], b = self.color[3]}
end

function Light:GetIntensity()
	return self.intensity
end

function Light:SetColor(r, g, b)
	self.color = {r, g, b}
end

function Light:SetIntensity(intensity)
	self.intensity = intensity
end

function Light:SetRange(range)
	self.range = range
end

function Light:SetEnabled(enabled)
	self.enabled = enabled
end

function Light:EnableShadows(config)
	local ShadowMap = require("graphics.shadow_map")
	config = config or {}
	self.cast_shadows = true

	if self.type == Light.TYPE_DIRECTIONAL then
		self.shadow_map = ShadowMap.New(
			{
				size = config.size,
				ortho_size = config.ortho_size or 50.0,
				near_plane = config.near_plane or 1.0,
				far_plane = config.far_plane or 200.0,
			}
		)
	elseif self.type == Light.TYPE_POINT then
		-- Point light shadows would need cubemap - not implemented yet
		print("Warning: Point light shadows not yet implemented")
		self.cast_shadows = false
	end
end

function Light:DisableShadows()
	self.cast_shadows = false
	self.shadow_map = nil
end

function Light:GetShadowMap()
	return self.shadow_map
end

function Light:HasShadows()
	return self.cast_shadows and self.shadow_map ~= nil
end

-- Update shadow map matrices for directional/sun light
-- For cascaded shadow maps, pass the view_camera to calculate frustum-based cascades
-- For legacy single shadow map, pass camera_position and camera_angles
function Light:UpdateShadowMap()
	if not self.shadow_map then return end

	self.shadow_map:UpdateCascadeLightMatrices(self.rotation)
end

-- Get light data packed for GPU
function Light:GetGPUData()
	local data = LightData()

	if self.type == Light.TYPE_DIRECTIONAL then
		-- For directional lights, store normalized direction
		local dir = self.rotation:GetForward()
		data.position[0] = dir.x
		data.position[1] = dir.y
		data.position[2] = dir.z
	else
		-- For point/spot lights, store position
		data.position[0] = self.position.x
		data.position[1] = self.position.y
		data.position[2] = self.position.z
	end

	data.position[3] = self.type
	data.color[0] = self.color[1]
	data.color[1] = self.color[2]
	data.color[2] = self.color[3]
	data.color[3] = self.intensity
	data.params[0] = self.range
	data.params[1] = self.inner_cone
	data.params[2] = self.outer_cone
	data.params[3] = 0
	return data
end

-- Create a directional light
function Light.CreateDirectional(config)
	config = config or {}
	config.type = Light.TYPE_DIRECTIONAL
	return Light.New(config)
end

-- Create a point light
function Light.CreatePoint(config)
	config = config or {}
	config.type = Light.TYPE_POINT
	return Light.New(config)
end

-- Create a spot light
function Light.CreateSpot(config)
	config = config or {}
	config.type = Light.TYPE_SPOT
	return Light.New(config)
end

-- Scene light management
function Light.AddToScene(light)
	table.insert(scene_lights, light)
	return light
end

function Light.RemoveFromScene(light)
	for i, l in ipairs(scene_lights) do
		if l == light then
			table.remove(scene_lights, i)
			return true
		end
	end

	return false
end

function Light.ClearScene()
	scene_lights = {}
	sun = nil
end

function Light.GetSceneLights()
	return scene_lights
end

function Light.GetEnabledLights()
	local enabled = {}

	for _, light in ipairs(scene_lights) do
		if light.enabled then
			table.insert(enabled, light)

			if #enabled >= Light.MAX_LIGHTS then break end
		end
	end

	return enabled
end

function Light.SetAmbientColor(r, g, b)
	ambient_color = {r, g, b}
end

function Light.GetAmbientColor()
	return ambient_color
end

-- Set the sun (primary directional light with shadows)
function Light.SetSun(light)
	if light and light.type ~= Light.TYPE_DIRECTIONAL then
		error("Sun must be a directional light")
	end

	sun = light

	if light and not light.shadow_map then light:EnableShadows() end
end

-- Get the sun
function Light.GetSun()
	return sun
end

-- Get the primary directional light (sun) for shadow mapping
function Light.GetPrimaryDirectional()
	if sun then return sun end

	for _, light in ipairs(scene_lights) do
		if light.enabled and light.type == Light.TYPE_DIRECTIONAL then
			return light
		end
	end

	return nil
end

-- Create GPU-ready array of light data
function Light.GetSceneLightData()
	local lights = Light.GetEnabledLights()
	local data = ffi.new(
		"struct { float position[4]; float color[4]; float params[4]; }[?]",
		Light.MAX_LIGHTS
	)

	for i = 1, Light.MAX_LIGHTS do
		local light = lights[i]

		if light then
			local gpu_data = light:GetGPUData()
			ffi.copy(data[i - 1], gpu_data, ffi.sizeof(LightData))
		else
			-- Zero out unused light slots
			for j = 0, 3 do
				data[i - 1].position[j] = 0
				data[i - 1].color[j] = 0
				data[i - 1].params[j] = 0
			end
		end
	end

	return data, #lights
end

return Light
