local Color = import("goluwa/structs/color.lua")
local WHITE = Color(1, 1, 1, 1)
local materials = {}
materials.list = {}
materials.ids = {}

function materials.GetID(material)
	local id = materials.ids[material]

	if not id then
		id = #materials.list
		materials.list[id + 1] = material
		materials.ids[material] = id
	end

	return id
end

function materials.GetEmissive(material)
	if
		material:GetAlbedoAlphaIsEmissive() or
		material:GetAdditive() or
		material:GetEmissiveTexture() ~= nil
	then
		local multiplier = material:GetEmissiveMultiplier()
		local masked = material:GetEmissiveTexture() ~= nil or material:GetAlbedoAlphaIsEmissive()
		local mean = masked and material:GetEmissiveMean() or WHITE
		return multiplier.r * multiplier.a * mean.r,
		multiplier.g * multiplier.a * mean.g,
		multiplier.b * multiplier.a * mean.b
	end

	return 0, 0, 0
end

return materials
