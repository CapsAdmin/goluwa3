local event = import("goluwa/event.lua")
local Quat = import("goluwa/structs/quat.lua")

-- Overrides the 3d camera for the duration of a screenshot. Player controllers
-- re-assert the camera on every Update (before the frame is rendered), so the
-- override is re-applied on PreFrame, which fires inside render.Draw after
-- them. Returns a function that removes the override and restores the camera.
local function setup_camera_override(camera)
	local render3d = import("goluwa/render3d/render3d.lua")

	if not render3d.IsReady() then
		error("Screenshot: camera option requires 3d rendering", 2)
	end

	local cam = render3d.GetCamera()
	local saved = {
		position = cam:GetPosition():Copy(),
		rotation = cam:GetRotation():Copy(),
		fov = cam:GetFOV(),
	}
	local rotation = camera.rotation

	if rotation then
		local meta = getmetatable(rotation)

		if meta and meta.ClassName == "Ang3" then
			rotation = Quat():SetAngles(rotation)
		end
	end

	local function apply()
		if camera.position then cam:SetPosition(camera.position) end

		if rotation then cam:SetRotation(rotation) end

		if camera.fov then cam:SetFOV(camera.fov) end
	end

	local remove = event.AddListener("PreFrame", "screenshot_camera_override", apply)
	return function()
		remove()
		cam:SetPosition(saved.position)
		cam:SetRotation(saved.rotation)
		cam:SetFOV(saved.fov)
	end
end

-- Screenshot(cb, opt)
--
-- Captures the rendered screen and calls cb(texture) with a TextureDownloaded
-- whose pixels are ready (:GetPixel, :ToPNG, :Save all work).
--
-- opt:
--   update_events = n  -- run n Update events (dt = 1/60) before capturing.
--                       -- UI layout resolves over a few Update events, so use
--                       -- this when screenshotting UI.
--   midframe = true    -- capture immediately with render.Capture() instead of
--                       -- at the end of the frame. Must be called from inside
--                       -- a frame (e.g. a Draw or Draw2D listener). Cannot be
--                       -- combined with camera.
--   camera = {         -- 3d only: capture from this camera instead of the
--       position = Vec3,      -- current one. The original camera is restored
--       rotation = Quat|Ang3, -- after the capture. Cannot be combined with
--       fov = radians,        -- midframe.
--   }
--
-- Without midframe, the capture happens at the end of the next frame (or the
-- current frame if called mid-frame), so everything drawn up to that point
-- (including the UI) is included. With camera, the capture is always a frame
-- rendered with the override, so a mid-frame call waits for the next frame.
--
-- Examples:
--   Screenshot(function(texture)
--       print(texture:Save(nil, true)) -- save to storage/logs/screenshots/
--   end)
--
--   Screenshot(function(texture)
--       print(texture:Save("storage/logs/my_ui.png"))
--   end, {update_events = 3})
--
--   Screenshot(function(texture)
--       print(texture:Save("storage/logs/from_here.png"))
--   end, {camera = {position = Vec3(0, 5, 0), rotation = QuatDeg3(45, 0, 0)}})
function Screenshot(cb, opt)
	opt = opt or {}
	local render = import("goluwa/render/render.lua")

	if not render.available then
		error("Screenshot: rendering is not available (headless mode)", 2)
	end

	local camera_restore

	if opt.camera then camera_restore = setup_camera_override(opt.camera) end

	local function finish(texture)
		if camera_restore then
			camera_restore()
			camera_restore = nil
		end

		cb(texture)
	end

	local function capture_swapchain()
		-- called at PostRenderPass: the frame's command buffer is still
		-- recording, so the copy is recorded before present and the pixels are
		-- read once the frame is submitted
		local texture = render.target:GetTexture():Download()

		event.AddListener("FrameEnd", function()
			texture:Resolve()
			finish(texture)
		end)
	end

	local function schedule()
		-- with a camera override, the current frame (if any) was already
		-- rendered with the old camera; wait for the next frame
		if camera_restore and render.cmd then
			event.AddListener("FrameEnd", function()
				schedule()
			end)

			return
		end

		if render.target.config.offscreen then
			-- the frame's command buffer is only submitted at the end of
			-- EndFrame, so wait for FrameEnd before downloading
			event.AddListener("FrameEnd", function()
				finish(render.target:GetTexture():Download())
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
			if opt.camera then
				if camera_restore then
					camera_restore()
					camera_restore = nil
				end

				error(
					"Screenshot: camera cannot be combined with midframe (the 3d frame is already rendered)",
					2
				)
			end

			local texture = render.Capture()

			if not texture then
				error(
					"Screenshot: midframe capture must be called during a frame (e.g. inside a Draw or Draw2D listener)",
					2
				)
			end

			return finish(texture)
		end

		schedule()
	end

	if not render.IsInitialized() then
		if not (RENDER_2D or RENDER_3D) then
			error("Screenshot: rendering is disabled (headless mode)", 2)
		end

		-- rendering initializes after the user script runs (e.g. the
		-- --screenshot flag), so wait for the first frame
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
