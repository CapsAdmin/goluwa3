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
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local envprobe = import("goluwa/render3d/envprobe.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local light_components = import("goluwa/entities/components/light.lua")

local function decorate_pipeline_instance(pipeline, config)
	pipeline.name = config.name
	pipeline.pre_render = config.pre_render
	pipeline.post_draw = config.post_draw
	pipeline.draw_in_prerender = config.draw_in_prerender ~= false
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

render3d.camera_block = {
	{"inv_view", "mat4"},
	{"inv_projection", "mat4"},
	{"view", "mat4"},
	{"projection", "mat4"},
	{"render_size", "vec2"},
	{"camera_position", "vec3"},
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
	return block
end

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

render3d.velocity_enabled = render3d.velocity_enabled ~= false
-- Material emissive multipliers are relative; this is the luminance a
-- multiplier of 1 stands for. Anything that shades emissive surfaces itself
-- (the gbuffer, GI hit shading) must scale by the same amount.
render3d.EMISSIVE_REFERENCE_LUMINANCE = 2000.0
-- the largest value the gbuffer's b10g11r11 emissive target can hold
render3d.EMISSIVE_MAX_LUMINANCE = 64512.0

function render3d.GetEmissiveGLSL()
	return (
		"const float EMISSIVE_REFERENCE_LUMINANCE = %.1f;\nconst float EMISSIVE_MAX_LUMINANCE = %.1f;\n"
	):format(render3d.EMISSIVE_REFERENCE_LUMINANCE, render3d.EMISSIVE_MAX_LUMINANCE)
end

function render3d.SetVelocityEnabled(enabled)
	render3d.velocity_enabled = enabled ~= false
end

function render3d.IsVelocityEnabled()
	return render3d.velocity_enabled
end

render3d.gbuffer_block = {
	{"albedo_tex", "int"},
	{"normal_tex", "int"},
	{"mra_tex", "int"},
	{"emissive_tex", "int"},
	{"transmission_tex", "int"},
	{"depth_tex", "int"},
	{"velocity_tex", "int"},
}

function render3d.WriteGBufferBlock(self, block)
	local framebuffer = render3d.pipelines.gbuffer:GetFramebuffer()
	block.albedo_tex = self:GetTextureIndex(framebuffer:GetAttachment(1))
	block.normal_tex = self:GetTextureIndex(framebuffer:GetAttachment(2))
	block.mra_tex = self:GetTextureIndex(framebuffer:GetAttachment(3))
	block.emissive_tex = self:GetTextureIndex(framebuffer:GetAttachment(4))
	block.transmission_tex = self:GetTextureIndex(framebuffer:GetAttachment(5))
	block.depth_tex = self:GetTextureIndex(framebuffer:GetDepthTexture())
	block.velocity_tex = render3d.velocity_enabled and
		self:GetTextureIndex(framebuffer:GetAttachment(6)) or
		-1
	return block
end

-- How the gbuffer pass packs its targets (see its ColorFormat), for the
-- shaders writing them
function render3d.GetGBufferEncodeGLSL()
	return [[
		vec3 gbuffer_encode_normal(vec3 N) {
			return N * 0.5 + 0.5;
		}

		// a multiplier of 1 is dielectric F0 0.04; up to 2 fits
		float gbuffer_encode_specular(float multiplier) {
			return clamp(multiplier * 0.5, 0.0, 1.0);
		}

		// red and blue, halved to fit up to 2. the tint's luminance is 1, which
		// gives the green back
		vec2 gbuffer_encode_transmission_tint(vec3 tint) {
			return tint.rb * 0.5;
		}
	]]
end

do
	local decoders = [[
		vec3 gbuffer_albedo(COORD c) { return gbuffer_fetch(GBUFFER.albedo_tex, c).rgb; }
		float gbuffer_alpha(COORD c) { return gbuffer_fetch(GBUFFER.albedo_tex, c).a; }
		float gbuffer_depth(COORD c) { return gbuffer_fetch(GBUFFER.depth_tex, c).r; }
		vec3 gbuffer_normal(COORD c) { return gbuffer_fetch(GBUFFER.normal_tex, c).xyz * 2.0 - 1.0; }
		float gbuffer_metallic(COORD c) { return gbuffer_fetch(GBUFFER.mra_tex, c).r; }
		// ggx alpha
		float gbuffer_roughness(COORD c) { return gbuffer_fetch(GBUFFER.mra_tex, c).g; }
		float gbuffer_ao(COORD c) { return gbuffer_fetch(GBUFFER.mra_tex, c).b; }
		float gbuffer_transmission(COORD c) { return gbuffer_fetch(GBUFFER.mra_tex, c).a; }
		vec3 gbuffer_emissive(COORD c) { return gbuffer_fetch(GBUFFER.emissive_tex, c).rgb; }
		float gbuffer_transmission_scattering(COORD c) { return gbuffer_fetch(GBUFFER.transmission_tex, c).r; }
		float gbuffer_dielectric_f0(COORD c) { return gbuffer_fetch(GBUFFER.transmission_tex, c).b * 0.08; }

		vec3 gbuffer_transmission_color(COORD c) {
			vec4 packed = gbuffer_fetch(GBUFFER.transmission_tex, c);
			float r = packed.g * 2.0;
			float b = packed.a * 2.0;
			return vec3(r, max((1.0 - 0.2126 * r - 0.0722 * b) / 0.7152, 0.0), b);
		}
	]]
	local code = [[
		vec4 gbuffer_fetch(int tex, vec2 uv) {
			return texture(TEXTURE(tex), uv);
		}

		vec4 gbuffer_fetch(int tex, ivec2 pixel) {
			return texelFetch(TEXTURE(tex), pixel, 0);
		}
	]] .. decoders:gsub("COORD", "vec2") .. decoders:gsub("COORD", "ivec2")

	-- Reading what render3d.GetGBufferEncodeGLSL packed, at a uv or a pixel.
	-- block_name is the uniform block holding render3d.gbuffer_block
	function render3d.GetGBufferGLSL(block_name)
		return (code:gsub("GBUFFER%.", block_name .. "."))
	end
end

render3d.last_frame_block = {
	{"last_frame_tex", "int"},
}

function render3d.WriteLastFrameBlock(self, block)
	if not render3d.ShouldUseLastFrameHistory() then
		block.last_frame_tex = -1
		return block
	end

	if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
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

	-- prev_projection_matrix is stored without jitter. It is handed out with
	-- this frame's jitter applied, so reprojecting through it and the current
	-- projection cancels the jitter and leaves only the motion
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

function render3d.CreatePipelineBundle(options)
	options = options or {}
	local bundle = {
		pipelines = {},
		pipelines_i = {},
		options = options,
	}
	local framebuffer_size = options.framebuffer_size
	local filter = options.filter
	local include_names = options.include_names
	local exclude_names = options.exclude_names or {}
	local passes = options.passes or
		{
			import("goluwa/render3d/light_grid.lua").pass,
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/ambient_occlusion.lua"),
			import("goluwa/render3d/passes/ddgi.lua"),
			import("goluwa/render3d/passes/ssr.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/ocean.lua"),
			import("goluwa/render3d/passes/volumetric_fog.lua"),
			import("goluwa/render3d/passes/translucent.lua"),
			import("goluwa/render3d/passes/forward_overlay.lua"),
			import("goluwa/render3d/passes/taa.lua"),
			import("goluwa/render3d/passes/bloom.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		}

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
			if pipeline.draw_in_prerender and render3d.IsPipelineEnabled(pipeline.name) then
				pipeline:Draw(cmd)
			end
		end
	end)
end

function render3d.Initialize(config)
	render3d.initializing = true

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

		scene_bvh.EnsureBuilt()
		local ocean_needed = render3d.IsOceanEnabled()

		for _, pipeline in ipairs(render3d.pipelines_i) do
			local is_ocean_pass = pipeline.name == "ocean" or
				pipeline.name == "ocean_resolve" or
				pipeline.name == "ocean_waves" or
				pipeline.name == "ocean_waves_near"

			if
				pipeline.name ~= "blit" and
				pipeline.draw_in_prerender and
				not (
					is_ocean_pass and
					not ocean_needed
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

	if gpu_culling.Shutdown then gpu_culling.Shutdown() end

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
	-- render to the screen
	render3d.pipelines.blit:Draw(cmd)

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
	local pipeline = material:HasVertexAnimation() and
		render3d.pipelines.gbuffer_anim or
		render3d.pipelines.gbuffer
	pipeline:UploadConstants()
	render.GetCommandBuffer():SetCullMode(material:GetCullMode())
end

-- translucent entries draw twice, once into the moments and once lit, with
-- whichever pipeline the translucent pass is at. a refracting draw's thickness
-- is what its material says, or its thinnest extent when the material leaves
-- it to the object
function render3d.UploadTranslucentConstants(thickness)
	render3d.translucent_thickness = thickness
	render3d.translucent_pipeline:UploadConstants()
	render.GetCommandBuffer():SetCullMode(render3d.GetMaterial():GetCullMode())
end

-- a refracting material is about to draw, so the translucent pass builds the
-- blurred scene it looks through
function render3d.RequestRefractionSource()
	render3d.refraction_source_requested = true
end

-- the distances from the camera the translucent surfaces drawn this frame
-- span, which the translucent pass fits its depth precision to
function render3d.ExtendTranslucentDepthRange(near, far)
	render3d.translucent_depth_near = math.min(render3d.translucent_depth_near, near)
	render3d.translucent_depth_far = math.max(render3d.translucent_depth_far, far)
end

function render3d.UploadInstancedGBufferConstants()
	render3d.pipelines.gbuffer_instanced:UploadConstants()
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

	-- the camera the screen is rendered from, driven by the active view (see
	-- view.lua); GetCamera is whichever camera is pushed while rendering
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
		-- ORIENTATION / TRANSFORMATION: Coordinate system defined in orientation.lua
		-- Row-major: v * V * P
		local camera = render3d.GetCamera()
		camera:BuildViewMatrix():GetMultiplied(camera:BuildProjectionMatrix(), pv_cached)
		return pv_cached
	end

	function render3d.GetProjectionViewWorldMatrix()
		-- ORIENTATION / TRANSFORMATION: Coordinate system defined in orientation.lua
		-- Row-major: v * W * V * P
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

do -- mesh
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
