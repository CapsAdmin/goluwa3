local event = import("goluwa/event.lua")

function Screenshot(cb, opt)
	opt = opt or {}
	local render = import("goluwa/render/render.lua")

	if not render.available then
		error("Screenshot: rendering is not available (headless mode)", 2)
	end

	local function capture_swapchain()
		local texture = render.target:GetTexture():Download()

		event.AddListener("FrameEnd", function()
			texture:Resolve()
			cb(texture)
		end)
	end

	local function schedule()
		if render.target.config.offscreen then
			event.AddListener("FrameEnd", function()
				cb(render.target:GetTexture():Download())
			end)

			return
		end

		event.AddListener("PostRenderPass", capture_swapchain)
	end

	local function capture()
		if opt.update_events then
			for i = 1, opt.update_events do
				event.Call("Update", 1 / 60)
			end
		end

		if opt.midframe then
			local texture = render.Capture()

			if not texture then
				error(
					"Screenshot: midframe capture must be called during a frame (e.g. inside a Draw or Draw2D listener)",
					2
				)
			end

			return cb(texture)
		end

		schedule()
	end

	if not render.IsInitialized() then
		if not (RENDER_2D or RENDER_3D) then
			error("Screenshot: rendering is disabled (headless mode)", 2)
		end

		event.AddListener("PostRenderPass", function()
			if render.target.config.offscreen then
				schedule()
			else
				capture_swapchain()
			end
		end)

		return
	end

	capture()
end
