local RenderModelPreview = import("goluwa/render3d/model_preview.lua")
local model_preview = library()

function model_preview.New(config)
	return RenderModelPreview.New(config)
end

function model_preview.RenderEntity(entity, config)
	local preview = model_preview.New(config)
	preview:RenderEntity(entity)
	return preview
end

return model_preview
