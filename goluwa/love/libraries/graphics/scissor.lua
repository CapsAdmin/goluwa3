return function(ctx)
	local love = ctx.love
	local ENV = ctx.ENV
	local render2d = ctx.render2d

	function love.graphics.setScissor(x, y, w, h)
		if x == nil then
			ENV.scissor = nil
			local sw, sh = render2d.GetSize()
			render2d.SetScissor(0, 0, sw or 0, sh or 0)
			return
		end

		ENV.scissor = {x = x or 0, y = y or 0, w = w or 0, h = h or 0}
		render2d.SetScissor(ENV.scissor.x, ENV.scissor.y, ENV.scissor.w, ENV.scissor.h)
	end

	function love.graphics.getScissor()
		if not ENV.scissor then return end

		return ENV.scissor.x, ENV.scissor.y, ENV.scissor.w, ENV.scissor.h
	end

	function love.graphics.intersectScissor(x, y, w, h)
		if x == nil then
			love.graphics.setScissor()
			return
		end

		local scx, scy, scw, sch = love.graphics.getScissor()

		if scx == nil then
			love.graphics.setScissor(x, y, w, h)
			return
		end

		local left = math.max(scx, x)
		local top = math.max(scy, y)
		local right = math.min(scx + scw, x + w)
		local bottom = math.min(scy + sch, y + h)
		local width = math.max(0, right - left)
		local height = math.max(0, bottom - top)
		love.graphics.setScissor(left, top, width, height)
	end
end
