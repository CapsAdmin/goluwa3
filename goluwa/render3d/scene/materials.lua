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
		return multiplier.r * multiplier.a, multiplier.g * multiplier.a, multiplier.b * multiplier.a
	end

	return 0, 0, 0
end

return materials
