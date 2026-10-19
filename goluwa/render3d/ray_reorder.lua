local render = import("goluwa/render/render.lua")
local ray_reorder = {}

function ray_reorder.IsSupported()
	return render.GetDevice().ray_reorder ~= nil
end

-- the `ray_generation` config of a compute pass that is built as a ray generation shader instead, where threads can be
-- reordered. the functions of the extension the device has are defined as SER_<name> (hitObject, hitObjectTraceRay,
-- reorderThread, ...), `declarations` and `anyhit` are added to the shader and to the any hit shader of the pipeline
function ray_reorder.GetRayGeneration(config)
	local vendor = render.GetDevice().ray_reorder:upper()
	local names = {}

	for _, name in ipairs({
		"hitObject",
		"hitObjectTraceRay",
		"reorderThread",
		"hitObjectIsHit",
		"hitObjectGetRayTMax",
		"hitObjectGetInstanceCustomIndex",
		"hitObjectGetPrimitiveIndex",
		"hitObjectGetAttributes",
		"hitObjectAttribute",
	}) do
		names[#names + 1] = "#define SER_" .. name .. " " .. name .. vendor
	end

	return {
		extension = "#extension GL_" .. vendor .. "_shader_invocation_reorder : require",
		declarations = table.concat(names, "\n") .. "\n" .. (config.declarations or ""),
		anyhit = config.anyhit,
	}
end

return ray_reorder
