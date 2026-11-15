local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local short_range_gi = {}
pvars.StartGroup("Lighting", "Short range GI", {store = false, prefix = "short_range_gi_"})
short_range_gi.range = pvars.Setup2{
	key = "short_range_gi_range",
	default = 2,
	help = "how far the per pixel rays reach, in spacings of the finest probe cascade. a ray that hits something within it takes that surface's light, a ray that reaches its end takes the probes' light from its direction there",
}
short_range_gi.rays = pvars.Setup2{
	key = "short_range_gi_rays",
	default = 1,
	integer = true,
	help = "rays per pixel and frame",
}
short_range_gi.accumulation = pvars.Setup2{
	key = "short_range_gi_accumulation",
	default = 32,
	help = "most frames a pixel's estimate averages over",
}
pvars.EndGroup()

do
	local reset_frame = 0

	function short_range_gi.ResetHistory()
		reset_frame = system.GetFrameNumber()
	end

	function short_range_gi.GetResetFrame()
		return reset_frame
	end
end

function short_range_gi.IsActive()
	return render3d.IsPassEnabled("short_range_gi")
end

function short_range_gi.GetOutputTexture()
	return render3d.pipelines.short_range_gi_accumulate:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1)
end

return short_range_gi
