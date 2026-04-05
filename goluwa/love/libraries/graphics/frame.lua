return function(ctx)
	local love = ctx.love
	local ENV = ctx.ENV
	local render = ctx.render
	local render2d = ctx.render2d

	local function get_main_surface_dimensions()
		if ENV.graphics_current_canvas then
			return ENV.graphics_current_canvas.fb:GetColorTexture():GetSize():Unpack()
		end

		local size = ctx.window.GetSize and ctx.window.GetSize() or nil

		if size and size.x and size.y and size.x > 0 and size.y > 0 then
			return size.x, size.y
		end

		if render.GetRenderImageSize then
			local render_size = render.GetRenderImageSize()

			if render_size and render_size.x and render_size.y then
				return render_size.x, render_size.y
			end
		end

		local width = render.GetWidth and render.GetWidth() or 0
		local height = render.GetHeight and render.GetHeight() or 0
		return width, height
	end

	local function begin_temporary_frame()
		if ENV.graphics_manual_frame_active then
			return render.GetCommandBuffer() ~= nil
		end

		if render.in_frame or not render.target then
			return render.GetCommandBuffer() ~= nil
		end

		render.target:WaitForPreviousFrame()

		if not render.BeginFrame() then return false end

		ENV.graphics_manual_frame_active = true
		render2d.cmd = render.GetCommandBuffer()
		return true
	end

	local function draw_clear_rect(r, g, b, a, w, h)
		local old_r, old_g, old_b, old_a = love.graphics.getColor()
		render2d.PushMatrix(nil, nil, nil, nil, nil, true)
		render2d.PushTexture(render2d.GetTexture())
		render2d.PushUV(render2d.GetUV())
		render2d.PushAlphaMultiplier(render2d.GetAlphaMultiplier())
		render2d.PushSwizzleMode(render2d.GetSwizzleMode())
		render2d.LoadIdentity()
		render2d.PushBlendMode("one", "zero", "add", "one", "zero", "add")
		render2d.SetTexture()
		render2d.SetUV()
		render2d.SetAlphaMultiplier(1)
		render2d.SetSwizzleMode(0)
		render2d.SetColor(r / 255, g / 255, b / 255, a / 255)
		render2d.DrawRectf(0, 0, w, h)
		render2d.PopBlendMode()
		render2d.PopSwizzleMode()
		render2d.PopAlphaMultiplier()
		render2d.PopUV()
		render2d.PopTexture()
		render2d.PopMatrix()
		love.graphics.setColor(old_r, old_g, old_b, old_a)
	end

	local function clear_active_target(r, g, b, a, depth, stencil)
		local cmd = render2d.cmd

		if not (cmd and cmd.ClearAttachments) then return false end

		local w, h

		if ENV.graphics_current_canvas then
			w, h = ENV.graphics_current_canvas:getDimensions()
		else
			w, h = get_main_surface_dimensions()
		end

		cmd:ClearAttachments{
			color = {r / 255, g / 255, b / 255, a / 255},
			depth = depth,
			stencil = stencil,
			w = w,
			h = h,
		}
		return true
	end

	local function get_current_depth_target_size()
		if ENV.graphics_current_canvas then
			return ENV.graphics_current_canvas:getDimensions()
		end

		return get_main_surface_dimensions()
	end

	local function get_depth_target_frame_marker()
		local canvas = ENV.graphics_current_canvas

		if canvas then return canvas, "_love_depth_initialized_frame" end

		return ENV, "graphics_screen_depth_initialized_frame"
	end

	local function mark_depth_target_initialized(frame)
		local holder, key = get_depth_target_frame_marker()
		holder[key] = frame
	end

	local function get_love_depth_clear_value(compare_mode)
		if compare_mode == "greater" or compare_mode == "gequal" then return 0 end

		return 1
	end

	local function ensure_love_depth_target_initialized(compare_mode)
		local cmd = render2d.cmd

		if not (cmd and cmd.ClearAttachments) then return end

		local frame = render.GetCurrentFrame and render.GetCurrentFrame() or nil
		local holder, key = get_depth_target_frame_marker()

		if frame ~= nil and holder[key] == frame then return end

		local w, h = get_current_depth_target_size()
		cmd:ClearAttachments{
			depth = get_love_depth_clear_value(compare_mode),
			w = w,
			h = h,
		}

		if frame ~= nil then mark_depth_target_initialized(frame) end
	end

	local function clear_love_stencil_target(value)
		local cmd = render2d.cmd

		if not (cmd and cmd.ClearAttachments) then return end

		local w, h = get_current_depth_target_size()
		cmd:ClearAttachments{
			stencil = value or 0,
			w = w,
			h = h,
		}
	end

	render2d.on_missing_command = begin_temporary_frame
	ctx.get_main_surface_dimensions = get_main_surface_dimensions
	ctx.begin_temporary_frame = begin_temporary_frame
	ctx.draw_clear_rect = draw_clear_rect
	ctx.clear_active_target = clear_active_target
	ctx.mark_depth_target_initialized = mark_depth_target_initialized
	ctx.ensure_love_depth_target_initialized = ensure_love_depth_target_initialized
	ctx.clear_love_stencil_target = clear_love_stencil_target

	function love.graphics.present()
		if not ENV.graphics_manual_frame_active then return end

		render.EndFrame()
		render2d.cmd = nil
		ENV.graphics_manual_frame_active = false
	end

	function love.graphics.setIcon() end
end
