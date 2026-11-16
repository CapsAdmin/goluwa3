local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local global_illumination = {}
global_illumination.RESOLUTION_SCALES = {full = 1, half = 0.5, quarter = 0.25}
pvars.StartGroup("Lighting", "ReSTIR GI", {store = false, prefix = "global_illumination_"})
global_illumination.resolution = pvars.Setup2{
	key = "global_illumination_resolution",
	default = "full",
	enums = {"full", "half", "quarter"},
	help = "the resolution the gi reservoirs are kept, resampled and denoised at, relative to the screen. below full a gi pixel stands for one of the 2x2 screen pixels below it, a different one each frame, and loses its history where those pixels are different surfaces (foliage). global_illumination_rays sets how many of them trace",
	callback = function()
		local pipelines = render3d.pipelines

		if not pipelines or not pipelines.global_illumination_temporal then return end

		for _, name in ipairs{
			"global_illumination_candidates",
			"global_illumination_temporal",
			"global_illumination_spatial",
			"global_illumination_accumulate",
			"global_illumination_filter_0",
			"global_illumination_filter_1",
			"global_illumination_filter_2",
			"global_illumination_filter",
		} do
			pipelines[name]:RecreateFramebuffers()
		end
	end,
}
global_illumination.RAY_SHARES = {every = 1, half = 2, quarter = 4}
global_illumination.rays = pvars.Setup2{
	key = "global_illumination_rays",
	default = "every",
	enums = {"every", "half", "quarter"},
	help = "which gi pixels trace a new ray each frame: every one, half of them (a checkerboard) or one of each 2x2 (a different one every frame). the others keep their reservoir and take this frame's new samples from their neighbours, so every pixel has a history of its own surface at a fraction of the rays",
}
global_illumination.temporal = pvars.Setup2{
	key = "global_illumination_temporal",
	default = true,
	help = "each pixel's reservoir keeps its sample from last frame and resamples it against this frame's, so a rare bright sample (sky through a small opening, a hidden emitter) lasts several frames instead of flashing as a firefly. a moving pixel keeps a shorter history so samples are not dragged into streaks. global_illumination_rays half and quarter need it: a pixel that did not trace has no sample of its own hemisphere without it and the shade comes out dark",
}
global_illumination.max_history = pvars.Setup2{
	key = "global_illumination_max_history",
	default = 12,
	integer = true,
	min = 1,
	max = 100,
	help = "the most frames of samples a reservoir stands for. more is less noise and a slower answer when the light changes",
}
global_illumination.permutation = pvars.Setup2{
	key = "global_illumination_permutation",
	default = false,
	help = "each frame every pixel takes its old reservoir from a neighbour (the same swap for the whole screen), so a lucky bright sample wanders instead of staying a blotch for its whole history. it brings fireflies back (a swapped sample is weighed at a receiver it was not found from) and the motion scaled history already keeps moving samples from streaking",
}
global_illumination.boiling_filter = pvars.Setup2{
	key = "global_illumination_boiling_filter",
	default = 0,
	min = 0,
	max = 100,
	help = "a reservoir whose light is more than this many times the mean of its 8x8 pixel group drops its history for this frame's sample. it darkens shade lit through small gaps, where the few reservoirs that found the gap are rightly far brighter than the rest. 0 is off",
}
global_illumination.hit_gi_share = pvars.Setup2{
	key = "global_illumination_hit_gi_share",
	default = 1,
	min = 0.05,
	max = 1,
	help = "share of frames an 8x8 pixel group looks its off screen ray hits up in the world cache (the light past the first bounce, with its visibility rays), scaled up by 1/share when it does. unbiased and leak free at any share and the cheapest saving in the candidate pass (a quarter saved 1.8 ms in foliage), but the groups that looked up stand out as mottling while the camera moves and the denoiser has little history: 0.5 is faint, 0.25 clearly visible",
}
global_illumination.guided = pvars.Setup2{
	key = "global_illumination_guided",
	default = 0.5,
	min = 0,
	max = 0.95,
	help = "share of the gi rays aimed by the nearest gi_cache probe's radiance guide instead of the cosine, weighted by the mix of both densities so it stays unbiased. light through a small opening or from a sunlit patch next to a dark room is found that much more often instead of as rare bright samples. only with the gi_cache cache",
}
global_illumination.spatial = pvars.Setup2{
	key = "global_illumination_spatial",
	default = true,
	help = "each pixel also resamples the reservoirs of pixels around it on the same surface, reconnecting their hit points to its own position",
}
global_illumination.spatial_samples = pvars.Setup2{
	key = "global_illumination_spatial_samples",
	default = 2,
	integer = true,
	min = 1,
	max = 16,
	help = "neighbouring reservoirs each pixel resamples",
}
global_illumination.spatial_radius = pvars.Setup2{
	key = "global_illumination_spatial_radius",
	default = 32,
	min = 2,
	max = 64,
	help = "radius in gi pixels the neighbours are picked from",
}
global_illumination.visibility = pvars.Setup2{
	key = "global_illumination_visibility",
	default = true,
	help = "a neighbour's hit point is only taken after a ray from this pixel reaches it. off, light from behind nearby walls and corners leaks in and contact shadows fade",
}
global_illumination.validation = pvars.Setup2{
	key = "global_illumination_validation",
	default = false,
	help = "every 4th frame a pixel traces again to the hit point its reservoir holds and drops the history if the hit is gone or its light changed more than 4x, which resets the denoiser around it. it darkens light seen through gaps (canopies): the retrace cannot start where the sample was found, and the samples it loses are the bright ones. off, a changed light is followed within global_illumination_max_history frames",
}
global_illumination.accumulation = pvars.Setup2{
	key = "global_illumination_accumulation",
	default = 64,
	integer = true,
	min = 1,
	max = 100000,
	help = "most frames the denoiser averages. with temporal and spatial reuse and the filter off and a still camera a very large number accumulates a reference",
}
global_illumination.light_change = pvars.Setup2{
	key = "global_illumination_light_change",
	default = 0.25,
	min = 0,
	max = 10,
	help = "when the sun or moon changes in a frame by more than this (its relative change in illuminance plus how far its direction moved), the denoiser keeps only a few frames of history everywhere for a moment. exponential averaging otherwise takes as many history lengths to follow a drop as the drop has orders of magnitude (day to night is seconds). 0 is off",
}
global_illumination.filter = pvars.Setup2{
	key = "global_illumination_filter",
	default = true,
	help = "the denoiser's spatial filter: a-trous passes stopped by plane, normal and a luminance difference beyond the pixel's noise, so a noisy pixel blurs wide and a settled one keeps its detail",
}
global_illumination.filter_luminance = pvars.Setup2{
	key = "global_illumination_filter_luminance",
	default = 4,
	help = "how many standard deviations of a pixel's estimate a neighbour may differ by and still be blurred in, higher blurs noisy areas wider and loses more contrast",
}
global_illumination.debug = pvars.Setup2{
	key = "global_illumination_debug",
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

	function global_illumination.GetHistoryCap()
		local frame = system.GetFrameNumber()

		if frame == last_frame then return cap end

		last_frame = frame
		local lights = render3d.GetLights()
		local direction = directional_shadows.GetPrimarySunDirection(lights)
		local illuminance = directional_shadows.GetPrimarySunIlluminance(lights) * math.smoothstep(-0.08, 0.02, direction.y)
		local threshold = global_illumination.light_change:Get()

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

do
	local CHANGE_FRAMES = 60
	global_illumination.MAX_CHANGED_LIGHTS = 8
	local tracked = setmetatable({}, {__mode = "k"})
	local changed = {}
	local last_frame = -1

	local function track(key, x, y, z, size, intensity, rotation, frame)
		local t = tracked[key]

		if not t then
			t = {path = {}}
			tracked[key] = t
		end

		if
			t.x and
			(
				math.abs(x - t.x) + math.abs(y - t.y) + math.abs(z - t.z) > 1e-3 or
				math.abs(intensity - t.intensity) > 0.02 * math.max(intensity, t.intensity)
				or
				rotation and
				math.abs(rotation.x * t.qx + rotation.y * t.qy + rotation.z * t.qz + rotation.w * t.qw) < 0.99999
			)
		then
			t.until_frame = frame + CHANGE_FRAMES
			t.path[#t.path + 1] = {frame = frame, x = t.x, y = t.y, z = t.z, intensity = t.intensity}
		end

		t.x, t.y, t.z, t.intensity = x, y, z, intensity

		if rotation then
			t.qx, t.qy, t.qz, t.qw = rotation.x, rotation.y, rotation.z, rotation.w
		end

		while t.path[1] and t.path[1].frame < frame - CHANGE_FRAMES do
			table.remove(t.path, 1)
		end

		if not t.until_frame or t.until_frame < frame then return end

		local lo_x, lo_y, lo_z, hi_x, hi_y, hi_z, strongest = x, y, z, x, y, z, intensity

		for _, p in ipairs(t.path) do
			lo_x, lo_y, lo_z = math.min(lo_x, p.x), math.min(lo_y, p.y), math.min(lo_z, p.z)
			hi_x, hi_y, hi_z = math.max(hi_x, p.x), math.max(hi_y, p.y), math.max(hi_z, p.z)
			strongest = math.max(strongest, p.intensity)
		end

		changed[#changed + 1] = {
			x = (lo_x + hi_x) * 0.5,
			y = (lo_y + hi_y) * 0.5,
			z = (lo_z + hi_z) * 0.5,
			radius = 0.5 * math.sqrt((hi_x - lo_x) ^ 2 + (hi_y - lo_y) ^ 2 + (hi_z - lo_z) ^ 2) + size,
			intensity = strongest,
		}
	end

	local function by_intensity(a, b)
		return a.intensity > b.intensity
	end

	function global_illumination.GetChangedLights()
		local frame = system.GetFrameNumber()

		if frame == last_frame then return changed end

		last_frame = frame
		table.clear(changed)

		for visual in pairs(bridge.GetEmissiveVisuals()) do
			local aabb = visual.Visible and visual:GetWorldAABB()

			if aabb then
				local luminance = 0

				for _, item in ipairs(visual.scene_instances) do
					if item.material:GetEmitsLight() then
						local r, g, b = materials.GetEmissive(item.material)
						luminance = math.max(luminance, 0.2126 * r + 0.7152 * g + 0.0722 * b)
					end
				end

				local sx, sy, sz = aabb.max_x - aabb.min_x, aabb.max_y - aabb.min_y, aabb.max_z - aabb.min_z
				track(
					visual,
					(aabb.min_x + aabb.max_x) * 0.5,
					(aabb.min_y + aabb.max_y) * 0.5,
					(aabb.min_z + aabb.max_z) * 0.5,
					0.5 * math.sqrt(sx * sx + sy * sy + sz * sz),
					luminance * render3d.EMISSIVE_REFERENCE_LUMINANCE * math.max(sx * sy, sy * sz, sx * sz),
					false,
					frame
				)
			end
		end

		for _, light in ipairs(render3d.GetLights()) do
			if light.Type ~= "light_sun" and light.Type ~= "light_directional" then
				local x, y, z = light.Owner.transform:GetWorldMatrix():GetTranslation()
				local color = light.Color
				track(
					light,
					x,
					y,
					z,
					light.SourceRadius,
					(
							0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
						) * light:GetColorScale() * light:GetPhotometricAmount() * light:GetInverseEmissionSolidAngle(),
					light.Owner.transform:GetRotation(),
					frame
				)
			end
		end

		table.sort(changed, by_intensity)

		for i = #changed, global_illumination.MAX_CHANGED_LIGHTS + 1, -1 do
			changed[i] = nil
		end

		return changed
	end
end

function global_illumination.GetRayShare()
	return global_illumination.RAY_SHARES[global_illumination.rays:Get()]
end

function global_illumination.GetScale()
	return global_illumination.RESOLUTION_SCALES[global_illumination.resolution:Get()]
end

do
	local reset_frame = 0

	function global_illumination.ResetHistory()
		reset_frame = system.GetFrameNumber()
	end

	function global_illumination.GetResetFrame()
		return reset_frame
	end
end

function global_illumination.IsDebugGI()
	return global_illumination.debug:Get()
end

function global_illumination.GetOutputTexture(index)
	return render3d.pipelines.global_illumination_filter:GetFramebuffer(1):GetAttachment(index)
end

function global_illumination.GetSpecularTexture()
	return global_illumination.GetOutputTexture(3)
end

function global_illumination.GetHitIrradianceTextures()
	local current = system.GetFrameNumber() % 2 + 1
	return render3d.pipelines.global_illumination_accumulate:GetFramebuffer(current):GetAttachment(3),
	render3d.pipelines.global_illumination_temporal:GetFramebuffer(current):GetAttachment(4)
end

return global_illumination
