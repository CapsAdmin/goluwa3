local objects = import("goluwa/objects/objects.lua")
local Texture = import("goluwa/render/texture.lua")
local envprobe = import("goluwa/render3d/envprobe.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("render3d_environment")
local SAMPLER = {
	min_filter = "linear",
	mag_filter = "linear",
	wrap_s = "repeat",
	wrap_t = "clamp_to_edge",
}
local MAP_WIDTH = 2048
-- the atmosphere modules in render3d/atmospheres all define get_atmosphere(dir, sun_dir, cam_pos),
-- this renders it into an equirect the same way an hdr file is laid out, the top row is up
local SHADER_WRAPPER = [[

	vec4 shade(vec2 uv, vec3 _cube_dir) {
		float phi = (uv.x - 0.5) * 6.28318530718;
		float theta = (0.5 - uv.y) * 3.14159265359;
		vec3 dir = vec3(cos(theta) * cos(phi), sin(theta), cos(theta) * sin(phi));
		vec3 sun = normalize(vec3(%.6f, %.6f, %.6f));
		float ground = %.6f;
		vec3 color = get_atmosphere(dir, sun, vec3(0.0));

		// a sky has no ground, the albedo given here lights one by the sky along the horizon and overhead
		if (ground > 0.0 && dir.y < 0.0) {
			vec3 horizon = get_atmosphere(normalize(vec3(dir.x, 0.0, dir.z)), sun, vec3(0.0));
			vec3 overhead = get_atmosphere(vec3(0.0, 1.0, 0.0), sun, vec3(0.0));
			color = mix(horizon, ground * 0.5 * (horizon + overhead), smoothstep(0.0, -0.08, dir.y));
		}

		if (any(isnan(color)) || any(isinf(color))) color = vec3(0.0);

		return vec4(max(color, vec3(0.0)), 1.0);
	}
]]
local cache = {}
local preset_cache = {}
META:GetSet("Path", nil, {callback = "OnSourceChanged"})
META:GetSet("Shader", nil, {callback = "OnSourceChanged"})
META:GetSet("SunElevation", 45, {callback = "OnSourceChanged"})
META:GetSet("SunAzimuth", 0, {callback = "OnSourceChanged"})
META:GetSet("Ground", 0, {callback = "OnSourceChanged"})
META:GetSet("Intensity", 1000, {callback = "Invalidate"})
META:GetSet("Size", 256, {callback = "OnSizeChanged"})

function META.New(config)
	local self = META:CreateObject()
	self.version = 0
	self.needs_bake = true
	self.baked = false

	if config then
		for k, v in pairs(config) do
			self["Set" .. k](self, v)
		end
	end

	self.probe = self.probe or envprobe.CreateProbe(self.Size)
	self.probe.environment = self
	return self
end

function META.GetShared(path)
	local key = path or false
	local environment = cache[key]

	if environment and environment:IsValid() then return environment end

	environment = META.New{Path = path}
	cache[key] = environment
	return environment
end

function META:OnSourceChanged()
	if self.source then
		self.source:Remove()
		self.source = nil
	end

	if self.Path then
		self.source = Texture.New{
			path = self.Path,
			sampler = SAMPLER,
			on_ready = function()
				self:Invalidate()
			end,
		}
	end

	self:Invalidate()
end

function META:OnSizeChanged()
	if not self.probe then return end

	envprobe.RemoveProbe(self.probe)
	self.probe = envprobe.CreateProbe(self.Size)
	self.probe.environment = self
	self.baked = false
	self:Invalidate()
end

function META:Invalidate()
	self.needs_bake = true
end

function META:OnRemove()
	if self.source then self.source:Remove() end

	envprobe.RemoveProbe(self.probe)
	self.probe = nil
end

function META:GetSourceTexture()
	return self.source
end

function META:GetSpecularTexture()
	return self.probe.color_equirect
end

function META:GetIrradianceTexture()
	return self.probe.irradiance_equirect
end

-- the exposure that shows a map value of 1 as white
function META:GetExposure()
	return 1 / self.Intensity
end

function META:GetVersion()
	return self.version
end

function META:IsReady()
	return self.baked
end

function META:GetSunDirection()
	local elevation = math.rad(self.SunElevation)
	local azimuth = math.rad(self.SunAzimuth)
	return Vec3(
		math.cos(elevation) * math.cos(azimuth),
		math.sin(elevation),
		math.cos(elevation) * math.sin(azimuth)
	)
end

function META:GenerateShaderMap()
	local sun = self:GetSunDirection()
	local texture = Texture.New{
		width = MAP_WIDTH,
		height = MAP_WIDTH / 2,
		format = "r16g16b16a16_sfloat",
		mip_map_levels = 1,
		sampler = SAMPLER,
	}
	texture:Shade(self.Shader .. SHADER_WRAPPER:format(sun.x, sun.y, sun.z, self.Ground))
	texture:MakeReady()
	self.source = texture
end

function META:Bake(cmd)
	if not self.needs_bake then return self.baked end

	if self.Shader and not self.source then self:GenerateShaderMap() end

	if self.source and not self.source:IsReady() then return self.baked end

	envprobe.BakeProbe(cmd, self.probe)
	self.needs_bake = false
	self.baked = true
	self.version = self.version + 1
	return true
end

-- what a viewer offers to pick from. the ones with a Shader are rendered from the modules in
-- render3d/atmospheres, whose values are around 1 by day, so their Intensity is 1 and the dusk's
-- is lower to bring up its sky
META.presets = {
	{Name = "Studio"},
	{
		Name = "Nishita midday",
		Shader = "goluwa/render3d/atmospheres/nishita.lua",
		SunElevation = 60,
		SunAzimuth = 50,
		Ground = 0.3,
		Intensity = 1,
	},
	{
		Name = "Nishita afternoon",
		Shader = "goluwa/render3d/atmospheres/nishita.lua",
		SunElevation = 25,
		SunAzimuth = 50,
		Ground = 0.3,
		Intensity = 1,
	},
	{
		Name = "Nishita sunset",
		Shader = "goluwa/render3d/atmospheres/nishita.lua",
		SunElevation = 3,
		SunAzimuth = 50,
		Ground = 0.3,
		Intensity = 1,
	},
	{
		Name = "Nishita dusk",
		Shader = "goluwa/render3d/atmospheres/nishita.lua",
		SunElevation = -2,
		SunAzimuth = 50,
		Ground = 0.3,
		Intensity = 0.1,
	},
	{
		Name = "Temple",
		Shader = "goluwa/render3d/atmospheres/temple.lua",
		Intensity = 1,
	},
}

function META.GetPresetNames()
	local names = {}

	for i, preset in ipairs(META.presets) do
		names[i] = preset.Name
	end

	return names
end

function META.GetPreset(name)
	local environment = preset_cache[name]

	if environment and environment:IsValid() then return environment end

	for _, preset in ipairs(META.presets) do
		if preset.Name == name then
			if not (preset.Shader or preset.Path) then return META.GetShared() end

			local config = {}

			for key, value in pairs(preset) do
				config[key] = value
			end

			config.Name = nil

			if config.Shader then config.Shader = import(config.Shader) end

			environment = META.New(config)
			preset_cache[name] = environment
			return environment
		end
	end

	error("no environment preset named " .. tostring(name), 2)
end

META:Register()
return META
