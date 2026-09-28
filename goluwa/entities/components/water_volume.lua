--[[
	A box of water. The entity's transform places the middle of the water
	surface, Size is the box's width, depth and length, so the water fills from
	the surface down to Size.y below it. Rotate it only around y.

	Absorption and Scattering are per meter for red, green and blue; take them
	from water.presets or measure your own. WaveHeight is the significant
	height of the ripples in meters (0 for a mirror), WaveLength the length of
	the longest ones. Flow moves the ripples along, for rivers and streams.
]]
local objects = import("goluwa/objects/objects.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local water = import("goluwa/render3d/water.lua")
local WaterVolume = objects.CreateTemplate("water_volume")
WaterVolume:StartStorable()
WaterVolume:GetSet("Size", Vec3(10, 3, 10))
WaterVolume:GetSet("Absorption", water.presets.lake.Absorption:Copy())
WaterVolume:GetSet("Scattering", water.presets.lake.Scattering:Copy())
WaterVolume:GetSet("IOR", 1.333, {validate = "number"})
WaterVolume:GetSet("WaveHeight", 0.02, {validate = "number"})
WaterVolume:GetSet("WaveLength", 1.2, {validate = "number"})
-- degrees, 0 is +x, 90 is +z
WaterVolume:GetSet("WindDirection", 30, {validate = "number"})
-- m/s over the surface
WaterVolume:GetSet("Flow", Vec2(0, 0))
-- microscopic roughness on top of the ripples, dust and film on the surface
WaterVolume:GetSet("Roughness", 0.015, {validate = "number"})
-- foam where the water is shallow along the shore and around objects
WaterVolume:GetSet("Foam", 0.4, {validate = "number"})
WaterVolume:GetSet("Caustics", 1, {validate = "number"})
WaterVolume:EndStorable()

function WaterVolume:SetPreset(name)
	local preset = water.presets[name]

	if not preset then error("unknown water preset " .. tostring(name), 2) end

	self:SetAbsorption(preset.Absorption:Copy())
	self:SetScattering(preset.Scattering:Copy())
end

function WaterVolume:OnCreate()
	water.AddVolume(self)
end

function WaterVolume:OnRemove()
	water.RemoveVolume(self)
end

return WaterVolume:Register()
