return function(ctx)
	local love = ctx.love
	local ENV = ctx.ENV

	function love.graphics.setDefaultImageFilter(min, mag, anisotropy)
		ENV.graphics_filter_min = min or "linear"
		ENV.graphics_filter_mag = mag or min or "linear"
		ENV.graphics_filter_anisotropy = anisotropy or 1
	end

	love.graphics.setDefaultFilter = love.graphics.setDefaultImageFilter
end
