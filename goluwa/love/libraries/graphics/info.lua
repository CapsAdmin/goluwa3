return function(ctx)
	local love = ctx.love
	local render = ctx.render

	function love.graphics.getTextureTypes()
		return {
			["2d"] = true,
			array = false,
			cube = false,
			volume = true,
		}
	end

	function love.graphics.isCreated()
		return true
	end

	function love.graphics.getModes()
		return {
			{width = 720, height = 480},
			{width = 800, height = 480},
			{width = 800, height = 600},
			{width = 852, height = 480},
			{width = 1024, height = 768},
			{width = 1152, height = 768},
			{width = 1152, height = 864},
			{width = 1280, height = 720},
			{width = 1280, height = 768},
			{width = 1280, height = 800},
			{width = 1280, height = 854},
			{width = 1280, height = 960},
			{width = 1280, height = 1024},
			{width = 1365, height = 768},
			{width = 1366, height = 768},
			{width = 1400, height = 1050},
			{width = 1440, height = 900},
			{width = 1440, height = 960},
			{width = 1600, height = 900},
			{width = 1600, height = 1200},
			{width = 1680, height = 1050},
			{width = 1920, height = 1080},
			{width = 1920, height = 1200},
			{width = 2048, height = 1536},
			{width = 2560, height = 1600},
			{width = 2560, height = 2048},
		}
	end

	function love.graphics.getStats()
		return {
			fonts = 1,
			images = 1,
			canvases = 1,
			images = 1,
			texturememory = 1,
			canvasswitches = 1,
			drawcalls = 1,
		}
	end

	function love.graphics.getRendererInfo()
		local screen_texture = render.GetScreenTexture and render.GetScreenTexture()
		local version = screen_texture and screen_texture.format or "unknown"
		return "Vulkan", version, "Goluwa", "Goluwa Vulkan Renderer"
	end
end
