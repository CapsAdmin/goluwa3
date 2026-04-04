return function(ctx)
	local love = ctx.love
	local render2d = ctx.render2d
	local ensure_love_depth_target_initialized = ctx.ensure_love_depth_target_initialized

	function love.graphics.setDepthMode(compare_mode, write)
		if not compare_mode then
			render2d.SetDepthMode("none", false)
			return
		end

		render2d.SetDepthMode(compare_mode, write)
		ensure_love_depth_target_initialized(compare_mode)
	end

	function love.graphics.getDepthMode()
		local compare_mode, write = render2d.GetDepthMode()

		if compare_mode == "none" then return nil, false end

		return compare_mode, write
	end

	function love.graphics.isSupported(what)
		llog("is supported: %s", what)
		return true
	end

	do
		local COLOR_MODE = "alpha"
		local ALPHA_MODE = "alphamultiply"

		function love.graphics.setBlendMode(color_mode, alpha_mode)
			alpha_mode = alpha_mode or "alphamultiply"
			local func = "add"
			local srcRGB = "one"
			local srcA = "one"
			local dstRGB = "zero"
			local dstA = "zero"

			if color_mode == "alpha" then
				srcRGB = "one"
				srcA = "one"
				dstRGB = "one_minus_src_alpha"
				dstA = "one_minus_src_alpha"
			elseif color_mode == "multiply" or color_mode == "multiplicative" then
				srcRGB = "dst_color"
				srcA = "dst_alpha"
				dstRGB = "zero"
				dstA = "zero"
			elseif color_mode == "subtract" or color_mode == "subtractive" then
				func = "subtract"
			elseif color_mode == "add" or color_mode == "additive" then
				srcRGB = "one"
				srcA = "zero"
				dstRGB = "one"
				dstA = "one"
			elseif color_mode == "lighten" then
				func = "max"
			elseif color_mode == "darken" then
				func = "min"
			elseif color_mode == "screen" then
				srcRGB = "one"
				srcA = "one"
				dstRGB = "one_minus_src_color"
				dstA = "one_minus_src_color"
			else
				srcRGB = "one"
				srcA = "one"
				dstRGB = "zero"
				dstA = "zero"
			end

			if srcRGB == "one" and alpha_mode == "alphamultiply" then
				srcRGB = "src_alpha"
			end

			render2d.SetBlendMode(srcRGB, dstRGB, func, srcA, dstA, func)
			COLOR_MODE = color_mode
			ALPHA_MODE = alpha_mode
		end

		function love.graphics.getBlendMode()
			return COLOR_MODE, ALPHA_MODE
		end
	end

	do
		function love.graphics.setColorMode(mode)
			if mode == "replace" then mode = "none" end
		end

		function love.graphics.getColorMode()
			return "modulate"
		end
	end
end
