local model_transform_utils = {}

function model_transform_utils.GetModelTransforms(model)
	if model.WorldSpaceVertices then return nil, nil end

	local transform = model.Owner and model.Owner.transform or nil

	if not transform then return nil, nil end

	return transform:GetWorldMatrixInverse(), transform:GetWorldMatrix()
end

return model_transform_utils
