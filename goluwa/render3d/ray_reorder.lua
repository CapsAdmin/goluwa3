local render = import("goluwa/render/render.lua")
local ray_reorder = {}

function ray_reorder.IsSupported()
	return render.GetDevice().ray_reorder ~= nil
end

function ray_reorder.GetRayGeneration(config)
	local vendor = render.GetDevice().ray_reorder:upper()
	local names = {}

	for _, name in ipairs{
		"hitObject",
		"hitObjectTraceRay",
		"reorderThread",
		"hitObjectIsHit",
		"hitObjectGetRayTMax",
		"hitObjectGetInstanceCustomIndex",
		"hitObjectGetPrimitiveIndex",
		"hitObjectGetAttributes",
		"hitObjectAttribute",
	} do
		names[#names + 1] = "#define SER_" .. name .. " " .. name .. vendor
	end

	return {
		extension = "#extension GL_" .. vendor .. "_shader_invocation_reorder : require",
		declarations = table.concat(names, "\n") .. "\n" .. (config.declarations or ""),
		anyhit = config.anyhit,
	}
end

return ray_reorder
