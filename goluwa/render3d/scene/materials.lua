local materials = {}
-- a material row is the index of the material in this list. consumers build their own per material records from it
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

return materials
