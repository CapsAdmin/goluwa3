local pvars = import("goluwa/cli/pvars.lua")
local commands = import("goluwa/cli/commands.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local Material = import("goluwa/render3d/material.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local path_trace = {}
path_trace.VIEWS = {"path", "raster", "split", "difference"}
pvars.StartGroup("Lighting", "Path tracer", {store = false, prefix = "path_trace_"})
path_trace.bounces = pvars.Setup2{
	key = "path_trace_bounces",
	default = 8,
	integer = true,
	help = "the most bounces a path takes after the surface the camera sees, every bounce past the third may end early (russian roulette) without changing the mean",
}
path_trace.samples_per_frame = pvars.Setup2{
	key = "path_trace_samples_per_frame",
	default = 1,
	integer = true,
	help = "paths a pixel traces each frame and adds to its mean",
}
path_trace.max_samples = pvars.Setup2{
	key = "path_trace_max_samples",
	default = 0,
	integer = true,
	help = "the path tracer stops tracing once a pixel's mean holds this many paths and keeps showing it, 0 traces forever",
}
path_trace.view = pvars.Setup2{
	key = "path_trace_view",
	default = "path",
	enums = path_trace.VIEWS,
	help = "what the path trace pass shows over the lit scene: path is the path traced reference, raster the normal lighting (the reference keeps accumulating, so flipping between the two compares them), split shows the raster lighting left of path_trace_split and the reference right of it, difference compares the two raw radiance targets and is drawn straight to the screen, past fog, translucency, taa, bloom and tonemapping: grey is the reference's exposed brightness, red where the raster lighting is brighter and blue where it is darker, full colour at path_trace_difference_stops",
}
path_trace.split = pvars.Setup2{
	key = "path_trace_split",
	default = 0.5,
	help = "where the split view divides the screen, 0 is the left edge and 1 the right",
}
path_trace.difference_stops = pvars.Setup2{
	key = "path_trace_difference_stops",
	default = 1,
	help = "the difference in stops (factors of two) between the raster lighting and the reference that the difference view shows in full colour",
}
path_trace.caustics = pvars.Setup2{
	key = "path_trace_caustics",
	default = true,
	help = "light is bent by glass and water: paths refract and reflect through glass bodies, and photons traced from the sun through glass and water tops land on the surfaces the camera sees (the caustics a path from the surface cannot find the small sun through). off glass only tints the light passing straight through it, as in the raster lighting",
}
path_trace.photons = pvars.Setup2{
	key = "path_trace_photons",
	default = 1048576,
	integer = true,
	help = "photons traced from the sun through glass and water each frame for the caustics, more converges the caustics in fewer frames",
}
path_trace.reset_on_scene_change = pvars.Setup2{
	key = "path_trace_reset_on_scene_change",
	default = false,
	help = "the reference also starts over when something in the ray traced scene moves (the local player idling is enough, so it never converges while anything animates). off it starts over when the camera, the lights, the materials or the number of instances change, and what moves is averaged into a blur of its motion. path_trace_reset starts over by hand",
}
pvars.EndGroup()
local dirty_queue = bridge.CreateDirtyQueue()
local state = {
	samples = 0,
	reset = true,
	signature = {},
	before = 0,
	trace = false,
}

function path_trace.Reset()
	state.reset = true
end

function path_trace.GetSampleCount()
	return state.samples
end

commands.Add("path_trace_reset", function()
	path_trace.Reset()
end)

do
	local function changed(signature, i, value)
		if signature[i] == value then return false end

		signature[i] = value
		return true
	end

	function path_trace.Update(lights)
		local camera = render3d.GetCamera()
		local position = camera:GetPosition()
		local rotation = camera:GetRotation()
		local viewport = camera:GetViewport()
		local size = render3d.GetRenderSize()
		local signature = state.signature
		local any = false
		any = changed(signature, 1, position.x) or any
		any = changed(signature, 2, position.y) or any
		any = changed(signature, 3, position.z) or any
		any = changed(signature, 4, rotation.x) or any
		any = changed(signature, 5, rotation.y) or any
		any = changed(signature, 6, rotation.z) or any
		any = changed(signature, 7, rotation.w) or any
		any = changed(signature, 8, camera:GetFOV()) or any
		any = changed(signature, 9, viewport.w) or any
		any = changed(signature, 10, viewport.h) or any
		any = changed(signature, 11, size.x) or any
		any = changed(signature, 12, size.y) or any
		any = changed(signature, 13, scene_lights.GetHash(lights)) or any
		any = changed(signature, 14, Material.ray_material_generation) or any
		any = changed(signature, 15, instances.GetCount()) or any
		any = changed(signature, 16, render3d.GetEnvironmentTexture()) or any
		any = changed(signature, 17, path_trace.bounces:Get()) or any
		any = changed(signature, 18, path_trace.caustics:Get()) or any
		local scene_all, scene_boxes = bridge.ConsumeDirty(dirty_queue)

		if path_trace.reset_on_scene_change:Get() and (scene_all or scene_boxes[1]) then
			any = true
		end

		if any or state.reset then
			state.reset = false
			state.samples = 0
		end

		local before = state.samples
		local max_samples = path_trace.max_samples:Get()
		local trace = max_samples <= 0 or before < max_samples

		if trace then
			state.samples = before + path_trace.samples_per_frame:Get()
		end

		state.before = before
		state.trace = trace
		return before, trace
	end

	function path_trace.GetFrame()
		return state.before, state.trace
	end
end

function path_trace.AreCausticsTraced()
	return render3d.IsPassEnabled("path_trace") and path_trace.caustics:Get()
end

function path_trace.AreCausticsShown()
	return render3d.IsPassEnabled("path_trace") and
		path_trace.caustics:Get() and
		path_trace.view:Get() == "path"
end

local function attachment(index)
	return render3d.pipelines.path_trace:GetFramebuffer(1):GetAttachment(index)
end

function path_trace.GetTexture()
	return attachment(1)
end

function path_trace.GetRasterTexture()
	return attachment(2)
end

function path_trace.GetDifferenceTexture()
	if path_trace.view:Get() ~= "difference" or not render3d.IsPassEnabled("path_trace") then
		return nil
	end

	return attachment(3)
end

local function luminance(r, g, b)
	return r * 0.2126 + g * 0.7152 + b * 0.0722
end

function path_trace.Compare(step)
	step = step or 1
	local path = path_trace.GetTexture():Download()
	local raster = path_trace.GetRasterTexture():Download()
	local result = {
		pixels = 0,
		path = 0,
		raster = 0,
		absolute_error = 0,
		squared_error = 0,
	}

	for y = 0, path.height - 1, step do
		for x = 0, path.width - 1, step do
			local pr, pg, pb, count = path:GetPixelFloat(x, y)

			if count > 0 then
				local rr, rg, rb = raster:GetPixelFloat(x, y)
				local p = luminance(pr, pg, pb)
				local r = luminance(rr, rg, rb)
				result.pixels = result.pixels + 1
				result.path = result.path + p
				result.raster = result.raster + r
				result.absolute_error = result.absolute_error + math.abs(r - p)
				result.squared_error = result.squared_error + (r - p) ^ 2
			end
		end
	end

	if result.pixels > 0 then
		result.path = result.path / result.pixels
		result.raster = result.raster / result.pixels
		result.absolute_error = result.absolute_error / result.pixels
		result.squared_error = result.squared_error / result.pixels
	end

	result.ratio = result.path > 0 and result.raster / result.path or 0
	result.relative_error = result.path > 0 and result.absolute_error / result.path or 0
	result.samples = state.samples
	return result
end

commands.Add("path_trace_compare", function()
	local result = path_trace.Compare(2)
	logf(
		"path trace %d samples over %d pixels: mean luminance path %.4g raster %.4g (raster/path %.3f), mean absolute error %.1f%% of the path mean\n",
		result.samples,
		result.pixels,
		result.path,
		result.raster,
		result.ratio,
		result.relative_error * 100
	)
end)

return path_trace
