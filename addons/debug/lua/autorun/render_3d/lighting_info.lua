local commands = import("goluwa/cli/commands.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local ffi = require("ffi")
local render3d = import("goluwa/render3d/render3d.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local pvars = import("goluwa/cli/pvars.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")

commands.Add("lo_debug", function()
	local debug_state = light_occlusion.GetDebugState()
	logf(
		"[light_occlusion] frame %d, %d occlusion lights, bias %g blur %g bleed reduction %g oct %d\n",
		debug_state.frame,
		#debug_state.lights,
		debug_state.bias,
		debug_state.blur,
		debug_state.bleed_reduction,
		debug_state.oct_size
	)

	for _, light in ipairs(debug_state.lights) do
		logf(
			"  [%d] %-20s pos (%.1f %.1f %.1f) range %g stamp %d dispatched %d%s%s%s\n",
			light.index,
			light.name,
			light.x,
			light.y,
			light.z,
			light.range,
			light.stamp,
			light.dispatched,
			light.pending and " PENDING" or "",
			light.geom_stale and " GEOM_STALE" or "",
			light.in_frustum and "" or " OUT_OF_FRUSTUM"
		)
	end
end)

commands.Add("ddgi_emitter_info", function()
	local emitters = ddgi.GetEmitters()
	logf(
		"ddgi emitters: %d triangles, total power %.4g, reference luminance %.0f, max %.0f\n",
		emitters.count,
		emitters.weight,
		render3d.EMISSIVE_REFERENCE_LUMINANCE,
		render3d.EMISSIVE_MAX_LUMINANCE
	)
	logf(
		"  left out as additive effects (ddgi_additive_emitters 0): %d triangles, power %.4g\n",
		emitters.excluded_count,
		emitters.excluded_power
	)
	local floats = ffi.cast("float*", emitters.words)
	local lowest, highest = math.huge, 0

	for i = 0, emitters.count - 1 do
		local power = floats[2 + i * 3 + 2]
		lowest = math.min(lowest, power)
		highest = math.max(highest, power)
	end

	logf("  power per triangle: lowest %.4g, highest %.4g\n", lowest, highest)
	logf("  %d emissive blocks:\n", #scene_bvh.emissive_blocks)

	for i, block in ipairs(scene_bvh.emissive_blocks) do
		if i > 40 then
			logf("  ...\n")

			break
		end

		local power = 0

		for j = 0, block.emitter_count - 1 do
			power = power + block.emitters[j].power
		end

		logf(
			"  block %d%s: %d emitters, power %.4g, at %.1f %.1f %.1f\n",
			i,
			block.emitters[0].additive ~= 0 and not emitters.additive and " (left out)" or "",
			block.emitter_count,
			power,
			block.emitters[0].x,
			block.emitters[0].y,
			block.emitters[0].z
		)
		local seen = {}

		for _, slot in ipairs(block.slots) do
			if
				slot.emissive_r + slot.emissive_g + slot.emissive_b > 0 and
				not seen[slot.material_id]
			then
				seen[slot.material_id] = true
				local material = scene_bvh.materials[slot.material_id + 1]
				local color = material:GetColorMultiplier()
				logf(
					"    material '%s' (id %d): emissive x strength %.3f %.3f %.3f, colour %.2f %.2f %.2f, albedo texture %s, emissive texture %s, albedo alpha is emissive %s, additive %s\n",
					material:GetName(),
					slot.material_id,
					slot.emissive_r,
					slot.emissive_g,
					slot.emissive_b,
					color.r,
					color.g,
					color.b,
					tostring(material:GetAlbedoTexture() ~= nil),
					tostring(material:GetEmissiveTexture() ~= nil),
					tostring(material:GetAlbedoAlphaIsEmissive()),
					tostring(material:GetAdditive())
				)
			end
		end
	end
end)

commands.Add("ddgi_reset", function()
	ddgi.ResetHistory()
end)

commands.Add("ddgi_info", function()
	local state = ddgi.GetFrameState()
	local region = state.region
	logf(
		"ddgi: %d of %d cascades in use, region %.1f..%.1f %.1f..%.1f %.1f..%.1f\n",
		state.cascade_count,
		ddgi.CASCADES,
		region.min_x,
		region.max_x,
		region.min_y,
		region.max_y,
		region.min_z,
		region.max_z
	)

	for c = 1, ddgi.CASCADES do
		local cascade = state.cascades[c]
		logf(
			"  cascade %d%s: spacing %.2f, updates every %d frames, %d x %d x %d probes (%d), spans %.1f %.1f %.1f m from %.1f %.1f %.1f\n",
			c - 1,
			c > state.cascade_count and " (unused)" or "",
			cascade.spacing,
			ddgi.GetUpdateInterval(c),
			cascade.size.x,
			cascade.size.y,
			cascade.size.z,
			cascade.size.x * cascade.size.y * cascade.size.z,
			cascade.spacing * (cascade.size.x - 1),
			cascade.spacing * (cascade.size.y - 1),
			cascade.spacing * (cascade.size.z - 1),
			cascade.x * cascade.spacing,
			cascade.y * cascade.spacing,
			cascade.z * cascade.spacing
		)
	end
end)

commands.Add("r_exposure_info", function()
	local texture = post_source.GetExposureTexture()
	local exposure, metered_ev, adapted_ev = texture:Download():GetPixelFloat(0, 0)
	local ev = render3d.LOG_EXPOSURE_AT_EV0 - math.log(exposure) / math.log(2)
	logf(
		"[exposure] %s: metered EV %.2f, adapted EV %.2f, exposure %.3g (EV %.2f)\n",
		pvars.Get("r_eye") and "eye" or "camera",
		metered_ev,
		adapted_ev,
		exposure,
		ev
	)

	if not pvars.Get("r_eye") then
		local wb = exposure_model.GetCameraWhiteBalance()
		logf("[exposure] white balance %s\n", wb > 0 and (wb .. " K") or "auto")
		local iso, aperture, shutter = exposure_model.DescribeCamera(ev)
		logf("[exposure] camera %s: ISO %d, f/%.1f, 1/%d s\n", exposure_model.GetCameraMode(), iso, aperture, math.round(1 / shutter))
	end
end)
