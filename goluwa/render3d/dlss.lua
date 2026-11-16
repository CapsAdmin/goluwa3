local ffi = require("ffi")
local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local vfs = import("goluwa/vfs.lua")
local ngx = import("goluwa/bindings/ngx.lua")
ffi.cdef("int setenv(const char *name, const char *value, int overwrite);")
local dlss = {}
pvars.StartGroup("Post", "DLSS", {store = false})
dlss.library_directory = pvars.Setup2{
	key = "r_dlss_library_directory",
	default = "local_stuff/DLSS/lib/Linux_x86_64/rel",
	store = true,
	help = "the directory with the DLSS feature libraries (libnvidia-ngx-dlss.so and libnvidia-ngx-dlssd.so from the DLSS SDK), relative to the working directory",
}
dlss.logging = pvars.Setup2{
	key = "r_dlss_logging",
	default = false,
	help = "write NGX's own log to storage/logs/ngx, read at startup",
}
dlss.show_input = pvars.Setup2{
	key = "r_dlss_show_input",
	default = false,
	help = "show the scene DLSS is given (internal resolution, before upscaling and denoising) instead of its output; DLSS still runs so toggling keeps its history",
}
pvars.EndGroup()
local NVIDIA_VENDOR_ID = 0x10DE
local REQUIRED_DEVICE_EXTENSIONS = {"VK_NVX_binary_import", "VK_NVX_image_view_handle", "VK_KHR_push_descriptor"}
local PROJECT_ID = "7d3f4c1e-9b2a-4e58-a6c0-5b8d1f0e2a47"
local ROUGHNESS_PACKED = 1
local DENOISE_UNIFIED = 1
local state = {ready = false, features = {}}
local resources = {}

local function get_resource(name)
	local resource = resources[name]

	if not resource then
		resource = ngx.NewResource()
		resources[name] = resource
	end

	return resource
end

local function fill_resource(name, texture, aspect, read_write)
	local resource = get_resource(name)
	local image = texture:GetImage()
	resource.ImageView = texture:GetView().ptr[0]
	resource.Image = image.ptr[0]
	resource.aspect_mask = aspect
	resource.Format = vulkan.vk.e.VkFormat(image.format)
	resource.Width = image.width
	resource.Height = image.height
	resource.ReadWrite = read_write
	return resource
end

function dlss.Initialize()
	if state.ready then return end

	local directory = vfs.GetStorageDirectory("root") .. dlss.library_directory:Get()
	local log_directory = vfs.GetStorageDirectory("root") .. "storage/logs/ngx"
	os.execute("mkdir -p " .. log_directory)

	if dlss.logging:Get() then
		ffi.C.setenv("__NGX_LOG_LEVEL", "2", 1)
		ffi.C.setenv("__NGX_ENABLE_OVERRIDE_LOG_PATH", "1", 1)
		ffi.C.setenv("__NGX_LOG_PATH_OVERRIDE", log_directory, 1)
	end

	local device = render.GetDevice()

	for _, extension in ipairs(REQUIRED_DEVICE_EXTENSIONS) do
		assert(
			table.has_value(device.enabled_extensions, extension),
			"DLSS needs the device extension " .. extension .. ", which this gpu or driver does not enable"
		)
	end

	assert(render.GetPhysicalDevice():GetProperties().vendorID == NVIDIA_VENDOR_ID, "DLSS needs an NVIDIA gpu")
	local ok, err = ngx.Initialize{
		project_id = PROJECT_ID,
		engine_version = "1.0",
		data_directory = log_directory,
		feature_directory = directory,
		instance = render.GetVulkanInstance().ptr[0],
		physical_device = render.GetPhysicalDevice().ptr[0],
		device = device.ptr[0],
		get_instance_proc_addr = ffi.cast("void *", vulkan.lib.vkGetInstanceProcAddr),
		get_device_proc_addr = ffi.cast("void *", vulkan.lib.vkGetDeviceProcAddr),
		logging_level = dlss.logging:Get() and 2 or 0,
	}

	if not ok then error("DLSS: " .. tostring(err), 2) end

	state.ready = true
	state.device = device
	state.available = {
		[ngx.Feature.SuperSampling] = ngx.IsFeatureAvailable(ngx.Feature.SuperSampling),
		[ngx.Feature.RayReconstruction] = ngx.IsFeatureAvailable(ngx.Feature.RayReconstruction),
	}
end

function dlss.IsAvailable(feature)
	dlss.Initialize()
	return state.available[feature]
end

local function create_feature(cmd, feature, inputs)
	local params = ngx.AllocateParameters()
	local flags = ngx.FeatureFlags.IsHDR + ngx.FeatureFlags.MVLowRes + ngx.FeatureFlags.DepthInverted + ngx.FeatureFlags.AutoExposure
	local quality = (
			inputs.render_width == inputs.output_width and
			inputs.render_height == inputs.output_height
		)
		and
		ngx.PerfQuality.DLAA or
		ngx.PerfQuality.MaxQuality
	ngx.SetUI(params, "CreationNodeMask", 1)
	ngx.SetUI(params, "VisibilityNodeMask", 1)
	ngx.SetUI(params, "Width", inputs.render_width)
	ngx.SetUI(params, "Height", inputs.render_height)
	ngx.SetUI(params, "OutWidth", inputs.output_width)
	ngx.SetUI(params, "OutHeight", inputs.output_height)
	ngx.SetI(params, "PerfQualityValue", quality)
	ngx.SetI(params, "DLSS.Feature.Create.Flags", flags)
	ngx.SetI(params, "DLSS.Enable.Output.Subrects", 0)

	if feature == ngx.Feature.RayReconstruction then
		ngx.SetI(params, "DLSS.Denoise.Mode", DENOISE_UNIFIED)
		ngx.SetUI(params, "DLSS.Roughness.Mode", ROUGHNESS_PACKED)
		ngx.SetUI(params, "DLSS.Use.HW.Depth", 1)
	end

	return {
		handle = ngx.CreateFeature(state.device.ptr[0], cmd.ptr[0], feature, params),
		params = params,
		render_width = inputs.render_width,
		render_height = inputs.render_height,
		output_width = inputs.output_width,
		output_height = inputs.output_height,
	}
end

function dlss.Release(feature)
	local existing = state.features[feature]

	if existing then
		state.device:WaitIdle()
		ngx.ReleaseFeature(existing.handle, existing.params)
		state.features[feature] = nil
	end
end

function dlss.Evaluate(cmd, feature, inputs)
	dlss.Initialize()
	local existing = state.features[feature]

	if
		existing and
		(
			existing.render_width ~= inputs.render_width or
			existing.render_height ~= inputs.render_height or
			existing.output_width ~= inputs.output_width or
			existing.output_height ~= inputs.output_height
		)
	then
		dlss.Release(feature)
		existing = nil
	end

	if not existing then
		existing = create_feature(cmd, feature, inputs)
		state.features[feature] = existing
	end

	local params = existing.params
	ngx.SetVoidPointer(params, "Color", fill_resource("color", inputs.color, ngx.ASPECT_COLOR, false))
	ngx.SetVoidPointer(params, "Output", fill_resource("output", inputs.output, ngx.ASPECT_COLOR, true))
	ngx.SetVoidPointer(params, "Depth", fill_resource("depth", inputs.depth, ngx.ASPECT_DEPTH, false))
	ngx.SetVoidPointer(
		params,
		"MotionVectors",
		fill_resource("motion", inputs.motion, ngx.ASPECT_COLOR, false)
	)
	ngx.SetF(params, "Jitter.Offset.X", inputs.jitter_x)
	ngx.SetF(params, "Jitter.Offset.Y", inputs.jitter_y)
	ngx.SetI(params, "Reset", inputs.reset and 1 or 0)
	ngx.SetF(params, "MV.Scale.X", inputs.motion_scale_x)
	ngx.SetF(params, "MV.Scale.Y", inputs.motion_scale_y)
	ngx.SetUI(params, "DLSS.Render.Subrect.Dimensions.Width", inputs.render_width)
	ngx.SetUI(params, "DLSS.Render.Subrect.Dimensions.Height", inputs.render_height)
	ngx.SetF(params, "DLSS.Pre.Exposure", 1)
	ngx.SetF(params, "DLSS.Exposure.Scale", 1)

	if feature == ngx.Feature.RayReconstruction then
		ngx.SetVoidPointer(
			params,
			"DLSS.Input.DiffuseAlbedo",
			fill_resource("diffuse_albedo", inputs.diffuse_albedo, ngx.ASPECT_COLOR, false)
		)
		ngx.SetVoidPointer(
			params,
			"DLSS.Input.SpecularAlbedo",
			fill_resource("specular_albedo", inputs.specular_albedo, ngx.ASPECT_COLOR, false)
		)
		ngx.SetVoidPointer(
			params,
			"GBuffer.Normals",
			fill_resource("normals", inputs.normals, ngx.ASPECT_COLOR, false)
		)
		ngx.SetVoidPointer(
			params,
			"GBuffer.SpecularMvec",
			fill_resource("specular_motion", inputs.specular_motion, ngx.ASPECT_COLOR, false)
		)
		ngx.SetVoidPointer(
			params,
			"RayTracingHitDistance",
			inputs.hit_distance and
				fill_resource("hit_distance", inputs.hit_distance, ngx.ASPECT_COLOR, false) or
				nil
		)
	end

	ngx.EvaluateFeature(cmd.ptr[0], existing.handle, params)
end

return dlss
