local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ambient_occlusion = {}
ambient_occlusion.DEBUG_AO = 1
ambient_occlusion.DEBUG_BOUNCE = 2
ambient_occlusion.DEBUG_BENT_NORMAL = 3
pvars.StartGroup("Lighting", "Ambient occlusion", {store = false, prefix = "ambient_occlusion_"})
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
local DEBUG_VIEWS = {
	off = 0,
	occlusion = ambient_occlusion.DEBUG_AO,
	bounce = ambient_occlusion.DEBUG_BOUNCE,
	bent_normal = ambient_occlusion.DEBUG_BENT_NORMAL,
}
local debug_view = pvars.Setup2{
	key = "ambient_occlusion_debug",
	default = "off",
	enums = {"off", "occlusion", "bounce", "bent_normal"},
	help = "show only one output of the pass",
}
pvars.EndGroup()

function ambient_occlusion.IsGIEnabled()
	return gi:Get()
end

function ambient_occlusion.GetGIStrength()
	return gi_strength:Get()
end

function ambient_occlusion.GetDebugView()
	return DEBUG_VIEWS[debug_view:Get()]
end

function ambient_occlusion.GetBentNormalTexture()
	if not gi:Get() or not render3d.IsPassEnabled("ambient_occlusion") then
		return nil
	end

	return render3d.pipelines.ambient_occlusion_blur:GetFramebuffer(1):GetAttachment(2)
end

return ambient_occlusion
