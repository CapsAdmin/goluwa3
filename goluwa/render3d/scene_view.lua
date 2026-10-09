local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Camera3D = import("goluwa/render3d/camera3d.lua")
local Environment = import("goluwa/render3d/environment.lua")
local view_resolve = import("goluwa/render3d/view_resolve.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local META = objects.CreateTemplate("render3d_scene_view")
-- a preset is the passes a view runs, and the render context that makes them see what the view
-- should see instead of the world. views of a size share one set of pipelines per preset, so a
-- preset that keeps history between frames needs a set of its own per view
local presets = {
	model_preview = {
		include_names = {
			gbuffer = true,
			gbuffer_anim = true,
			gbuffer_height_map = true,
			gbuffer_anim_height_map = true,
			ambient_occlusion = true,
			ambient_occlusion_temporal = true,
			ambient_occlusion_blur = true,
			lighting = true,
		},
		context = {
			lights = {},
			ocean_enabled = false,
			allow_envprobe = false,
			allow_probe_reflections = false,
			allow_last_frame_history = false,
		},
	},
}
local BUNDLE_IDLE_SECONDS = 5
local release_bundle
local bundles = {}
local invalidated = {}
META:GetSet("Width", 256, {callback = "InvalidateFramebuffer"})
META:GetSet("Height", 256, {callback = "InvalidateFramebuffer"})
META:GetSet("Supersample", 2, {callback = "Invalidate"})
META:GetSet("Preset", "model_preview", {callback = "Invalidate"})
META:GetSet("Environment", nil, {callback = "Invalidate"})
META:GetSet("ExposureCompensation", 0, {callback = "Invalidate"})
META:GetSet("TransparentSky", true, {callback = "Invalidate"})
META:GetSet("AutoRender", false, {callback = "Invalidate"})

function META.OnDrawGeometry(cmd, self) end

-- draws what a visual has for the gbuffer, whether it is visible in the world or not
function META.DrawVisual(visual)
	local previous_world = render3d.GetWorldMatrix()
	local previous_material = render3d.GetMaterial()
	visual:DrawEntriesForPass(false, render3d.UploadGBufferConstants)
	render3d.SetWorldMatrix(previous_world)
	render3d.SetCurrentPolygon3D(nil)
	render3d.SetMaterial(previous_material)
end

function META.New(config)
	local self = META:CreateObject()
	self.camera = Camera3D.New()
	local context = {render_size = Vec2(1, 1)}
	self.context = context

	function context.draw_geometry(cmd)
		self.OnDrawGeometry(cmd, self)
	end

	if config then
		for k, v in pairs(config) do
			local setter = self["Set" .. k]

			if setter then setter(self, v) else self[k] = v end
		end
	end

	return self
end

function META:GetCamera()
	return self.camera
end

-- with AutoRender the view is drawn in the next frame, by the frame's own command buffer, so what
-- changed it doesn't have to wait for the gpu
function META:Invalidate()
	if self.AutoRender then invalidated[self] = true end
end

function META:InvalidateFramebuffer()
	if self.framebuffer then
		self.framebuffer:Remove()
		self.framebuffer = nil
	end

	self.rendered = false
	self:Invalidate()
end

function META.GetBundleCount()
	local count = 0

	for _ in pairs(bundles) do
		count = count + 1
	end

	return count
end

-- false until the first render, before that the texture holds nothing to show
function META:HasRendered()
	return self.rendered
end

function META:OnRemove()
	self:InvalidateFramebuffer()
	invalidated[self] = nil

	if self.bundle then release_bundle(self.bundle) end

	self.camera = nil
	self.context = nil
end

function META:EnsureFramebuffer()
	if self.framebuffer then return self.framebuffer end

	self.framebuffer = Framebuffer.New{
		name = "scene view",
		width = self.Width,
		height = self.Height,
		format = "r8g8b8a8_srgb",
		clear_color = {0, 0, 0, 0},
	}
	return self.framebuffer
end

function META:GetTexture()
	return self:EnsureFramebuffer():GetColorTexture()
end

local function acquire_bundle(key, preset_name, width, height)
	local bundle = bundles[key]

	if not bundle then
		bundle = render3d.CreatePipelineBundle{
			framebuffer_size = {x = width, y = height},
			include_names = presets[preset_name].include_names,
		}
		bundle.users = 0
		bundles[key] = bundle
	end

	bundle.users = bundle.users + 1
	bundle.idle_since = nil
	return bundle
end

function release_bundle(bundle)
	bundle.users = bundle.users - 1

	if bundle.users == 0 then bundle.idle_since = system.GetElapsedTime() end
end

-- records the view into cmd. false when it can't be drawn yet, because the environment is still
-- loading
function META:Render(cmd)
	local environment = self.Environment or Environment.GetShared()

	if not environment:Bake(cmd) then
		self:Invalidate()
		return false
	end

	local preset = presets[self.Preset]
	local ratio = self.Supersample
	local width = self.Width * ratio
	local height = self.Height * ratio
	local key = self.Preset .. ":" .. width .. "x" .. height

	if self.bundle_key ~= key then
		if self.bundle then release_bundle(self.bundle) end

		self.bundle = acquire_bundle(key, self.Preset, width, height)
		self.bundle_key = key
	end

	local bundle = self.bundle
	local camera = self.camera
	local context = self.context
	camera:SetViewport(Rect(0, 0, width, height))
	table.merge(context, preset.context)
	context.render_size.x = width
	context.render_size.y = height
	context.camera = camera
	context.environment = environment
	context.transparent_sky = self.TransparentSky
	context.prev_view_matrix = camera:BuildViewMatrix()
	context.prev_projection_matrix = camera:BuildUnjitteredProjectionMatrix()
	render3d.RunPipelineBundle(bundle, cmd, context)
	view_resolve.Draw(
		cmd,
		self:EnsureFramebuffer(),
		bundle.pipelines.lighting:GetFramebuffer(1):GetAttachment(1),
		ratio,
		environment:GetExposure() * 2 ^ self.ExposureCompensation
	)
	self.rendered = true
	return true
end

-- for callers that need the result right away, like reading the pixels back. every call records
-- into a new command buffer, compute passes hand out their descriptor sets per command buffer
function META:RenderNow()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd.gpu_timing_disabled = true
	cmd:Begin()
	local ok, rendered = xpcall(self.Render, debug.traceback, self, cmd)
	cmd:End()
	render.SubmitAndWait(cmd)
	cmd:Remove()

	if not ok then error(rendered, 0) end

	return rendered
end

do
	local pending = {}

	event.AddListener("PreRenderPass", "render3d_scene_views", function()
		local now = system.GetElapsedTime()

		for key, bundle in pairs(bundles) do
			if bundle.idle_since and now - bundle.idle_since > BUNDLE_IDLE_SECONDS then
				bundles[key] = nil
				render3d.RemovePipelineBundle(bundle)
			end
		end

		local cmd = render.GetCommandBuffer()
		local count = 0

		for view in pairs(invalidated) do
			count = count + 1
			pending[count] = view
			invalidated[view] = nil
		end

		for i = 1, count do
			local view = pending[i]
			pending[i] = nil

			if cmd then view:Render(cmd) end
		end
	end)
end

META:Register()
return META
