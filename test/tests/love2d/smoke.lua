local T = import("test/environment.lua")
local base64 = import("goluwa/codecs/base64.lua")
local fs = import("goluwa/fs.lua")
local line = import("goluwa/love/line.lua")
local frame = import("goluwa/love/libraries/graphics/frame.lua")
local render = import("goluwa/render/render.lua")
local window = import("goluwa/window.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local INLINE_ATLAS_SHADER = [[
		#if defined(VERTEX) || __VERSION__ > 100 || defined(GL_FRAGMENT_PRECISION_HIGH)
			#define MY_PRECISION highp
		#else
			#define MY_PRECISION mediump
		#endif

		extern number dissolve;
		extern number time;
		extern vec4 texture_details;
		extern vec2 image_details;
		extern bool shadow;
		extern vec4 burn_colour_1;
		extern vec4 burn_colour_2;
		extern vec2 mouse_screen_pos;
		extern number hovering;
		extern number screen_scale;

		#ifdef VERTEX
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			if (hovering <= 0.0) return transform_projection * vertex_position;
			vec2 mouse_offset = (vertex_position.xy - mouse_screen_pos.xy) / max(screen_scale, 0.001);
			return transform_projection * (vertex_position + vec4(mouse_offset, 0.0, 0.0));
		}
		#endif

		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			vec4 sampled = Texel(tex, texture_coords) * color;
			if (sampled.a <= 0.0) return sampled;
			if (shadow) return vec4(0.0, 0.0, 0.0, sampled.a * 0.35);
			return sampled;
		}
	]]
local INLINE_BACKGROUND_SHADER = [[
		extern number time;
		extern number spin_time;
		extern number contrast;
		extern number spin_amount;
		extern vec4 colour_1;
		extern vec4 colour_2;
		extern vec4 colour_3;

		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			float mix_amount = clamp(texture_coords.x * 0.7 + texture_coords.y * 0.3, 0.0, 1.0);
			vec4 gradient = mix(colour_1, colour_2, mix_amount + spin_amount * 0.0 + time * 0.0 + spin_time * 0.0);
			return mix(gradient, colour_3, 0.2) * vec4(vec3(contrast), 1.0) * color;
		}
	]]
local INLINE_POSTPROCESS_SHADER = [[
		extern vec2 distortion_fac;
		extern vec2 scale_fac;
		extern number feather_fac;
		extern number bloom_fac;
		extern number time;
		extern number noise_fac;
		extern number crt_intensity;
		extern number glitch_intensity;
		extern number scanlines;
		extern vec2 mouse_screen_pos;
		extern number screen_scale;
		extern number hovering;

		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			vec4 sampled = Texel(tex, texture_coords) * color;
			float line = 1.0 - crt_intensity * 0.25 * sin(texture_coords.y * max(scanlines, 1.0) * 6.28318);
			return sampled * line;
		}
	]]

local function fill_rect(data, x, y, width, height, r, g, b, a)
	for py = y, y + height - 1 do
		for px = x, x + width - 1 do
			data:setPixel(px, py, r, g, b, a)
		end
	end
end

local function send_inline_atlas_uniforms(shader, love, image_w, image_h, quad_x, quad_y, quad_w, quad_h, options)
	options = options or {}
	shader:send("dissolve", options.dissolve or 0)
	shader:send("time", options.time or 0)
	shader:send("texture_details", {quad_x, quad_y, quad_w, quad_h})
	shader:send("image_details", {image_w, image_h})
	shader:send("shadow", options.shadow == true)
	shader:send("burn_colour_1", options.burn_colour_1 or {0, 0, 0, 0})
	shader:send("burn_colour_2", options.burn_colour_2 or {0, 0, 0, 0})
	shader:send(
		"mouse_screen_pos",
		options.mouse_screen_pos or
			{love.graphics.getWidth() / 2, love.graphics.getHeight() / 2}
	)
	shader:send("hovering", options.hovering or 0)
	shader:send("screen_scale", options.screen_scale or 1)
end

T.Test2D("love2d startup window api smoke", function()
	local game_dir = "test/tmp/love2d_smoke"
	assert(fs.create_directory_recursive(game_dir))
	assert(
		fs.write_file(
			game_dir .. "/conf.lua",
			[[
		function love.conf(t)
			t.title = "Love2D Smoke"
			t.window.width = 320
			t.window.height = 200
		end
	]]
		)
	)
	assert(
		fs.write_file(
			game_dir .. "/main.lua",
			[[
		function love.load()
			local ok = love.window.updateMode(640, 360, {
				fullscreen = true,
				fullscreentype = "desktop",
				vsync = 0,
				resizable = true,
				display = 1,
			})

			local width, height, flags = love.window.getMode()
			WINDOW_UPDATE_OK = ok
			WINDOW_WIDTH = width
			WINDOW_HEIGHT = height
			WINDOW_FULLSCREEN = flags.fullscreen
			WINDOW_FULLSCREEN_TYPE = flags.fullscreentype
			WINDOW_VSYNC = flags.vsync
			WINDOW_RESIZABLE = flags.resizable
			WINDOW_DISPLAY = flags.display
			WINDOW_IS_OPEN = love.window.isOpen()
			WINDOW_TITLE = love.window.getTitle()
			WINDOW_TO_PIXELS = love.window.toPixels(70)
			WINDOW_FROM_PIXELS = love.window.fromPixels(70)
			WINDOW_MESSAGE_BOX = love.window.showMessageBox("Quit", "", {"OK", "Cancel"})
		end
	]]
		)
	)
	local love = line.RunGame(game_dir)
	local globals = love._line_env.globals
	T(love._line_env.error_message)["=="](nil)
	T(globals.WINDOW_UPDATE_OK)["=="](true)
	T(globals.WINDOW_WIDTH)["=="](640)
	T(globals.WINDOW_HEIGHT)["=="](360)
	T(globals.WINDOW_FULLSCREEN)["=="](true)
	T(globals.WINDOW_FULLSCREEN_TYPE)["=="]("desktop")
	T(globals.WINDOW_VSYNC)["=="](0)
	T(globals.WINDOW_RESIZABLE)["=="](true)
	T(globals.WINDOW_DISPLAY)["=="](1)
	T(globals.WINDOW_IS_OPEN)["=="](true)
	T(globals.WINDOW_TITLE)["=="]("Love2D Smoke")
	T(globals.WINDOW_TO_PIXELS)["=="](70)
	T(globals.WINDOW_FROM_PIXELS)["=="](70)
	T(globals.WINDOW_MESSAGE_BOX)["=="](1)
	T(globals.ScreenWidth)["=="](640)
	T(globals.ScreenHeight)["=="](360)
	T(globals.windowWidth)["=="](640)
	T(globals.windowHeight)["=="](360)
end)

T.Test2D("love2d shader file path smoke", function()
	local game_dir = "test/tmp/love2d_shader_path"
	assert(fs.create_directory_recursive(game_dir .. "/resources/shaders"))
	assert(
		fs.write_file(
			game_dir .. "/main.lua",
			[[
		function love.load()
			SHADER_TEST_BOOTED = true
		end
	]]
		)
	)
	assert(
		fs.write_file(
			game_dir .. "/resources/shaders/test.fs",
			[[
		#ifdef GL_ES
			#define MY_HIGHP_OR_MEDIUMP highp
		#else
			#define MY_HIGHP_OR_MEDIUMP mediump
		#endif

		extern MY_HIGHP_OR_MEDIUMP number time;
		extern bool shadow;
		extern MY_HIGHP_OR_MEDIUMP vec4 burn_colour_1;

		vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
			return vec4(time, shadow ? burn_colour_1.g : 0.0, burn_colour_1.b, 1.0) * color;
		}
	]]
		)
	)
	local love = line.RunGame(game_dir)
	local shader = love.graphics.newShader("resources/shaders/test.fs")
	T(love._line_env.error_message)["=="](nil)
	T(shader ~= nil)["=="](true)
end)

T.Test2D("love2d combined vertex shader smoke", function()
	local game_dir = "test/tmp/love2d_combined_shader"
	assert(fs.create_directory_recursive(game_dir .. "/resources/shaders"))
	assert(fs.write_file(game_dir .. "/main.lua", [[
		function love.load() end
	]]))
	assert(
		fs.write_file(
			game_dir .. "/resources/shaders/test.fs",
			[[
		#if defined(VERTEX) || __VERSION__ > 100 || defined(GL_FRAGMENT_PRECISION_HIGH)
			#define MY_HIGHP_OR_MEDIUMP highp
		#else
			#define MY_HIGHP_OR_MEDIUMP mediump
		#endif

		extern MY_HIGHP_OR_MEDIUMP vec2 mouse_screen_pos;
		extern MY_HIGHP_OR_MEDIUMP float hovering;
		extern MY_HIGHP_OR_MEDIUMP float screen_scale;

		vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
			return color;
		}

		#ifdef VERTEX
		vec4 position(mat4 transform_projection, vec4 vertex_position) {
			if (hovering <= 0.0) return transform_projection * vertex_position;
			vec2 mouse_offset = (vertex_position.xy - mouse_screen_pos.xy) / screen_scale;
			return transform_projection * vertex_position + vec4(mouse_offset, 0.0, 0.0);
		}
		#endif
	]]
		)
	)
	local love = line.RunGame(game_dir)
	local shader = love.graphics.newShader("resources/shaders/test.fs")
	T(love._line_env.error_message)["=="](nil)
	T(shader ~= nil)["=="](true)
end)

T.Test2D("love2d vertex-only shader smoke", function()
	local game_dir = "test/tmp/love2d_vertex_only_shader"
	assert(fs.create_directory_recursive(game_dir .. "/resources/shaders"))
	assert(fs.write_file(game_dir .. "/main.lua", [[
		function love.load() end
	]]))
	assert(
		fs.write_file(
			game_dir .. "/resources/shaders/test.fs",
			[[
		extern vec2 mouse_screen_pos;
		extern float hovering;
		extern float screen_scale;

		#ifdef VERTEX
		vec4 position(mat4 transform_projection, vec4 vertex_position) {
			if (hovering <= 0.0) return transform_projection * vertex_position;
			vec2 mouse_offset = (vertex_position.xy - mouse_screen_pos.xy) / screen_scale;
			return transform_projection * vertex_position + vec4(mouse_offset, 0.0, 0.0);
		}
		#endif
	]]
		)
	)
	local love = line.RunGame(game_dir)
	local shader = love.graphics.newShader("resources/shaders/test.fs")
	T(love._line_env.error_message)["=="](nil)
	T(shader ~= nil)["=="](true)
end)

T.Test2D("love2d lily async image smoke", function()
	local game_dir = "test/tmp/love2d_lily_image"
	assert(fs.create_directory_recursive(game_dir .. "/libraries"))
	assert(
		fs.write_file(
			game_dir .. "/pixel.png",
			base64.Decode(
				"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN6kAAAAASUVORK5CYII="
			)
		)
	)
	assert(
		fs.write_file(
			game_dir .. "/libraries/async_image.lua",
			[[
		local taskChannel = love.thread.newChannel()
		local dataPullChannel = love.thread.newChannel()
		local updateModeChannel = love.thread.newChannel()
		local worker = love.thread.newThread("libraries/async_image_thread.lua")
		local loader = {
			request = {},
			threads = {worker},
			taskChannel = taskChannel,
			dataPullChannel = dataPullChannel,
			updateModeChannel = updateModeChannel,
		}
		local next_id = 1

		function loader.setUpdateMode(mode)
			updateModeChannel:clear()
			updateModeChannel:push(mode)
		end

		loader.setUpdateMode("auto")
		worker:start(taskChannel, dataPullChannel)

		function loader.newImage(path)
			local id = next_id
			next_id = next_id + 1
			local request = {id = id}
			loader.request[id] = request
			taskChannel:push({kind = "image", id = id, path = path})
			local handle = {}

			function handle:onComplete(callback)
				request.onComplete = callback
				return self
			end

			function handle:onError(callback)
				request.onError = callback
				return self
			end

			return handle
		end

		function loader.update()
			while true do
				local message = dataPullChannel:pop()

				if not message then break end

				local request = loader.request[message.id]
				loader.request[message.id] = nil

				if request then
					if message.error then
						if request.onError then request.onError(nil, message.error) end
					else
						local image = love.graphics.newImage(message.data)
						if request.onComplete then request.onComplete(nil, image) end
					end
				end
			end
		end

		function loader.quit()
			taskChannel:push({kind = "quit"})
			worker:wait()
		end

		return loader
		]]
		)
	)
	assert(
		fs.write_file(
			game_dir .. "/libraries/async_image_thread.lua",
			[[
		local taskChannel, dataPullChannel = ...

		while true do
			local task = taskChannel:demand(0.1)

			if task then
				if task.kind == "quit" then return end

				local ok, result = pcall(love.image.newImageData, task.path)

				if ok then
					dataPullChannel:push({id = task.id, data = result})
				else
					dataPullChannel:push({id = task.id, error = tostring(result)})
				end
			else
				love.timer.sleep(0.001)
			end
		end
		]]
		)
	)
	assert(
		fs.write_file(
			game_dir .. "/conf.lua",
			[[
		function love.conf(t)
			t.version = "11.0"
		end
	]]
		)
	)
	assert(
		fs.write_file(
			game_dir .. "/main.lua",
			[[
		_G.testMode = nil
		local loader = require("libraries.async_image")

		function love.load()
			LOADER_DONE = false
			LOADER_ERROR = nil
			if loader.setUpdateMode then loader.setUpdateMode("manual") end
			LOADER_MODE = loader.updateModeChannel and loader.updateModeChannel:peek() or nil
			loader.newImage("pixel.png"):onComplete(function(_, image)
				LOADER_DONE = image and image:typeOf("Image")
				if image then
					LOADER_WIDTH, LOADER_HEIGHT = image:getDimensions()
				end
				loader.quit()
			end):onError(function(_, err)
				LOADER_ERROR = err
				loader.quit()
			end)
		end
		]]
		)
	)
	local love = line.RunGame(game_dir)
	local globals = love._line_env.globals
	local update_module

	for _, module in ipairs(love._line_env.update_modules or {}) do
		if module.taskChannel and module.dataPullChannel and module.threads then
			update_module = module

			break
		end
	end

	T(update_module ~= nil)["=="](true)

	for _ = 1, 240 do
		if globals.LOADER_DONE or globals.LOADER_ERROR then break end

		love.line_update(1 / 60)
	end

	local worker_error = update_module and
		update_module.threads and
		update_module.threads[1] and
		update_module.threads[1]:getError() or
		nil
	local task_count = update_module and
		update_module.taskChannel and
		update_module.taskChannel:getCount() or
		nil
	local pull_count = update_module and
		update_module.dataPullChannel and
		update_module.dataPullChannel:getCount() or
		nil
	local request_count = 0

	if update_module and update_module.request then
		for _ in pairs(update_module.request) do
			request_count = request_count + 1
		end
	end

	if update_module and update_module.quit then pcall(update_module.quit) end

	T(love._line_env.error_message)["=="](nil)
	T(worker_error)["=="](nil)
	T(globals.LOADER_ERROR)["=="](nil)
	T(task_count)["=="](0)
	T(pull_count)["=="](0)
	T(request_count)["=="](0)
	T(globals.LOADER_DONE)["=="](true)
	T(globals.LOADER_WIDTH)["=="](1)
	T(globals.LOADER_HEIGHT)["=="](1)
end)

T.Test2D("love2d canvas pixel dimension smoke", function()
	local love = line.CreateLoveEnv("11.0.0")
	local canvas = love.graphics.newCanvas(64, 32)
	T(canvas:getPixelWidth())["=="](64)
	T(canvas:getPixelHeight())["=="](32)
	local pixel_w, pixel_h = canvas:getPixelDimensions()
	T(pixel_w)["=="](64)
	T(pixel_h)["=="](32)
end)

T.Test2D("love2d image dpiscale quad smoke", function()
	local love = line.CreateLoveEnv("11.0.0")
	local data = love.image.newImageData(4, 2)

	for y = 0, 1 do
		data:setPixel(0, y, 1, 0, 0, 1)
		data:setPixel(1, y, 1, 0, 0, 1)
		data:setPixel(2, y, 0, 1, 0, 1)
		data:setPixel(3, y, 0, 1, 0, 1)
	end

	local image = love.graphics.newImage(data, {dpiscale = 2})
	image:setFilter("nearest", "nearest", 1)
	local width, height = image:getDimensions()
	local quad = love.graphics.newQuad(0, 0, width, height, image:getDimensions())
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.draw(image, quad, 0, 0, 0, 32, 32)
	return function()
		T(width)["=="](2)
		T(height)["=="](1)
		T.AssertScreenPixel{pos = {16, 16}, color = {1, 0, 0, 1}, tolerance = 0.08}
		T.AssertScreenPixel{pos = {48, 16}, color = {0, 1, 0, 1}, tolerance = 0.08}
	end
end)

T.Test2D("love2d atlas shader dpiscale sprite smoke", function()
	local love = line.CreateLoveEnv("11.0.0")
	local data = love.image.newImageData(40, 40)

	for y = 0, 19 do
		for x = 0, 19 do
			data:setPixel(x, y, 1, 0, 0, 1)
		end

		for x = 20, 39 do
			data:setPixel(x, y, 0, 1, 0, 1)
		end
	end

	for y = 20, 39 do
		for x = 0, 19 do
			data:setPixel(x, y, 0, 0, 1, 1)
		end

		for x = 20, 39 do
			data:setPixel(x, y, 1, 1, 0, 1)
		end
	end

	local image = love.graphics.newImage(data, {dpiscale = 2})
	image:setFilter("nearest", "nearest", 1)
	local image_w, image_h = image:getDimensions()
	local quad = love.graphics.newQuad(10, 10, 10, 10, image_w, image_h)
	local shader = love.graphics.newShader(INLINE_ATLAS_SHADER)
	send_inline_atlas_uniforms(shader, love, image_w, image_h, 10, 10, 10, 10)
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.draw(image, quad, 0, 0, 0, 6.4, 6.4)
	love.graphics.setShader()
	return function()
		T(image_w)["=="](20)
		T(image_h)["=="](20)
		T.AssertScreenPixel{pos = {32, 32}, color = {1, 1, 0, 1}, tolerance = 0.08}
		T.AssertScreenPixel{pos = {80, 32}, color = {0, 0, 0, 1}, tolerance = 0.08}
	end
end)

T.Test2D("love2d atlas shader hover transform smoke", function()
	local love = line.CreateLoveEnv("11.0.0")
	local canvas = love.graphics.newCanvas(192, 192)
	local shader = love.graphics.newShader(INLINE_ATLAS_SHADER)
	local center_data = love.image.newImageData(142, 95)
	fill_rect(center_data, 71, 0, 71, 95, 0.95, 0.3, 0.2, 1)
	fill_rect(center_data, 90, 18, 18, 18, 1, 1, 1, 1)
	local center = love.graphics.newImage(center_data, {mipmaps = true, dpiscale = 2})
	local center_w, center_h = center:getDimensions()
	local center_quad = love.graphics.newQuad(1 * 71, 0, 71, 95, center_w, center_h)
	local card_x = 48
	local card_y = 18
	local card_w = 96
	local card_h = 128
	center:setFilter("linear", "linear", 1)
	send_inline_atlas_uniforms(
		shader,
		love,
		center_w,
		center_h,
		1,
		0,
		71,
		95,
		{
			mouse_screen_pos = {card_x + card_w * 0.5, card_y + card_h * 0.5},
			hovering = 1,
			screen_scale = 64,
		}
	)
	love.graphics.setCanvas(canvas)
	love.graphics.clear(0.45, 0.40, 0.36, 1)
	love.graphics.push()
	love.graphics.translate(card_x, card_y)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.draw(center, center_quad, 0, 0, 0, card_w / 71, card_h / 95)
	love.graphics.setShader()
	love.graphics.pop()
	love.graphics.setCanvas()
	local canvas_data = canvas:newImageData()
	local body_x = math.floor(card_x + card_w * 0.30)
	local body_y = math.floor(card_y + card_h * 0.35)
	local body_r, body_g, body_b, body_a = canvas_data:getPixel(body_x, body_y)
	return function()
		T(body_a > 0.1)["=="](true)
		T(body_r + body_g + body_b > 0.25)["=="](true)
	end
end)

T.Test2D("love2d canvas shader sampling smoke", function()
	local love = line.CreateLoveEnv("11.0.0")
	local canvas = love.graphics.newCanvas(32, 32)
	local shader = love.graphics.newShader([[
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			if (tex < 0) return vec4(1.0, 0.0, 1.0, 1.0);
			return Texel(tex, texture_coords) * color;
		}
	]])
	love.graphics.setCanvas(canvas)
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(1, 0, 0, 1)
	love.graphics.rectangle("fill", 0, 0, 32, 32)
	love.graphics.setCanvas()
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.draw(canvas, 0, 0)
	love.graphics.setShader()
	return function()
		T.AssertScreenPixel{pos = {16, 16}, color = {1, 0, 0, 1}, tolerance = 0.08}
	end
end)

T.Test2D("love2d combined shader image draw smoke", function()
	local love = line.CreateLoveEnv("11.0.0")
	local source = love.image.newImageData(1, 1)
	source:setPixel(0, 0, 0, 1, 0, 1)
	local image = love.graphics.newImage(source)
	image:setFilter("nearest", "nearest", 1)
	local shader = love.graphics.newShader([[
		#ifdef VERTEX
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			return transform_projection * vertex_position;
		}
		#endif

		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			return Texel(tex, texture_coords) * color;
		}
	]])
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.draw(image, 0, 0, 0, 64, 64)
	love.graphics.setShader()
	return function()
		T.AssertScreenPixel{pos = {32, 32}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love2d layered shader canvas smoke", function()
	local love = line.CreateLoveEnv("11.0.0")
	local canvas = love.graphics.newCanvas(96, 64)
	local source = love.image.newImageData(1, 1)
	source:setPixel(0, 0, 1, 1, 1, 1)
	local image = love.graphics.newImage(source)
	image:setFilter("nearest", "nearest", 1)
	local background = love.graphics.newShader(INLINE_BACKGROUND_SHADER)
	local crt = love.graphics.newShader(INLINE_POSTPROCESS_SHADER)
	background:send("time", 0)
	background:send("spin_time", 0)
	background:send("colour_1", {238 / 255, 99 / 255, 80 / 255, 1})
	background:send("colour_2", {251 / 255, 189 / 255, 109 / 255, 1})
	background:send("colour_3", {49 / 255, 42 / 255, 35 / 255, 1})
	background:send("contrast", 1)
	background:send("spin_amount", 0)
	love.graphics.setCanvas({canvas})
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(background)
	love.graphics.draw(image, 0, 0, 0, canvas:getWidth(), canvas:getHeight())
	love.graphics.setShader()
	love.graphics.setCanvas()
	local canvas_data = canvas:newImageData()
	local canvas_r, canvas_g, canvas_b, canvas_a = canvas_data:getPixel(48, 32)
	crt:send("distortion_fac", {1, 1})
	crt:send("scale_fac", {1, 1})
	crt:send("feather_fac", 0.01)
	crt:send("bloom_fac", 0)
	crt:send("time", 0)
	crt:send("noise_fac", 0)
	crt:send("crt_intensity", 0)
	crt:send("glitch_intensity", 0)
	crt:send("scanlines", canvas:getPixelHeight() * 0.75)
	crt:send("mouse_screen_pos", {love.graphics.getWidth() / 2, love.graphics.getHeight() / 2})
	crt:send("screen_scale", 1)
	crt:send("hovering", 0)
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.push()
	love.graphics.scale(1)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(crt)
	love.graphics.draw(canvas, 0, 0)
	love.graphics.setShader()
	love.graphics.pop()
	return function()
		T(canvas_a > 0.99)["=="](true)
		T(canvas_r + canvas_g + canvas_b > 0.1)["=="](true)
		T.AssertScreenPixel{pos = {48, 32}, color = {canvas_r, canvas_g, canvas_b, 1}, tolerance = 0.15}
	end
end)

T.Test2D("love2d layered atlas title card smoke", function()
	local love = line.CreateLoveEnv("11.0.0")
	local canvas = love.graphics.newCanvas(192, 192)
	local shader = love.graphics.newShader(INLINE_ATLAS_SHADER)
	local front_data = love.image.newImageData(142, 95)
	local center_data = love.image.newImageData(142, 95)
	fill_rect(front_data, 71, 0, 71, 95, 0.2, 0.35, 1, 1)
	fill_rect(front_data, 82, 12, 49, 70, 0.85, 0.92, 1, 1)
	fill_rect(center_data, 71, 0, 71, 95, 0.9, 0.6, 0.15, 1)
	fill_rect(center_data, 88, 18, 34, 56, 0.45, 0.15, 0.05, 1)
	local front = love.graphics.newImage(front_data, {mipmaps = true, dpiscale = 2})
	local center = love.graphics.newImage(center_data, {mipmaps = true, dpiscale = 2})
	local front_w, front_h = front:getDimensions()
	local center_w, center_h = center:getDimensions()
	local front_quad = love.graphics.newQuad(1 * 71, 0, 71, 95, front_w, front_h)
	local center_quad = love.graphics.newQuad(1 * 71, 0, 71, 95, center_w, center_h)
	local card_x = 48
	local card_y = 18
	local card_w = 96
	local card_h = 128
	local shadow_y = 6
	local shadow_scale = 0.98
	front:setFilter("linear", "linear", 1)
	center:setFilter("linear", "linear", 1)

	local function draw_dissolve(image, quad, atlas_x, atlas_y, x, y, scale_x, scale_y, is_shadow)
		local image_w, image_h = image:getDimensions()
		send_inline_atlas_uniforms(
			shader,
			love,
			image_w,
			image_h,
			atlas_x,
			atlas_y,
			71,
			95,
			{
				shadow = is_shadow,
			}
		)
		love.graphics.setShader(shader)
		love.graphics.draw(image, quad, x, y, 0, scale_x, scale_y)
		love.graphics.setShader()
	end

	love.graphics.setCanvas(canvas)
	love.graphics.clear(0.45, 0.40, 0.36, 1)
	draw_dissolve(
		center,
		center_quad,
		1,
		0,
		card_x,
		card_y + shadow_y,
		(card_w / 71) * shadow_scale,
		(card_h / 95) * shadow_scale,
		true
	)
	draw_dissolve(center, center_quad, 1, 0, card_x, card_y, card_w / 71, card_h / 95, false)
	draw_dissolve(front, front_quad, 12, 3, card_x, card_y, card_w / 71, card_h / 95, false)
	love.graphics.setCanvas()
	local canvas_data = canvas:newImageData()
	local body_x = math.floor(card_x + card_w * 0.30)
	local body_y = math.floor(card_y + card_h * 0.35)
	local shadow_x = math.floor(card_x + card_w * 0.50)
	local shadow_sample_y = math.floor(card_y + card_h + 2)
	local outside_x = math.floor(card_x + card_w + 18)
	local outside_y = body_y
	local body_r, body_g, body_b, body_a = canvas_data:getPixel(body_x, body_y)
	local shadow_r, shadow_g, shadow_b, shadow_a = canvas_data:getPixel(shadow_x, shadow_sample_y)
	local outside_r, outside_g, outside_b, outside_a = canvas_data:getPixel(outside_x, outside_y)
	local body_delta = math.abs(body_r - outside_r) + math.abs(body_g - outside_g) + math.abs(body_b - outside_b)
	local body_shadow_delta = math.abs(body_r - shadow_r) + math.abs(body_g - shadow_g) + math.abs(body_b - shadow_b)
	local shadow_brightness = shadow_r + shadow_g + shadow_b
	local outside_brightness = outside_r + outside_g + outside_b
	return function()
		T(body_delta > 0.2)["=="](true)
		T(body_shadow_delta > 0.15)["=="](true)
		T(outside_brightness > shadow_brightness + 0.08)["=="](true)
	end
end)

T.Test2D("love2d frame helper prefers render target size", function()
	local love = line.CreateLoveEnv("11.0.0")
	local helpers = frame.Get(love)
	local old_get_render_image_size = render.GetRenderImageSize
	local old_get_size = window.GetSize
	render.GetRenderImageSize = function()
		return Vec2(800, 600)
	end
	window.GetSize = function()
		return Vec2(1280, 720)
	end
	local ok, err = pcall(function()
		local width, height = helpers.get_main_surface_dimensions()
		T(width)["=="](800)
		T(height)["=="](600)
	end)
	render.GetRenderImageSize = old_get_render_image_size
	window.GetSize = old_get_size

	if not ok then error(err, 0) end
end)

T.Test2D("love2d source release smoke", function()
	local love = line.CreateLoveEnv("11.0.0")
	local sound_data = love.sound.newSoundData(32, 44100, 16, 1)
	local source = love.audio.newSource(sound_data)
	local ok, err = pcall(function()
		source:release()
	end)

	if not ok then error(err, 0) end

	T(source:isStopped())["=="](true)
end)

T.Test("love2d data deflate smoke", function()
	local love = line.CreateLoveEnv("11.0.0")
	local payload = "return {answer=42}"
	local compressed = love.data.compress("string", "deflate", payload, 1)
	local decompressed = love.data.decompress("string", "deflate", compressed)
	T(compressed)["=="](payload)
	T(decompressed)["=="](payload)
	local encoded = love.data.encode("string", "base64", "hello")
	local decoded = love.data.decode("string", "base64", encoded)
	T(decoded)["=="]("hello")
end)
