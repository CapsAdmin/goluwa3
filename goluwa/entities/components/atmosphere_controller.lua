local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local weather = import("goluwa/render3d/weather.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local water = import("goluwa/render3d/water.lua")
local META = objects.CreateTemplate("atmosphere_controller")
META.Singleton = true

local function copy_ocean_settings()
	local out = {}

	for key, value in pairs(water.GetOcean()) do
		local kind = typex(value)

		if kind == "number" or kind == "boolean" or kind == "string" then
			out[key] = value
		elseif kind == "vec3" or kind == "color" then
			out[key] = value:Copy()
		end
	end

	return out
end

local default_visibility = atmosphere.GetVisibility()
local default_ocean_enabled = render3d.IsOceanEnabled()
local default_ocean_settings = copy_ocean_settings()
local default_environment_map_intensity = atmosphere.GetEnvironmentMapIntensity()
META:StartStorable()
META:GetSet("SunRotation", nil, {type = "quat"})
META:GetSet("Visibility", default_visibility)
META:GetSet("FogColor", nil, {type = "vec3"})
META:GetSet("OceanEnabled", default_ocean_enabled)
META:GetSet("OceanLevel", nil, {type = "number"})
META:GetSet("OceanSettings", default_ocean_settings)
META:GetSet("EnvironmentMap", nil, {type = "string"})
META:GetSet("EnvironmentMapIntensity", default_environment_map_intensity)
META:EndStorable()

function META:Initialize()
	event.AddListener("OnTransformChanged", self, function(transform)
		if transform ~= self.Owner.transform then return end

		local direction = transform:GetRotation():GetNormalized():GetBackward()

		if direction:GetDot(weather.GetSunDirection()) > 1 - 1e-6 then return end

		weather.SetSunDirection(direction)
	end)
end

function META:OnRemove()
	event.RemoveListener("OnTransformChanged", self)
end

function META:GetSunRotation()
	return weather.GetSunRotation()
end

function META:SetSunRotation(rotation)
	weather.SetSunRotation(rotation:GetNormalized())
end

function META:SetSunDirection(direction)
	weather.SetSunDirection(direction)
end

function META:GetVisibility()
	return atmosphere.GetVisibility()
end

function META:SetVisibility(meters)
	weather.SetVisibility(meters)
end

function META:GetFogColor()
	return atmosphere.fog_color
end

function META:SetFogColor(color)
	atmosphere.SetFogColor(color)
end

function META:GetOceanEnabled()
	return render3d.IsOceanEnabled()
end

function META:SetOceanEnabled(enabled)
	render3d.SetOceanEnabled(enabled)
end

function META:GetOceanLevel()
	return render3d.GetOceanLevelOverride()
end

function META:SetOceanLevel(level)
	render3d.SetOceanLevel(level)
end

function META:GetOceanSettings()
	return copy_ocean_settings()
end

function META:SetOceanSettings(settings)
	water.SetOcean(settings)
end

function META:GetEnvironmentMap()
	return weather.GetEnvironmentMap()
end

function META:SetEnvironmentMap(path)
	weather.SetEnvironmentMap(path)
end

function META:GetEnvironmentMapIntensity()
	return weather.GetEnvironmentMapIntensity()
end

function META:SetEnvironmentMapIntensity(intensity)
	weather.SetEnvironmentMapIntensity(intensity)
end

function META:OnDeserialized()
	weather.UpdateSky()
end

function META:ResetProperties()
	self:SetVisibility(default_visibility)
	self:SetFogColor(nil)
	self:SetOceanEnabled(default_ocean_enabled)
	self:SetOceanLevel(nil)
	self:SetOceanSettings(default_ocean_settings)
	self:SetEnvironmentMap(nil)
	self:SetEnvironmentMapIntensity(default_environment_map_intensity)
end

return META:Register()
