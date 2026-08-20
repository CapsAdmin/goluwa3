local model_transform_utils = {}

function model_transform_utils.GetModelPrimitives(model)
	if not model then return nil end

	if model.GetPhysicsPrimitives then return model:GetPhysicsPrimitives() end

	return model.Primitives
end

function model_transform_utils.GetModelTransforms(model)
	if model.WorldSpaceVertices then return nil, nil end

	local transform = model.Owner.transform
	return transform:GetWorldMatrixInverse(), transform:GetWorldMatrix()
end

return model_transform_utils
