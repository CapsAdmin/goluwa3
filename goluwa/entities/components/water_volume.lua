local objects = import("goluwa/objects/objects.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local water = import("goluwa/render3d/water.lua")
local fluid = import("goluwa/physics/fluid.lua")
local WaterVolume = objects.CreateTemplate("water_volume")
WaterVolume:StartStorable()
WaterVolume:GetSet("Size", Vec3(10, 3, 10))
WaterVolume:GetSet("Absorption", water.presets.lake.Absorption:Copy())
WaterVolume:GetSet("ParticleScattering", water.presets.lake.ParticleScattering:Copy())
WaterVolume:GetSet("IOR", 1.333, {validate = "number"})
WaterVolume:GetSet("AbbeNumber", water.ABBE_NUMBER, {validate = "number"})
WaterVolume:GetSet("WaveHeight", 0.02, {validate = "number"})
WaterVolume:GetSet("WaveLength", 1.2, {validate = "number"})
WaterVolume:GetSet("WindDirection", 30, {validate = "number"})
WaterVolume:GetSet("Density", 1000, {validate = "number"})
WaterVolume:GetSet("Flow", Vec2(0, 0))
WaterVolume:GetSet("Roughness", 0.015, {validate = "number"})
WaterVolume:GetSet("Foam", 0.4, {validate = "number"})
WaterVolume:GetSet("Caustics", 1, {validate = "number"})
WaterVolume:GetSet("Visible", true)
WaterVolume:EndStorable()

function WaterVolume:SetPreset(name)
	local preset = water.presets[name]

	if not preset then error("unknown water preset " .. tostring(name), 2) end

	self:SetAbsorption(preset.Absorption:Copy())
	self:SetParticleScattering(preset.ParticleScattering:Copy())
end

function WaterVolume:OnCreate()
	fluid.AddVolume(self)

	if self.Visible then water.AddVolume(self) end
end

function WaterVolume:SetVisible(visible)
	if self.Visible == visible then return end

	objects.CommitProperty(self, "Visible", visible)

	if visible then water.AddVolume(self) else water.RemoveVolume(self) end
end

function WaterVolume:OnRemove()
	fluid.RemoveVolume(self)
	water.RemoveVolume(self)
end

return WaterVolume:Register()
