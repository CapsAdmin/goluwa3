local foot_surfaces = {}
local NONE = {}
local MODELS = {
	["models/player/eli.mdl"] = {foot_l = "metal", ["ValveBiped.Bip01_L_Foot"] = "metal"},
	["models/characters/eli/eli.vmdl_c"] = {foot_l = "metal", ankle_L = "metal"},
}

local function find_model(entity, depth)
	if entity.source_pose and entity.model then return entity.model.ModelPath end

	if depth == 0 then return end

	for _, child in ipairs(entity:GetChildren()) do
		local path = find_model(child, depth - 1)

		if path then return path end
	end
end

function foot_surfaces.Get(character)
	return MODELS[find_model(character, 3)] or NONE
end

return foot_surfaces
