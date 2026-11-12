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
local radius = pvars.Setup2{
	key = "ambient_occlusion_radius",
	default = 2.0,
	help = "world space radius of the occlusion sphere in meters, multiplied by the view scale",
}
local screen_radius = pvars.Setup2{
	key = "ambient_occlusion_screen_radius",
	default = 0.2,
	help = "largest radius of the sampling circle as a fraction of the screen height",
}
local backface_threshold = pvars.Setup2{
	key = "ambient_occlusion_backface_threshold",
	default = 0.5,
	help = "an occluder whose normal points away from the pixel by more than this dot product is treated as a back face",
}
local backface_boost = pvars.Setup2{
	key = "ambient_occlusion_backface_boost",
	default = 0.5,
	help = "how much the slope compensation widens back face occluders, against light leaking behind thin geometry",
}
local max_slope_compensation = pvars.Setup2{
	key = "ambient_occlusion_max_slope_compensation",
	default = 4.0,
	help = "largest factor an occluder circle is widened by when its surface is seen at a grazing angle",
}
local samples = pvars.Setup2{
	key = "ambient_occlusion_samples",
	default = 32,
	help = "depth samples per pixel and frame, read when the shader is built",
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

function ambient_occlusion.GetRadius()
	return radius:Get()
end

function ambient_occlusion.GetScreenRadius()
	return screen_radius:Get()
end

function ambient_occlusion.GetBackfaceThreshold()
	return backface_threshold:Get()
end

function ambient_occlusion.GetBackfaceBoost()
	return backface_boost:Get()
end

function ambient_occlusion.GetMaxSlopeCompensation()
	return max_slope_compensation:Get()
end

function ambient_occlusion.GetSamples()
	return samples:Get()
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
