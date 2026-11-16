local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Texture = import("goluwa/render/texture.lua")
local render = import("goluwa/render/render.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local frame_generation = {}
local pipelines = {}
local history
local history_valid = false
local draw_state = {}

local function get_pipeline(format)
	if pipelines[format] then return pipelines[format] end

	pipelines[format] = EasyPipeline.New{
		name = "frame_generation_compose",
		dont_create_framebuffers = true,
		ColorFormat = {{format, {"color", "rgba"}}},
		RasterizationSamples = "1",
		Blend = false,
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		fragment = {
			push_constants = {
				{
					name = "compose_data",
					block = {
						{"scene_tex", "int"},
						{"history_tex", "int"},
						{"ui_tex", "int"},
						{"generated", "int"},
					},
					write = function(self, block)
						block.scene_tex = self:GetTextureIndex(draw_state.scene)
						block.history_tex = self:GetTextureIndex(history)
						block.ui_tex = self:GetTextureIndex(draw_state.ui)
						block.generated = draw_state.generated and 1 or 0
						return block
					end,
				},
			},
			shader = [[
				void main() {
					ivec2 pixel = ivec2(gl_FragCoord.xy);
					vec3 scene = texelFetch(TEXTURE(compose_data.scene_tex), pixel, 0).rgb;

					if (compose_data.generated != 0) {
						scene = mix(texelFetch(TEXTURE(compose_data.history_tex), pixel, 0).rgb, scene, 0.5);
					}

					vec4 ui = texelFetch(TEXTURE(compose_data.ui_tex), pixel, 0);
					set_color(vec4(scene * (1.0 - ui.a) + ui.rgb, 1.0));
				}
			]],
		},
	}
	return pipelines[format]
end

local function draw(cmd, target, generated)
	local size = target:GetSize()
	draw_state.generated = generated
	render.TransitionResourceTo(
		target:GetImage(),
		"color_attachment_optimal",
		{
			cmd = cmd,
			srcStage = "all_commands",
			srcAccess = "none",
			dstStage = "color_attachment_output",
			dstAccess = "color_attachment_write",
		}
	)
	cmd:BeginRendering{
		color_image_view = target:GetView(),
		w = size.x,
		h = size.y,
		load_op = "dont_care",
	}
	get_pipeline(target:GetFormat()):Draw(cmd)
	cmd:EndRendering()
end

local function ensure_history(scene)
	local size = scene:GetSize()

	if history and history:GetSize() == size then return end

	if history then history:Remove() end

	history = Texture.New{
		width = size.x,
		height = size.y,
		format = scene:GetFormat(),
		image = {
			usage = {"sampled", "transfer_dst"},
			properties = "device_local",
		},
		sampler = {min_filter = "nearest", mag_filter = "nearest"},
	}
	history:SetDebugName("frame generation history")
	history_valid = false
end

function frame_generation.Compose(cmd, ui, generated, real)
	local scene = render3d.pipelines.blit_compute:GetFramebuffer():GetAttachment(1)
	ensure_history(scene)
	draw_state.scene = scene
	draw_state.ui = ui
	render.TransitionResourceToShaderRead(scene, {cmd = cmd, srcStage = "all_commands"})
	render.TransitionResourceToShaderRead(ui, {cmd = cmd, srcStage = "color_attachment_output"})
	render.TransitionResourceToShaderRead(history, {cmd = cmd, srcStage = "transfer"})
	local present_generated = history_valid and not render3d.IsCameraCut()

	if present_generated then draw(cmd, generated, true) end

	draw(cmd, real, false)
	render.TransitionResourceTo(
		scene:GetImage(),
		"transfer_src_optimal",
		{cmd = cmd, srcStage = "fragment", dstStage = "transfer"}
	)
	render.TransitionResourceTo(
		history:GetImage(),
		"transfer_dst_optimal",
		{cmd = cmd, srcStage = "fragment", dstStage = "transfer"}
	)
	local size = scene:GetSize()
	cmd:CopyImageToImage{
		src_image = scene:GetImage(),
		dst_image = history:GetImage(),
		width = size.x,
		height = size.y,
	}
	history_valid = true
	draw_state.scene = nil
	draw_state.ui = nil
	return present_generated
end

function frame_generation.IsEnabled()
	return render.target:GetFramePacer() ~= nil
end

pvars.StartGroup("Rendering", "Frame generation", {store = false})
local enabled = pvars.Setup2{
	key = "r_frame_generation",
	default = false,
	help = "present a frame generated between every two rendered ones, paced to the middle of the rendered frame time by a present thread, which doubles the presented frame rate at the cost of half a rendered frame of latency. the 2d ui is drawn once per rendered frame on its own layer and composited over both",
	callback = function(value)
		if not render3d.IsReady() then return end

		history_valid = false
		render.target:SetFrameGeneration(value and frame_generation.Compose or nil)
	end,
}
pvars.EndGroup()

event.AddListener("Render3DInitialized", "frame_generation", function()
	if enabled:Get() then
		render.target:SetFrameGeneration(frame_generation.Compose)
	end
end)

return frame_generation
