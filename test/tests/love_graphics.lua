local T = import("test/environment.lua")
local line = import("goluwa/love/line.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")

local function new_love_graphics_env()
	local love = {_line_env = {}}
	assert(loadfile("goluwa/love/libraries/image.lua"))(love)
	assert(loadfile("goluwa/love/libraries/graphics.lua"))(love)
	return love
end

local function make_quadrant_image(love)
	local data = love.image.newImageData(2, 2)
	data:setPixel(0, 0, 255, 255, 0, 255)
	data:setPixel(1, 0, 255, 0, 0, 255)
	data:setPixel(0, 1, 0, 255, 0, 255)
	data:setPixel(1, 1, 0, 128, 255, 255)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	return image
end

T.Test2D("love line creates an environment on Vulkan", function()
	local love = line.CreateLoveEnv()
	T(love ~= nil)["=="](true)
	T(type(love.graphics))["=="]("table")
end)

T.Test2D("love graphics renderer info reports Vulkan", function()
	local love = new_love_graphics_env()
	local backend, version, vendor, renderer = love.graphics.getRendererInfo()
	T(backend)["=="]("Vulkan")
	T(type(version))["=="]("string")
	T(vendor)["=="]("Goluwa")
	T(type(renderer))["=="]("string")
end)

T.Test2D("love graphics canvas clear path executes", function()
	local love = new_love_graphics_env()
	local canvas = love.graphics.newCanvas(16, 16)
	canvas:clear(255, 32, 0, 255)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(canvas, 32, 32, 0, 4, 4)
	return function()
		T(canvas.__line_type)["=="]("Canvas")
		T.TexturePixel(canvas.fb:GetColorTexture(), 4, 4, 1, 32 / 255, 0, 1, 0.08)
		T.AssertScreenPixel{pos = {40, 40}, color = {1, 32 / 255, 0, 1}, tolerance = 0.08}
	end
end)

T.Test2D("love graphics draw image placement", function()
	local love = new_love_graphics_env()
	local image = make_quadrant_image(love)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(image, 32, 32, 0, 32, 32)
	return function()
		T.AssertScreenPixel{pos = {40, 40}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {88, 40}, color = {1, 0, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {40, 88}, color = {0, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {88, 88}, color = {0, 128 / 255, 1, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics mrrescue splash quad placement", function()
	local love = new_love_graphics_env()
	local path = "love_games/mrrescue/data/splash.png"
	local image = love.graphics.newImage(path)
	image:setFilter("nearest", "nearest", 1)
	local quad = love.graphics.newQuad(0, 0, 256, 200, image:getWidth(), image:getHeight())
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(image, quad, 0, 0)
	return function()
		T.AssertScreenPixel{pos = {32, 40}, color = {238 / 255, 99 / 255, 80 / 255, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {200, 40}, color = {30 / 255, 23 / 255, 18 / 255, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {32, 180}, color = {251 / 255, 189 / 255, 109 / 255, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {128, 199}, color = {49 / 255, 42 / 255, 35 / 255, 1}, tolerance = 0.1}
	end
end)

T.Test("love image mrrescue palette transparency", function()
	local love = new_love_graphics_env()
	local image_data = love.image.newImageData("love_games/mrrescue/data/level_buildings.png")
	local tr, tg, tb, ta = image_data:getPixel(144, 80)
	local or_, og, ob, oa = image_data:getPixel(184, 80)
	T(tr)["=="](204)
	T(tg)["=="](152)
	T(tb)["=="](109)
	T(ta)["=="](0)
	T(or_)["=="](246)
	T(og)["=="](247)
	T(ob)["=="](221)
	T(oa)["=="](255)
end)

T.Test2D("love graphics drawq placement", function()
	local love = new_love_graphics_env()
	local image = make_quadrant_image(love)
	local quad = love.graphics.newQuad(0, 0, 1, 1, 2, 2)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(image, quad, 144, 32, 0, 64, 64)
	return function()
		T.AssertScreenPixel{pos = {160, 48}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {192, 80}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {204, 92}, color = {1, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics drawq nonzero source Y", function()
	local love = new_love_graphics_env()
	local image = make_quadrant_image(love)
	local quad = love.graphics.newQuad(0, 1, 1, 1, 2, 2)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(image, quad, 240, 32, 0, 64, 64)
	return function()
		T.AssertScreenPixel{pos = {256, 48}, color = {0, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {288, 80}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics quad viewport mutation", function()
	local love = new_love_graphics_env()
	local image = make_quadrant_image(love)
	local quad = love.graphics.newQuad(0, 0, 2, 2, 2, 2)
	quad:setViewport(0, 1, 1, 1)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(image, quad, 336, 32, 0, 64, 64)
	return function()
		T.AssertScreenPixel{pos = {352, 48}, color = {0, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {384, 80}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics spritebatch image placement", function()
	local love = new_love_graphics_env()
	local image = make_quadrant_image(love)
	local batch = love.graphics.newSpriteBatch(image, 1)
	batch:add(432, 32, 0, 32, 32)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(batch)
	return function()
		T.AssertScreenPixel{pos = {440, 40}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {480, 40}, color = {1, 0, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {440, 80}, color = {0, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {480, 80}, color = {0, 128 / 255, 1, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics spritebatch inherits outer transforms", function()
	local love = new_love_graphics_env()
	local image = make_quadrant_image(love)
	local batch = love.graphics.newSpriteBatch(image, 1)
	batch:add(0, 0, 0, 16, 16)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.push()
	love.graphics.translate(96, 64)
	love.graphics.scale(2, 2)
	love.graphics.draw(batch)
	love.graphics.pop()
	return function()
		T.AssertScreenPixel{pos = {104, 72}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {152, 72}, color = {1, 0, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {104, 120}, color = {0, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {152, 120}, color = {0, 128 / 255, 1, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics setBlendMode maps add and multiply correctly", function()
	local love = new_love_graphics_env()
	love.graphics.setBlendMode("add")
	local add_state = render2d.current_blend_mode_state
	T(add_state.src_color_blend_factor)["=="]("src_alpha")
	T(add_state.dst_color_blend_factor)["=="]("one")
	T(add_state.src_alpha_blend_factor)["=="]("zero")
	T(add_state.dst_alpha_blend_factor)["=="]("one")
	love.graphics.setBlendMode("multiply")
	local multiply_state = render2d.current_blend_mode_state
	T(multiply_state.src_color_blend_factor)["=="]("dst_color")
	T(multiply_state.dst_color_blend_factor)["=="]("zero")
	T(multiply_state.src_alpha_blend_factor)["=="]("dst_alpha")
	T(multiply_state.dst_alpha_blend_factor)["=="]("zero")
end)

T.Test2D("love graphics draw ignores leaked swizzle mode", function()
	local love = new_love_graphics_env()
	local image = make_quadrant_image(love)
	love.graphics.clear(0, 0, 0, 255)
	render2d.SetSwizzleMode(2)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(image, 32, 128, 0, 32, 32)
	return function()
		T.AssertScreenPixel{pos = {40, 136}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {88, 136}, color = {1, 0, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {40, 184}, color = {0, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {88, 184}, color = {0, 128 / 255, 1, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics mrrescue lightmap multiply composite stays neutral", function()
	local love = new_love_graphics_env()
	local canvas = love.graphics.newCanvas(256, 256)
	local light = love.graphics.newImage("love_games/mrrescue/data/light_player.png")
	light:setFilter("nearest", "nearest", 1)
	local light_w, light_h = light:getDimensions()
	local center_x = math.floor(light_w / 2)
	local center_y = math.floor(light_h / 2)
	love.graphics.setCanvas(canvas)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setBlendMode("add")
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(light, 32, 32)
	love.graphics.setBlendMode("alpha")
	love.graphics.setCanvas()
	love.graphics.clear(128, 128, 128, 255)
	love.graphics.setBlendMode("multiply")
	love.graphics.draw(canvas, 0, 0)
	love.graphics.setBlendMode("alpha")
	return function()
		T.TexturePixel(canvas.fb:GetColorTexture(), 4, 4, 0, 0, 0, 1, 0.08)

		T.TexturePixel(
			canvas.fb:GetColorTexture(),
			center_x + 32,
			center_y + 32,
			function(r, g, b)
				return math.abs(r - g) < 0.08 and math.abs(g - b) < 0.08 and r > 0.4
			end
		)

		T.AssertScreenPixel{pos = {4, 4}, color = {0, 0, 0, 1}, tolerance = 0.08}

		T.TexturePixel(
			render.target:GetTexture(),
			center_x + 32,
			center_y + 32,
			function(r, g, b)
				return math.abs(r - g) < 0.08 and math.abs(g - b) < 0.08 and r > 0.2 and r < 0.8
			end
		)
	end
end)

T.Test2D("love graphics canvas vertex colors stay correct", function()
	local love = new_love_graphics_env()
	local canvas = love.graphics.newCanvas(32, 32)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 255, 32, 0, 255},
			{16, 0, 0, 0, 255, 32, 0, 255},
			{16, 16, 0, 0, 255, 32, 0, 255},
			{0, 16, 0, 0, 255, 32, 0, 255},
		},
		nil,
		"fan"
	)
	love.graphics.setCanvas(canvas)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(mesh, 0, 0)
	love.graphics.setCanvas()
	return function()
		T.TexturePixel(canvas.fb:GetColorTexture(), 8, 8, 1, 32 / 255, 0, 1, 0.08)
	end
end)

T.Test2D("love graphics screen global color channels stay correct", function()
	local love = new_love_graphics_env()
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 32, 0, 255)
	love.graphics.rectangle("fill", 32, 32, 32, 32)
	return function()
		T.AssertScreenPixel{pos = {40, 40}, color = {1, 32 / 255, 0, 1}, tolerance = 0.08}
	end
end)

T.Test2D("love graphics mesh placement", function()
	local love = new_love_graphics_env()
	local image = make_quadrant_image(love)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 255, 255, 255, 255},
			{64, 0, 1, 0, 255, 255, 255, 255},
			{64, 64, 1, 1, 255, 255, 255, 255},
			{0, 64, 0, 1, 255, 255, 255, 255},
		},
		image,
		"fan"
	)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(mesh, 256, 32)
	return function()
		T.AssertScreenPixel{pos = {272, 48}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {304, 48}, color = {1, 0, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {272, 80}, color = {0, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {304, 80}, color = {0, 128 / 255, 1, 1}, tolerance = 0.1}
	end
end)
