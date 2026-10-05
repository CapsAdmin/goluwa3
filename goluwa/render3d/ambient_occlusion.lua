local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ambient_occlusion = library()
ambient_occlusion.DEBUG_AO = 1
ambient_occlusion.DEBUG_BOUNCE = 2
ambient_occlusion.DEBUG_BENT_NORMAL = 3
pvars.StartGroup("ambient_occlusion", {store = false})
local gi = pvars.Setup2{
	key = "ambient_occlusion_gi",
	default = true,
	help = "gather bounce light from the previous frame along the horizon search and bend the gi lookup towards the open side",
}
local gi_strength = pvars.Setup2{
	key = "ambient_occlusion_gi_strength",
	default = 1.0,
	min = 0,
	max = 4,
	help = "scale of the screen space bounce light",
}
local debug_view = pvars.Setup2{
	key = "ambient_occlusion_debug",
	default = 0,
	integer = true,
	min = 0,
	max = 3,
	help = "show only one output of the pass: 1 occlusion, 2 bounce light, 3 bent normal",
}
pvars.EndGroup()

function ambient_occlusion.IsGIEnabled()
	return gi:Get()
end

function ambient_occlusion.GetGIStrength()
	return gi_strength:Get()
end

function ambient_occlusion.GetDebugView()
	return debug_view:Get()
end

function ambient_occlusion.GetBentNormalTexture()
	if not gi:Get() or not render3d.IsPassEnabled("ambient_occlusion") then return nil end

	return render3d.pipelines.ambient_occlusion_blur:GetFramebuffer(1):GetAttachment(2)
end

return ambient_occlusion
