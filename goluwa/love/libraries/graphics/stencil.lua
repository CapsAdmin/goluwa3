return function(ctx)
	local love = ctx.love
	local ENV = ctx.ENV
	local render2d = ctx.render2d
	local clear_love_stencil_target = ctx.clear_love_stencil_target

	function love.graphics.newStencil(func) end

	function love.graphics.setStencil(func) end

	function love.graphics.setStencilTest(mode, val)
		if mode then
			ENV.graphics_stencil_mode = mode
			ENV.graphics_stencil_val = val

			if mode == "always" then
				render2d.SetStencilMode("none", 0)
			elseif mode == "equal" then
				render2d.SetStencilMode("test", val)
			elseif mode == "greater" and val == 0 then
				render2d.SetStencilMode("test_inverse", val)
			else
				error("unsupported stencil test mode: " .. tostring(mode), 2)
			end
		else
			ENV.graphics_stencil_mode = "always"
			ENV.graphics_stencil_val = 0
			render2d.SetStencilMode("none", 0)
		end
	end

	function love.graphics.getStencilTest()
		return ENV.graphics_stencil_mode or "always", ENV.graphics_stencil_val or 0
	end

	function love.graphics.stencil(func, action, num, keep)
		action = action or "replace"
		num = num or 1

		if action ~= "replace" then
			error("unsupported stencil action: " .. tostring(action), 2)
		end

		if not keep then clear_love_stencil_target(0) end

		local old_mode, old_val = love.graphics.getStencilTest()
		local old_r, old_g, old_b, old_a = love.graphics.getColor()
		render2d.SetStencilMode("write", num)
		love.graphics.setColor(old_r, old_g, old_b, 0)
		render2d.PushBlendMode("zero", "one", "add", "zero", "one", "add")
		func()
		render2d.PopBlendMode()
		love.graphics.setColor(old_r, old_g, old_b, old_a)
		love.graphics.setStencilTest(old_mode, old_val)
	end
end
