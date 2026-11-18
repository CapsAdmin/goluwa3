local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local radiance = {}
radiance.RESOLUTION_SCALES = {full = 1, half = 0.5, quarter = 0.25}
pvars.StartGroup("Lighting", "ReSTIR GI", {store = false, prefix = "radiance_"})
radiance.resolution = pvars.Setup2{
	key = "radiance_resolution",
	default = "full",
	enums = {"full", "half", "quarter"},
	help = "the resolution the gi reservoirs are kept, resampled and denoised at, relative to the screen. below full a gi pixel stands for one of the 2x2 screen pixels below it, a different one each frame, and loses its history where those pixels are different surfaces (foliage). radiance_rays sets how many of them trace",
	callback = function()
		local pipelines = render3d.pipelines

		if not pipelines or not pipelines.radiance_temporal then return end

		for _, name in ipairs{
			"radiance_candidates",
			"radiance_temporal",
			"radiance_spatial",
			"radiance_accumulate",
			"radiance_filter_0",
			"radiance_filter_1",
			"radiance_filter_2",
			"radiance_filter",
		} do
			pipelines[name]:RecreateFramebuffers()
		end
	end,
}
radiance.specular_emitter_roughness = pvars.Setup2{
	key = "radiance_specular_emitter_roughness",
	default = 0.2,
	help = "perceptual roughness from which the specular rays leave emissive surfaces to emitter samples (the light tree, as the diffuse rays sample them), each weighed by the specular lobe. a ray finds a small emitter rarely, and a sample reaches it directly",
}
radiance.RAY_SHARES = {every = 1, half = 2, quarter = 4}
radiance.rays = pvars.Setup2{
	key = "radiance_rays",
	default = "every",
	enums = {"every", "half", "quarter"},
	help = "which gi pixels trace a new ray each frame: every one, half of them (a checkerboard) or one of each 2x2 (a different one every frame). the others keep their reservoir and take this frame's new samples from their neighbours, so every pixel has a history of its own surface at a fraction of the rays",
}
radiance.temporal = pvars.Setup2{
	key = "radiance_temporal",
	default = true,
	help = "each pixel's reservoir keeps its sample from last frame and resamples it against this frame's, so a rare bright sample (sky through a small opening, a hidden emitter) lasts several frames instead of flashing as a firefly. a moving pixel keeps a shorter history so samples are not dragged into streaks. radiance_rays half and quarter need it: a pixel that did not trace has no sample of its own hemisphere without it and the shade comes out dark",
}
radiance.max_history = pvars.Setup2{
	key = "radiance_max_history",
	default = 12,
	integer = true,
	min = 1,
	max = 100,
	help = "the most frames of samples a reservoir stands for. more is less noise and a slower answer when the light changes",
}
radiance.permutation = pvars.Setup2{
	key = "radiance_permutation",
	default = false,
	help = "each frame every pixel takes its old reservoir from a neighbour (the same swap for the whole screen), so a lucky bright sample wanders instead of staying a blotch for its whole history. it brings fireflies back (a swapped sample is weighed at a receiver it was not found from) and the motion scaled history already keeps moving samples from streaking",
}
radiance.boiling_filter = pvars.Setup2{
	key = "radiance_boiling_filter",
	default = 0,
	min = 0,
	max = 100,
	help = "a reservoir whose light is more than this many times the mean of its 8x8 pixel group drops its history for this frame's sample. it darkens shade lit through small gaps, where the few reservoirs that found the gap are rightly far brighter than the rest. 0 is off",
}
radiance.hit_gi_share = pvars.Setup2{
	key = "radiance_hit_gi_share",
	default = 1,
	min = 0.05,
	max = 1,
	help = "share of frames an 8x8 pixel group looks its off screen ray hits up in the world cache (the light past the first bounce, with its visibility rays), scaled up by 1/share when it does. unbiased and leak free at any share and the cheapest saving in the candidate pass (a quarter saved 1.8 ms in foliage), but the groups that looked up stand out as mottling while the camera moves and the denoiser has little history: 0.5 is faint, 0.25 clearly visible",
}
radiance.guided = pvars.Setup2{
	key = "radiance_guided",
	default = 0.5,
	min = 0,
	max = 0.95,
	help = "share of the gi rays aimed by the nearest radiance_cache probe's radiance guide instead of the cosine, weighted by the mix of both densities so it stays unbiased. light through a small opening or from a sunlit patch next to a dark room is found that much more often instead of as rare bright samples. only with the radiance_cache cache",
}
radiance.spatial = pvars.Setup2{
	key = "radiance_spatial",
	default = true,
	help = "each pixel also resamples the reservoirs of pixels around it on the same surface, reconnecting their hit points to its own position",
}
radiance.spatial_samples = pvars.Setup2{
	key = "radiance_spatial_samples",
	default = 2,
	integer = true,
	min = 1,
	max = 16,
	help = "neighbouring reservoirs each pixel resamples",
}
radiance.spatial_radius = pvars.Setup2{
	key = "radiance_spatial_radius",
	default = 32,
	min = 2,
	max = 64,
	help = "radius in gi pixels the neighbours are picked from",
}
radiance.visibility = pvars.Setup2{
	key = "radiance_visibility",
	default = true,
	help = "a neighbour's hit point is only taken after a ray from this pixel reaches it. off, light from behind nearby walls and corners leaks in and contact shadows fade",
}
radiance.temporal_search = pvars.Setup2{
	key = "radiance_temporal_search",
	default = true,
	help = "when none of the 4 texels last frame's position falls between holds this pixel's surface (thin things like fences and leaves under the jitter, edges that moved), the reservoir and the denoiser take their history from the texel around them that does instead of giving it up",
}
radiance.validation = pvars.Setup2{
	key = "radiance_validation",
	default = false,
	help = "every 4th frame a pixel traces again to the hit point its reservoir holds and drops the history if the hit is gone or its light changed more than 4x, which resets the denoiser around it. it darkens light seen through gaps (canopies): the retrace cannot start where the sample was found, and the samples it loses are the bright ones. off, a changed light is followed within radiance_max_history frames",
}
radiance.accumulation = pvars.Setup2{
	key = "radiance_accumulation",
	default = 64,
	integer = true,
	min = 1,
	max = 100000,
	help = "most frames the denoiser averages. with temporal and spatial reuse and the filter off and a still camera a very large number accumulates a reference",
}
radiance.light_change = pvars.Setup2{
	key = "radiance_light_change",
	default = 0.25,
	min = 0,
	max = 10,
	help = "when the sun or moon changes in a frame by more than this (its relative change in illuminance plus how far its direction moved), the denoiser keeps only a few frames of history everywhere for a moment. exponential averaging otherwise takes as many history lengths to follow a drop as the drop has orders of magnitude (day to night is seconds). 0 is off",
}
radiance.filter = pvars.Setup2{
	key = "radiance_filter",
	default = true,
	help = "the denoiser's spatial filter: a-trous passes stopped by plane, normal and a luminance difference beyond the pixel's noise, so a noisy pixel blurs wide and a settled one keeps its detail",
}
radiance.filter_luminance = pvars.Setup2{
	key = "radiance_filter_luminance",
	default = 4,
	help = "how many standard deviations of a pixel's estimate a neighbour may differ by and still be blurred in, higher blurs noisy areas wider and loses more contrast",
}
radiance.debug = pvars.Setup2{
	key = "radiance_debug",
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

	function radiance.GetHistoryCap()
		local frame = system.GetFrameNumber()

		if frame == last_frame then return cap end

		last_frame = frame
		local lights = render3d.GetLights()
		local direction = directional_shadows.GetPrimarySunDirection(lights)
		local illuminance = directional_shadows.GetPrimarySunIlluminance(lights) * math.smoothstep(-0.08, 0.02, direction.y)
		local threshold = radiance.light_change:Get()

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
	radiance.MAX_CHANGED_LIGHTS = 8
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

	function radiance.GetChangedLights()
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

		for i = #changed, radiance.MAX_CHANGED_LIGHTS + 1, -1 do
			changed[i] = nil
		end

		return changed
	end
end

function radiance.GetRayShare()
	return radiance.RAY_SHARES[radiance.rays:Get()]
end

function radiance.GetScale()
	return radiance.RESOLUTION_SCALES[radiance.resolution:Get()]
end

do
	local reset_frame = 0

	function radiance.ResetHistory()
		reset_frame = system.GetFrameNumber()
	end

	function radiance.GetResetFrame()
		return reset_frame
	end
end

function radiance.IsDebugGI()
	return radiance.debug:Get()
end

function radiance.GetOutputTexture(index)
	return render3d.pipelines.radiance_filter:GetFramebuffer(1):GetAttachment(index)
end

function radiance.GetSpecularTexture()
	return radiance.GetOutputTexture(3)
end

function radiance.GetHitIrradianceTextures()
	local current = system.GetFrameNumber() % 2 + 1
	return render3d.pipelines.radiance_accumulate:GetFramebuffer(current):GetAttachment(3),
	render3d.pipelines.radiance_temporal:GetFramebuffer(current):GetAttachment(4)
end

return radiance
