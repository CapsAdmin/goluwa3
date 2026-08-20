local model_transform_utils = {}

function model_transform_utils.GetModelPrimitives(model)
	if not model then return nil end

	if model.GetPhysicsPrimitives then return model:GetPhysicsPrimitives() end

	return model.Primitives
end

function model_transform_utils.GetModelTransforms(model)
	if model.WorldSpaceVertices then return nil, nil end

	local transform = model.Owner and model.Owner.transform or nil

	if not transform then return nil, nil end

	return transform:GetWorldMatrixInverse(), transform:GetWorldMatrix()
end

return model_transform_utils
