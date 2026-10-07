local render3d = library()
import.loaded["goluwa/render3d/render3d.lua"] = render3d
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local event = import("goluwa/event.lua")
local Material = import("goluwa/render3d/material.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Camera3D = import("goluwa/render3d/camera3d.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local envprobe = import("goluwa/render3d/envprobe.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local skinning = import("goluwa/render3d/skinning.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local water = import("goluwa/render3d/water.lua")
local light_components = import("goluwa/entities/components/light.lua")

local function decorate_pipeline_instance(pipeline, config)
	pipeline.name = config.name
	pipeline.pre_render = config.pre_render
	pipeline.post_draw = config.post_draw
	pipeline.draw_in_prerender = config.draw_in_prerender ~= false
	pipeline.is_enabled = config.is_enabled
	pipeline.present_texture = config.present_texture
	return pipeline
end

local function remove_pipeline_bundle(bundle)
	if not bundle or not bundle.pipelines_i then return end

	for i = 1, #bundle.pipelines_i do
		local pipeline = bundle.pipelines_i[i]

		if pipeline then pipeline:Remove() end
	end

	bundle.pipelines = {}
	bundle.pipelines_i = {}
end

function render3d.GetGPUCulling()
	return gpu_culling
end

pvars.StartGroup("normal_map", {store = false})
local normal_map_strength = pvars.Setup2{
	key = "r_normal_map_strength",
	default = 1.0,
	min = 0,
	max = 4,
	help = "scales how far normal maps tilt the surface normal, 0 is the vertex normal only",
}
pvars.EndGroup()
render3d.camera_block = {
	{"inv_view", "mat4"},
	{"inv_projection", "mat4"},
	{"view", "mat4"},
	{"projection", "mat4"},
	{"render_size", "vec2"},
	{"camera_position", "vec3"},
	{"normal_map_strength", "float"},
}

function render3d.WriteCameraBlock(self, block)
	local camera = render3d.GetCamera()
	local view = camera:BuildViewMatrix()
	local projection = camera:BuildProjectionMatrix()
	view:GetInverse():CopyToFloatPointer(block.inv_view)
	projection:GetInverse():CopyToFloatPointer(block.inv_projection)
	view:CopyToFloatPointer(block.view)
	projection:CopyToFloatPointer(block.projection)
	local size = render.GetRenderImageSize()
	block.render_size[0] = size and size.x or 1
	block.render_size[1] = size and size.y or 1
	camera:GetPosition():CopyToFloatPointer(block.camera_position)
	block.normal_map_strength = normal_map_strength:Get()
	return block
end

render3d.previous_jitter = Vec2(0, 0)
render3d.prev_camera_block = {
	{"prev_view", "mat4"},
	{"prev_projection", "mat4"},
}

function render3d.WritePreviousCameraBlock(self, block)
	local camera = render3d.GetCamera()
	local view = render3d.GetPreviousViewMatrix() or camera:BuildViewMatrix()
	local projection = render3d.GetPreviousProjectionMatrix() or camera:BuildProjectionMatrix()
	view:CopyToFloatPointer(block.prev_view)
	projection:CopyToFloatPointer(block.prev_projection)
	return block
end

render3d.common_block = {
	{"time", "float"},
}

function render3d.WriteCommonBlock(self, block)
	block.time = system.GetElapsedTime()
	return block
end

pvars.StartGroup("gbuffer", {store = false})
render3d.velocity_enabled = pvars.Setup2{
	key = "velocity_buffer",
	default = true,
	friendly = "velocity buffer",
	help = "consumers follow moving surfaces, off they reproject through the previous camera only",
}
pvars.EndGroup()
render3d.EMISSIVE_REFERENCE_LUMINANCE = 2000.0
render3d.EMISSIVE_MAX_LUMINANCE = 64512.0 * 256.0

function render3d.GetEmissiveGLSL()
	return (
		"const float EMISSIVE_REFERENCE_LUMINANCE = %.1f;\nconst float EMISSIVE_MAX_LUMINANCE = %.1f;\n"
	):format(render3d.EMISSIVE_REFERENCE_LUMINANCE, render3d.EMISSIVE_MAX_LUMINANCE)
end

render3d.last_frame_block = {
	{"last_frame_tex", "int"},
}

function render3d.WriteLastFrameBlock(self, block)
	if not render3d.ShouldUseLastFrameHistory() then
		block.last_frame_tex = -1
		return block
	end

	if not render3d.IsPassEnabled("lighting") then
		block.last_frame_tex = -1
		return block
	end

	local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
	block.last_frame_tex = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(prev_idx):GetAttachment(1))
	return block
end

function render3d.GetActiveRenderContext()
	return render3d.active_render_context
end

local function context_value(field, fallback)
	local context = render3d.GetActiveRenderContext()

	if context and context[field] ~= nil then return context[field] end

	return fallback
end

local function context_bool(field, fallback)
	local context = render3d.GetActiveRenderContext()

	if context and context[field] ~= nil then return context[field] == true end

	return fallback
end

function render3d.ShouldUseLastFrameHistory()
	return context_bool("allow_last_frame_history", true)
end

function render3d.ShouldUseEnvProbes()
	return context_bool("allow_envprobe", true)
end

function render3d.ShouldUseProbeReflections()
	return context_bool("allow_probe_reflections", render3d.ShouldUseEnvProbes())
end

function render3d.GetPreviousViewMatrix()
	local context = render3d.GetActiveRenderContext()

	if context and context.prev_view_matrix ~= nil then
		return context.prev_view_matrix
	end

	return render3d.prev_view_matrix
end

do
	local jittered = Matrix44()

	function render3d.GetPreviousProjectionMatrix()
		local context = render3d.GetActiveRenderContext()

		if context and context.prev_projection_matrix ~= nil then
			return context.prev_projection_matrix
		end

		return render3d.prev_projection_matrix:GetMultiplied(render3d.GetCamera():GetJitterMatrix(), jittered)
	end
end

function render3d.IsPipelineEnabled(name)
	local context = render3d.GetActiveRenderContext()
	local pipeline_flags = context and context.pipeline_flags or nil

	if pipeline_flags and pipeline_flags[name] ~= nil then
		return pipeline_flags[name] == true
	end

	return true
end

function render3d.PushRenderContext(context)
	render3d.render_context_stack = render3d.render_context_stack or {}
	table.insert(
		render3d.render_context_stack,
		{
			pipelines = render3d.pipelines,
			pipelines_i = render3d.pipelines_i,
			context = render3d.active_render_context,
		}
	)
	render3d.active_render_context = context

	if context then
		if context.pipelines then render3d.pipelines = context.pipelines end

		if context.pipelines_i then render3d.pipelines_i = context.pipelines_i end
	end

	return context
end

function render3d.PopRenderContext()
	render3d.render_context_stack = render3d.render_context_stack or {}
	local state = table.remove(render3d.render_context_stack)

	if not state then return nil end

	render3d.pipelines = state.pipelines
	render3d.pipelines_i = state.pipelines_i
	render3d.active_render_context = state.context
	return render3d.active_render_context
end

function render3d.WithRenderContext(context, callback)
	render3d.PushRenderContext(context)
	local ok, a, b, c, d = xpcall(callback, debug.traceback)
	render3d.PopRenderContext()

	if not ok then error(a, 0) end

	return a, b, c, d
end

local default_passes = {
	{"light_grid", "goluwa/render3d/light_grid.lua"},
	{"gbuffer", "goluwa/render3d/passes/gbuffer.lua"},
	{"clouds", "goluwa/render3d/passes/clouds.lua"},
	{"ambient_occlusion", "goluwa/render3d/passes/ambient_occlusion.lua"},
	{"glass_tint", "goluwa/render3d/passes/glass_tint.lua"},
	{"ddgi", "goluwa/render3d/passes/ddgi.lua"},
	{"ssr", "goluwa/render3d/passes/ssr.lua"},
	{"lighting", "goluwa/render3d/passes/lighting.lua"},
	{"ocean", "goluwa/render3d/passes/ocean.lua"},
	{"volumetric_fog", "goluwa/render3d/passes/volumetric_fog.lua"},
	{"translucent", "goluwa/render3d/passes/translucent.lua"},
	{"forward_overlay", "goluwa/render3d/passes/forward_overlay.lua"},
	{"edge_aa", "goluwa/render3d/passes/edge_aa.lua"},
	{"taa", "goluwa/render3d/passes/taa.lua"},
	{"ssaa", "goluwa/render3d/passes/ssaa.lua"},
	{"fxaa", "goluwa/render3d/passes/fxaa.lua"},
	{"ambient_occlusion_debug", "goluwa/render3d/passes/ambient_occlusion_debug.lua"},
	{"normal_debug", "goluwa/render3d/passes/normal_debug.lua"},
	{"blit", "goluwa/render3d/passes/blit.lua"},
}
local pass_vars = {}
local bundle_of_pipelines = setmetatable({}, {__mode = "k"})
pvars.StartGroup("pass", {store = false})

for _, entry in ipairs(default_passes) do
	pass_vars[entry[1]] = pvars.Setup2{
		key = "r_pass_" .. entry[1],
		default = true,
		friendly = entry[1],
		help = "run the " .. entry[1] .. " pass, off skips every pipeline it adds",
		callback = function(value)
			event.Call("Render3DPassToggled", entry[1], value)
		end,
	}
end

pvars.EndGroup()

function render3d.IsBundlePassEnabled(bundle, name)
	return bundle.passes[name] == true and pass_vars[name]:Get()
end

function render3d.HasPass(name)
	return bundle_of_pipelines[render3d.pipelines].passes[name] == true
end

function render3d.IsPassEnabled(name)
	return render3d.IsBundlePassEnabled(bundle_of_pipelines[render3d.pipelines], name) and
		render3d.IsPipelineEnabled(name)
end

pvars.StartGroup("display", {store = false})
local anti_aliasing = pvars.Setup2{
	key = "r_aa",
	default = "taa",
	enums = {"taa", "edge_aa", "edge_aa_t", "fxaa", "ssaa", "none"},
	help = "taa resolves jittered frames over time, edge_aa smooths detected edges by their shape, edge_aa_t is edge_aa with two jittered frames averaged on top, fxaa blurs along high contrast edges, ssaa averages jittered frames while the camera is still, as a reference",
}
pvars.EndGroup()

function render3d.IsAntiAliasingEnabled(mode)
	if anti_aliasing:Get() ~= mode then return false end

	if mode == "edge_aa_t" then
		return render3d.IsPassEnabled("edge_aa") and render3d.IsPassEnabled("taa")
	end

	return render3d.IsPassEnabled(mode)
end

function render3d.IsTemporalAntiAliasingEnabled()
	return render3d.IsAntiAliasingEnabled("taa") or
		render3d.IsAntiAliasingEnabled("edge_aa_t") or
		render3d.IsAntiAliasingEnabled("ssaa")
end

function render3d.CreatePipelineBundle(options)
	options = options or {}
	local bundle = {
		pipelines = {},
		pipelines_i = {},
		passes = {},
		options = options,
	}
	bundle_of_pipelines[bundle.pipelines] = bundle
	local framebuffer_size = options.framebuffer_size
	local filter = options.filter
	local include_names = options.include_names
	local exclude_names = options.exclude_names or {}
	local pass_name_of_module = {}

	for _, entry in ipairs(default_passes) do
		local module = import(entry[2])
		pass_name_of_module[entry[1] == "light_grid" and module.pass or module] = entry[1]
	end

	local pass_of_config = {}
	local passes = options.passes

	if not passes then
		passes = {}

		for _, entry in ipairs(default_passes) do
			local module = import(entry[2])
			passes[#passes + 1] = entry[1] == "light_grid" and module.pass or module
		end
	end

	for _, module in ipairs(passes) do
		local pass_name = pass_name_of_module[module]

		if pass_name then
			for _, config in ipairs(list.flatten({module})) do
				pass_of_config[config] = pass_name
			end
		end
	end

	for _, source_config in ipairs(list.flatten(passes)) do
		local name = source_config.name

		if
			not exclude_names[name] and
			(
				not include_names or
				include_names[name]
			)
			and
			(
				not filter or
				filter(name, source_config) ~= false
			)
		then
			local config = table.copy(source_config)
			local pass_name = pass_of_config[source_config]

			if pass_name then
				local enabled_var = pass_vars[pass_name]
				local is_enabled = config.is_enabled
				local is_fallback = config.fallback == true
				bundle.passes[pass_name] = true
				config.is_enabled = function()
					return enabled_var:Get() ~= is_fallback and (not is_enabled or is_enabled())
				end
			end

			if framebuffer_size and not config.FramebufferSize then
				config.FramebufferSize = {
					x = framebuffer_size.x,
					y = framebuffer_size.y,
				}
			end

			local pipeline = decorate_pipeline_instance(EasyPipeline.New(config), config)
			bundle.pipelines_i[#bundle.pipelines_i + 1] = pipeline
			bundle.pipelines[name] = pipeline
		end
	end

	return bundle
end

function render3d.RemovePipelineBundle(bundle)
	remove_pipeline_bundle(bundle)
end

function render3d.RunPipelineBundle(bundle, cmd, context)
	if not bundle or not bundle.pipelines_i then return end

	local active_context = context or {}
	active_context.pipelines = bundle.pipelines
	active_context.pipelines_i = bundle.pipelines_i

	render3d.WithRenderContext(active_context, function()
		for _, pipeline in ipairs(bundle.pipelines_i) do
			if
				pipeline.draw_in_prerender and
				render3d.IsPipelineEnabled(pipeline.name) and
				(
					not pipeline.is_enabled or
					pipeline.is_enabled()
				)
			then
				pipeline:Draw(cmd)
			end
		end
	end)
end

function render3d.Initialize(config)
	render3d.initializing = true
	scene_bvh.Initialize()

	if render3d.main_pipeline_bundle then
		render3d.RemovePipelineBundle(render3d.main_pipeline_bundle)
	end

	render3d.main_pipeline_bundle = render3d.CreatePipelineBundle(config and {passes = config.passes})
	render3d.pipelines = render3d.main_pipeline_bundle.pipelines
	render3d.pipelines_i = render3d.main_pipeline_bundle.pipelines_i
	local size = render.GetRenderImageSize()
	render3d.camera:SetViewport(Rect(0, 0, size.x, size.y))
	render3d.GetMainCamera():SetJitter(Vec2(0, 0))

	event.AddListener("PreRenderPass", "render3d", function()
		if not render3d.pipelines.gbuffer then return end

		for _, pipeline in ipairs(render3d.pipelines_i) do
			if pipeline.pre_render then pipeline:pre_render() end
		end

		skinning.Dispatch(render.GetCommandBuffer())
		scene_bvh.EnsureBuilt()
		local ocean_enabled = render3d.IsOceanEnabled()
		local water_needed = render3d.IsWaterEnabled()

		for _, pipeline in ipairs(render3d.pipelines_i) do
			local is_wave_pass = pipeline.name:starts_with("ocean_waves")
			local is_ocean_pass = is_wave_pass or pipeline.name == "ocean" or pipeline.name == "ocean_resolve"

			if
				pipeline.name ~= "blit" and
				pipeline.draw_in_prerender and
				(
					not pipeline.is_enabled or
					pipeline.is_enabled()
				)
				and
				not (
					is_ocean_pass and
					not water_needed
				)
				and
				not (
					is_wave_pass and
					not ocean_enabled
				)
			then
				if is_ocean_pass and not pipeline.framebuffers then
					pipeline:RecreateFramebuffers()

					if not pipeline.config.FramebufferSize then
						pipeline:AddGlobalEvent("WindowFramebufferResized")
					end
				end

				pipeline:Draw()

				if pipeline.name == "gbuffer" then
					gpu_culling.PrepareMainViewHiZ(render.GetCommandBuffer())
				end
			end
		end
	end)

	event.AddListener("Draw", "render3d", function(dt)
		render3d.Draw(dt)
	end)

	event.AddListener("WindowFramebufferResized", "render3d", function(wnd, size)
		if render.target:IsValid() and render.target.config.offscreen then return end

		render3d.camera:SetViewport(Rect(0, 0, size.x, size.y))
	end)

	gpu_culling.Initialize()
	render3d.initializing = false
	import("goluwa/render3d/model_loader.lua")
	event.Call("Render3DInitialized")
	render3d.ready = true
end

function render3d.IsReady()
	return render3d.ready == true
end

function render3d.Shutdown()
	if render3d.main_pipeline_bundle then
		render3d.RemovePipelineBundle(render3d.main_pipeline_bundle)
		render3d.main_pipeline_bundle = nil
	end

	render3d.pipelines = {}
	render3d.pipelines_i = {}
	gpu_culling.Shutdown()
	render.GetDevice():WaitIdle()
end

function render3d.ResetState()
	render3d.main_camera = Camera3D.New()
	render3d.camera = render3d.main_camera
	render3d.camera_stack = {render3d.camera}
	render3d.world_matrix = Matrix44()
	render3d.prev_world_matrix = render3d.world_matrix
	render3d.prev_view_matrix = Matrix44()
	render3d.prev_projection_matrix = Matrix44()
	render3d.current_material = render3d.GetDefaultMaterial()
	render3d.current_polygon3d = nil
	render3d.forward_overlay_clip_plane_enabled = false
	render3d.forward_overlay_clip_plane_origin = Vec3(0, 0, 0)
	render3d.forward_overlay_clip_plane_normal = Vec3(0, 0, 1)
	render3d.environment_texture = nil
	render3d.ocean_enabled = true
	render3d.ocean_level = nil
end

function render3d.Draw(dt)
	if not render3d.pipelines.blit then return end

	local cmd = render.GetCommandBuffer()
	render3d.pipelines[render3d.IsPassEnabled("blit") and "blit" or "blit_scene"]:Draw(cmd)

	for _, pipeline in ipairs(render3d.pipelines_i) do
		if pipeline.post_draw then pipeline:post_draw(cmd, dt) end
	end

	local render_camera = render3d.GetCamera()
	render3d.prev_view_matrix = render_camera:BuildViewMatrix():Copy()
	render3d.prev_projection_matrix = render_camera:BuildUnjitteredProjectionMatrix():Copy()
	render3d.prev_elapsed_time = system.GetElapsedTime()
end

function render3d.GetPreviousElapsedTime()
	return render3d.prev_elapsed_time or system.GetElapsedTime()
end

local function get_material_upload_key(material)
	material = material or render3d.GetDefaultMaterial()
	return material.upload_cache_key or material
end

function render3d.UploadGBufferConstants()
	local material = render3d.GetMaterial()
	local pipelines = render3d.pipelines

	if material:HasHeightMap() then
		if material:HasVertexAnimation() then
			pipelines.gbuffer_anim_height_map:UploadConstants()
		else
			pipelines.gbuffer_height_map:UploadConstants()
		end
	elseif material:HasVertexAnimation() then
		pipelines.gbuffer_anim:UploadConstants()
	else
		pipelines.gbuffer:UploadConstants()
	end

	render.GetCommandBuffer():SetCullMode(material:GetCullMode())
end

function render3d.UploadTranslucentConstants(thickness)
	render3d.translucent_thickness = thickness
	render3d.translucent_pipeline:UploadConstantsBound()
	render.GetCommandBuffer():SetCullMode(render3d.GetMaterial():GetCullMode())
end

function render3d.RequestRefractionSource()
	render3d.refraction_source_requested = true
end

function render3d.ExtendTranslucentDepthRange(near, far)
	render3d.translucent_depth_near = math.min(render3d.translucent_depth_near, near)
	render3d.translucent_depth_far = math.max(render3d.translucent_depth_far, far)
end

function render3d.UploadInstancedGBufferConstants()
	if render3d.GetMaterial():HasHeightMap() then
		render3d.pipelines.gbuffer_instanced_height_map:UploadConstants()
	else
		render3d.pipelines.gbuffer_instanced:UploadConstants()
	end

	render.GetCommandBuffer():SetCullMode(render3d.GetMaterial():GetCullMode())
end

function render3d.UploadForwardOverlayConstants()
	local cmd = render.GetCommandBuffer()
	local material = render3d.GetMaterial()
	render3d.pipelines.forward_overlay:UploadConstants()
	cmd:SetCullMode(material:GetCullMode())
	cmd:SetColorBlendEnable(0, material:GetTranslucent())
	cmd:SetColorBlendEquation(0, material:GetBlendEquation())
end

do
	render3d.main_camera = render3d.main_camera or Camera3D.New()
	render3d.camera = render3d.camera or render3d.main_camera
	render3d.camera_stack = render3d.camera_stack or {render3d.camera}
	render3d.world_matrix = render3d.world_matrix or Matrix44()
	render3d.prev_world_matrix = render3d.prev_world_matrix or render3d.world_matrix
	render3d.prev_view_matrix = render3d.prev_view_matrix or Matrix44()
	render3d.prev_projection_matrix = render3d.prev_projection_matrix or Matrix44()

	function render3d.GetCamera()
		return render3d.camera
	end

	function render3d.GetMainCamera()
		return render3d.main_camera
	end

	function render3d.PushCamera(camera)
		table.insert(render3d.camera_stack, render3d.camera)
		render3d.camera = camera or Camera3D.New()
		return render3d.camera
	end

	function render3d.PopCamera()
		local camera = table.remove(render3d.camera_stack)

		if camera then render3d.camera = camera end

		return render3d.camera
	end

	function render3d.SetWorldMatrix(world, prev_world)
		render3d.world_matrix = world
		render3d.prev_world_matrix = prev_world or world
	end

	function render3d.GetWorldMatrix()
		return render3d.world_matrix
	end

	function render3d.GetPreviousWorldMatrix()
		return render3d.prev_world_matrix or render3d.world_matrix
	end

	local pv_cached = Matrix44()
	local pvm_cached = Matrix44()

	function render3d.GetProjectionViewMatrix()
		local camera = render3d.GetCamera()
		camera:BuildViewMatrix():GetMultiplied(camera:BuildProjectionMatrix(), pv_cached)
		return pv_cached
	end

	function render3d.GetProjectionViewWorldMatrix()
		local camera = render3d.GetCamera()
		render3d.world_matrix:GetMultiplied(camera:BuildViewMatrix(), pvm_cached)
		pvm_cached:GetMultiplied(camera:BuildProjectionMatrix(), pvm_cached)
		return pvm_cached
	end

	local pvm_unjittered_cached = Matrix44()

	function render3d.GetUnjitteredProjectionViewWorldMatrix()
		local camera = render3d.GetCamera()
		render3d.world_matrix:GetMultiplied(camera:BuildViewMatrix(), pvm_unjittered_cached)
		pvm_unjittered_cached:GetMultiplied(camera:BuildUnjitteredProjectionMatrix(), pvm_unjittered_cached)
		return pvm_unjittered_cached
	end

	local frustum_planes = {}
	local frustum_frame = -1

	function render3d.GetFrustumPlanes()
		local frame = system.GetFrameNumber()

		if frustum_frame == frame then return frustum_planes end

		local m = render3d.GetProjectionViewMatrix()
		local x0, x1, x2, x3 = m.m00, m.m10, m.m20, m.m30
		local y0, y1, y2, y3 = m.m01, m.m11, m.m21, m.m31
		local planes = frustum_planes
		planes[0], planes[1], planes[2], planes[3] = m.m03 + x0, m.m13 + x1, m.m23 + x2, m.m33 + x3
		planes[4], planes[5], planes[6], planes[7] = m.m03 - x0, m.m13 - x1, m.m23 - x2, m.m33 - x3
		planes[8], planes[9], planes[10], planes[11] = m.m03 + y0, m.m13 + y1, m.m23 + y2, m.m33 + y3
		planes[12], planes[13], planes[14], planes[15] = m.m03 - y0, m.m13 - y1, m.m23 - y2, m.m33 - y3
		planes[16], planes[17], planes[18], planes[19] = m.m02, m.m12, m.m22, m.m32
		planes[20], planes[21], planes[22], planes[23] = m.m03 - m.m02, m.m13 - m.m12, m.m23 - m.m22, m.m33 - m.m32

		for i = 0, 20, 4 do
			local a, b, c = planes[i], planes[i + 1], planes[i + 2]
			local len = math.sqrt(a * a + b * b + c * c)

			if len > 0 then
				local inv_len = 1.0 / len
				planes[i] = a * inv_len
				planes[i + 1] = b * inv_len
				planes[i + 2] = c * inv_len
				planes[i + 3] = planes[i + 3] * inv_len
			end
		end

		frustum_frame = frame
		return frustum_planes
	end

	function render3d.SphereInFrustum(x, y, z, radius)
		local planes = render3d.GetFrustumPlanes()

		for i = 0, 20, 4 do
			if planes[i] * x + planes[i + 1] * y + planes[i + 2] * z + planes[i + 3] < -radius then
				return false
			end
		end

		return true
	end
end

function render3d.GetLights()
	return light_components.GetInstances()
end

function render3d.SetMaterial(mat)
	render3d.current_material = mat
end

function render3d.GetMaterial()
	return render3d.current_material or render3d.GetDefaultMaterial()
end

function render3d.GetMaterialUploadKey()
	return get_material_upload_key(render3d.GetMaterial())
end

function render3d.SetCurrentPolygon3D(poly)
	render3d.current_polygon3d = poly
end

function render3d.GetCurrentPolygon3D()
	return render3d.current_polygon3d
end

function render3d.SetForwardOverlayClipPlane(origin, normal)
	if origin and normal then
		render3d.forward_overlay_clip_plane_enabled = true
		render3d.forward_overlay_clip_plane_origin = origin
		render3d.forward_overlay_clip_plane_normal = normal
		return
	end

	render3d.forward_overlay_clip_plane_enabled = false

	if not render3d.forward_overlay_clip_plane_origin then
		render3d.forward_overlay_clip_plane_origin = Vec3(0, 0, 0)
	end

	if not render3d.forward_overlay_clip_plane_normal then
		render3d.forward_overlay_clip_plane_normal = Vec3(0, 0, 1)
	end
end

function render3d.IsForwardOverlayClipPlaneEnabled()
	return render3d.forward_overlay_clip_plane_enabled == true
end

function render3d.GetForwardOverlayClipPlaneOrigin()
	return render3d.forward_overlay_clip_plane_origin or Vec3(0, 0, 0)
end

function render3d.GetForwardOverlayClipPlaneNormal()
	return render3d.forward_overlay_clip_plane_normal or Vec3(0, 0, 1)
end

do
	local default = Material.New()

	function render3d.GetDefaultMaterial()
		return default
	end
end

function render3d.SetEnvironmentTexture(texture, irradiance_texture)
	render3d.environment_texture = texture
	render3d.environment_irradiance_texture = irradiance_texture
end

function render3d.GetEnvironmentTexture()
	return context_value("environment_texture", render3d.environment_texture)
end

function render3d.GetEnvironmentIrradianceTexture()
	return context_value("environment_irradiance_texture", render3d.environment_irradiance_texture)
end

function render3d.SetOceanEnabled(enabled)
	render3d.ocean_enabled = enabled ~= false
end

function render3d.IsOceanEnabled()
	return context_bool("ocean_enabled", render3d.ocean_enabled == true)
end

function render3d.IsWaterEnabled()
	return render3d.IsOceanEnabled() or water.HasVolumes()
end

function render3d.SetOceanLevel(level)
	render3d.ocean_level = level
end

function render3d.GetOceanLevelOverride()
	return render3d.ocean_level
end

function render3d.GetOceanLevel()
	if render3d.ocean_level ~= nil then return render3d.ocean_level end

	return atmosphere.GetOceanLevel()
end

do
	local Mesh = import("goluwa/render/mesh.lua")

	function render3d.CreateMesh(vertices, indices, index_type, index_count, deduped, name)
		local ctor = deduped and Mesh.NewDeduped or Mesh.New
		return ctor(
			render3d.pipelines.gbuffer:GetVertexAttributes(),
			vertices,
			indices,
			index_type,
			index_count,
			name
		)
	end
end

return render3d
