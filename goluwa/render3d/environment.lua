local objects = import("goluwa/objects/objects.lua")
local Texture = import("goluwa/render/texture.lua")
local envprobe = import("goluwa/render3d/envprobe.lua")
local META = objects.CreateTemplate("render3d_environment")
local SAMPLER = {
	min_filter = "linear",
	mag_filter = "linear",
	wrap_s = "repeat",
	wrap_t = "clamp_to_edge",
}
local cache = {}
META:GetSet("Path", nil, {callback = "OnPathChanged"})
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

function META:OnPathChanged()
	if self.source then self.source:Remove() end

	self.source = self.Path and
		Texture.New{
			path = self.Path,
			sampler = SAMPLER,
			on_ready = function()
				self:Invalidate()
			end,
		} or
		nil
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

function META:Bake(cmd)
	if not self.needs_bake then return self.baked end

	if self.source and not self.source:IsReady() then return false end

	envprobe.BakeProbe(cmd, self.probe)
	self.needs_bake = false
	self.baked = true
	self.version = self.version + 1
	return true
end

META:Register()
return META
