local base = import("goluwa/render/easy_pipeline_base.lua")
local EasyPipelineGraphics = import("goluwa/render/easy_pipeline_graphics.lua")
local EasyPipelineCompute = import("goluwa/render/easy_pipeline_compute.lua")

local EasyPipeline = base.EasyPipeline

function EasyPipeline.New(config)
	if config.ComputePass or config.compute_pass then
		return EasyPipelineCompute.ComputePass(config)
	end

	return EasyPipelineGraphics.New(config)
end

EasyPipeline.Compute = EasyPipelineCompute.Compute
EasyPipeline.ComputePass = EasyPipelineCompute.ComputePass
return EasyPipeline:Register()
