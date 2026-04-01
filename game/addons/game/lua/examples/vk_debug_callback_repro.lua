local jit = require("jit")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local repro_fb
local wrong_pipeline
local safe_pipeline
local triggered = false

local function issue_draw(cmd, pipeline, r, g, b)
	pipeline:Bind(cmd, render.GetCurrentFrame())
	render2d.BindMesh(render2d.rect_mesh)
	render2d.SetTexture(nil)
	render2d.SetColor(r, g, b, 1)
	render2d.UploadConstants(cmd, 64, 64, 64, 64)
	render2d.rect_mesh:DrawIndexed(cmd, 6)
end

local function ensure_resources()
	if repro_fb then return end

	render2d.Initialize()
	wrong_pipeline = render2d.pipeline
	repro_fb = Framebuffer.New{
		width = 64,
		height = 64,
		format = "r8g8b8a8_unorm",
		clear_color = {0, 0, 0, 1},
	}

	do
		local previous_cmd = render2d.cmd
		local cmd = repro_fb:Begin()
		render2d.cmd = cmd
		render2d.BindPipeline(cmd)
		safe_pipeline = render2d.pipeline
		repro_fb:End(cmd)
		render2d.cmd = previous_cmd
	end
end

event.AddListener("Draw2D", "vk_debug_callback_repro", function()
	if triggered then return end

	ensure_resources()
	triggered = true
	local previous_cmd = render2d.cmd
	jit.flush(issue_draw)

	do
		local warm_cmd = repro_fb:Begin()
		render2d.cmd = warm_cmd
		render2d.ResetState()

		for i = 1, 128 do
			issue_draw(warm_cmd, safe_pipeline, (i % 3) / 2, ((i + 1) % 3) / 2, ((i + 2) % 3) / 2)
		end

		repro_fb:End(warm_cmd)
	end

	do
		local bad_cmd = repro_fb:Begin()
		render2d.cmd = bad_cmd
		render2d.ResetState()
		-- Intentionally reuse the swapchain pipeline after the helper above has
		-- already gone hot under LuaJIT on the matching UNORM pipeline.
		issue_draw(bad_cmd, wrong_pipeline, 1, 0, 0)
		repro_fb:End(bad_cmd)
	end

	render2d.cmd = previous_cmd
	triggered = true
end)
