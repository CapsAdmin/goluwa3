local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local restir_gi = {}
restir_gi.RESOLUTION_SCALES = {full = 1, half = 0.5, quarter = 0.25}
pvars.StartGroup("Lighting", "ReSTIR GI", {store = false, prefix = "restir_gi_"})
restir_gi.resolution = pvars.Setup2{
	key = "restir_gi_resolution",
	default = "full",
	enums = {"full", "half", "quarter"},
	help = "the resolution the gi reservoirs are kept, resampled and denoised at, relative to the screen. below full a gi pixel stands for one of the 2x2 screen pixels below it, a different one each frame, and loses its history where those pixels are different surfaces (foliage). restir_gi_rays sets how many of them trace",
	callback = function()
		local pipelines = render3d.pipelines

		if not pipelines or not pipelines.restir_gi_temporal then return end

		for _, name in ipairs{
			"restir_gi_candidates",
			"restir_gi_temporal",
			"restir_gi_spatial",
			"restir_gi_accumulate",
			"restir_gi_blur",
			"restir_gi_filter",
		} do
			pipelines[name]:RecreateFramebuffers()
		end
	end,
}
restir_gi.RAY_SHARES = {every = 1, half = 2, quarter = 4}
restir_gi.rays = pvars.Setup2{
	key = "restir_gi_rays",
	default = "every",
	enums = {"every", "half", "quarter"},
	help = "which gi pixels trace a new ray each frame: every one, half of them (a checkerboard) or one of each 2x2 (a different one every frame). the others keep their reservoir and take this frame's new samples from their neighbours, so every pixel has a history of its own surface at a fraction of the rays",
}
restir_gi.temporal = pvars.Setup2{
	key = "restir_gi_temporal",
	default = true,
	help = "each pixel's reservoir keeps its sample from last frame and resamples it against this frame's, so a rare bright sample (sky through a small opening, a hidden emitter) lasts several frames instead of flashing as a firefly. a moving pixel keeps a shorter history so samples are not dragged into streaks. restir_gi_rays half and quarter need it: a pixel that did not trace has no sample of its own hemisphere without it and the shade comes out dark",
}
restir_gi.max_history = pvars.Setup2{
	key = "restir_gi_max_history",
	default = 12,
	integer = true,
	min = 1,
	max = 100,
	help = "the most frames of samples a reservoir stands for. more is less noise and a slower answer when the light changes",
}
restir_gi.permutation = pvars.Setup2{
	key = "restir_gi_permutation",
	default = false,
	help = "each frame every pixel takes its old reservoir from a neighbour (the same swap for the whole screen), so a lucky bright sample wanders instead of staying a blotch for its whole history. it brings fireflies back (a swapped sample is weighed at a receiver it was not found from) and the motion scaled history already keeps moving samples from streaking",
}
restir_gi.boiling_filter = pvars.Setup2{
	key = "restir_gi_boiling_filter",
	default = 0,
	min = 0,
	max = 100,
	help = "a reservoir whose light is more than this many times the mean of its 8x8 pixel group drops its history for this frame's sample. it darkens shade lit through small gaps, where the few reservoirs that found the gap are rightly far brighter than the rest. 0 is off",
}
restir_gi.hit_gi_share = pvars.Setup2{
	key = "restir_gi_hit_gi_share",
	default = 1,
	min = 0.05,
	max = 1,
	help = "share of frames an 8x8 pixel group looks its off screen ray hits up in the world cache (the light past the first bounce, with its visibility rays), scaled up by 1/share when it does. unbiased and leak free at any share and the cheapest saving in the candidate pass (a quarter saved 1.8 ms in foliage), but the groups that looked up stand out as mottling while the camera moves and the denoiser has little history: 0.5 is faint, 0.25 clearly visible",
}
restir_gi.guided = pvars.Setup2{
	key = "restir_gi_guided",
	default = 0.5,
	min = 0,
	max = 0.95,
	help = "share of the gi rays aimed by the nearest ddgi probe's radiance guide instead of the cosine, weighted by the mix of both densities so it stays unbiased. light through a small opening or from a sunlit patch next to a dark room is found that much more often instead of as rare bright samples. only with the ddgi cache",
}
restir_gi.spatial = pvars.Setup2{
	key = "restir_gi_spatial",
	default = true,
	help = "each pixel also resamples the reservoirs of pixels around it on the same surface, reconnecting their hit points to its own position",
}
restir_gi.spatial_samples = pvars.Setup2{
	key = "restir_gi_spatial_samples",
	default = 2,
	integer = true,
	min = 1,
	max = 16,
	help = "neighbouring reservoirs each pixel resamples",
}
restir_gi.spatial_radius = pvars.Setup2{
	key = "restir_gi_spatial_radius",
	default = 32,
	min = 2,
	max = 64,
	help = "radius in gi pixels the neighbours are picked from",
}
restir_gi.visibility = pvars.Setup2{
	key = "restir_gi_visibility",
	default = true,
	help = "a neighbour's hit point is only taken after a ray from this pixel reaches it. off, light from behind nearby walls and corners leaks in and contact shadows fade",
}
restir_gi.validation = pvars.Setup2{
	key = "restir_gi_validation",
	default = false,
	help = "every 4th frame a pixel traces again to the hit point its reservoir holds and drops the history if the hit is gone or its light changed more than 4x, which resets the denoiser around it. it darkens light seen through gaps (canopies): the retrace cannot start where the sample was found, and the samples it loses are the bright ones. off, a changed light is followed within restir_gi_max_history frames",
}
restir_gi.accumulation = pvars.Setup2{
	key = "restir_gi_accumulation",
	default = 64,
	integer = true,
	min = 1,
	max = 100000,
	help = "most frames the denoiser averages. with temporal and spatial reuse and the filter off and a still camera a very large number accumulates a reference",
}
restir_gi.light_change = pvars.Setup2{
	key = "restir_gi_light_change",
	default = 0.25,
	min = 0,
	max = 10,
	help = "when the sun or moon changes in a frame by more than this (its relative change in illuminance plus how far its direction moved), the denoiser keeps only a few frames of history everywhere for a moment. exponential averaging otherwise takes as many history lengths to follow a drop as the drop has orders of magnitude (day to night is seconds). 0 is off",
}
restir_gi.filter = pvars.Setup2{
	key = "restir_gi_filter",
	default = true,
	help = "the denoiser's spatial filter, wide where the history is short and narrowing as frames add up",
}
restir_gi.filter_radius = pvars.Setup2{
	key = "restir_gi_filter_radius",
	default = 24,
	min = 1,
	max = 32,
	help = "radius in gi pixels of the spatial filter on a pixel with no history",
}
restir_gi.filter_history = pvars.Setup2{
	key = "restir_gi_filter_history",
	default = 8,
	min = 1,
	max = 100,
	help = "frames of history after which the spatial filter is off: its radius falls from restir_gi_filter_radius on a pixel with no history to nothing here, so only what the camera just revealed is blurred and settled surfaces keep their detail",
}
restir_gi.debug = pvars.Setup2{
	key = "restir_gi_debug",
	default = false,
	help = "shows the gi irradiance the lighting gets instead of the lit scene",
}
pvars.EndGroup()

do
	local LIGHT_CHANGE_FRAMES = 60
	local LIGHT_CHANGE_HISTORY = 4
	local last_frame = -1
	local cap = math.huge
	local fast_until = -1
	local reference

	function restir_gi.GetHistoryCap()
		local frame = system.GetFrameNumber()

		if frame == last_frame then return cap end

		last_frame = frame
		local lights = render3d.GetLights()
		local direction = directional_shadows.GetPrimarySunDirection(lights)
		local illuminance = directional_shadows.GetPrimarySunIlluminance(lights) * math.smoothstep(-0.08, 0.02, direction.y)
		local threshold = restir_gi.light_change:Get()

		if reference and threshold > 0 then
			local change = math.abs(illuminance - reference.illuminance) / math.max(illuminance, reference.illuminance, 1e-3) + (
					direction - reference.direction
				):GetLength()

			if change > threshold then fast_until = frame + LIGHT_CHANGE_FRAMES end
		end

		reference = reference or {}
		reference.illuminance = illuminance
		reference.direction = direction:Copy()
		cap = frame <= fast_until and LIGHT_CHANGE_HISTORY or math.huge
		return cap
	end
end

function restir_gi.GetRayShare()
	return restir_gi.RAY_SHARES[restir_gi.rays:Get()]
end

function restir_gi.GetScale()
	return restir_gi.RESOLUTION_SCALES[restir_gi.resolution:Get()]
end

do
	local reset_frame = 0

	function restir_gi.ResetHistory()
		reset_frame = system.GetFrameNumber()
	end

	function restir_gi.GetResetFrame()
		return reset_frame
	end
end

function restir_gi.IsDebugGI()
	return restir_gi.debug:Get()
end

function restir_gi.GetOutputTexture(index)
	return render3d.pipelines.restir_gi_filter:GetFramebuffer(1):GetAttachment(index)
end

return restir_gi
