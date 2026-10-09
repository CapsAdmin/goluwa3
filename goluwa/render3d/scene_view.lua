local objects = import("goluwa/objects/objects.lua")
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
local bundles = {}
META:GetSet("Width", 256, {callback = "InvalidateFramebuffer"})
META:GetSet("Height", 256, {callback = "InvalidateFramebuffer"})
META:GetSet("Supersample", 2)
META:GetSet("Preset", "model_preview")
META:GetSet("Environment", nil)
META:GetSet("ExposureCompensation", 0)
META:GetSet("TransparentSky", true)

function META.OnDrawGeometry(cmd, self) end

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

function META:InvalidateFramebuffer()
	if self.framebuffer then
		self.framebuffer:Remove()
		self.framebuffer = nil
	end
end

function META:OnRemove()
	self:InvalidateFramebuffer()
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

local function get_bundle(preset_name, width, height)
	local key = preset_name .. ":" .. width .. "x" .. height
	local bundle = bundles[key]

	if bundle then return bundle end

	bundle = render3d.CreatePipelineBundle{
		framebuffer_size = {x = width, y = height},
		include_names = presets[preset_name].include_names,
	}
	bundles[key] = bundle
	return bundle
end

-- records the view into cmd. false when it can't be drawn yet, because the environment is still
-- loading
function META:Render(cmd)
	local environment = self.Environment or Environment.GetShared()

	if not environment:Bake(cmd) then return false end

	local preset = presets[self.Preset]
	local ratio = self.Supersample
	local width = self.Width * ratio
	local height = self.Height * ratio
	local bundle = get_bundle(self.Preset, width, height)
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

META:Register()
return META
