local T = import("test/environment.lua")
local line = import("goluwa/love/line.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local window = import("goluwa/window.lua")
local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

local function apply_love_version(love, version)
	version = tostring(version or "0.10.1")
	local major, minor, revision = version:match("^(%d+)%.(%d+)%.?(%d*)$")
	revision = revision ~= "" and revision or "0"
	love._version_major = tonumber(major) or 0
	love._version_minor = tonumber(minor) or 0
	love._version_revision = tonumber(revision) or 0
	love._version = string.format("%d.%d.%d", love._version_major, love._version_minor, love._version_revision)
end

local function new_love_graphics_env(version)
	local love = {_line_env = {}}
	apply_love_version(love, version)
	assert(loadfile("goluwa/love/libraries/image_data.lua"))(love)
	assert(loadfile("goluwa/love/libraries/graphics.lua"))(love)
	return love
end

local function new_love_mouse_env(version)
	local love = {_line_env = {}}
	apply_love_version(love, version)
	assert(loadfile("goluwa/love/libraries/event.lua"))(love)
	assert(loadfile("goluwa/love/libraries/mouse.lua"))(love)
	return love
end

local function new_love_draw_env(version)
	local love = {_line_env = {}}
	apply_love_version(love, version)
	assert(loadfile("goluwa/love/libraries/image_data.lua"))(love)
	assert(loadfile("goluwa/love/libraries/graphics.lua"))(love)
	assert(loadfile("goluwa/love/libraries/love.lua"))(love)
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

T.Test2D("love graphics dimensions follow window size on main surface", function()
	local love = new_love_graphics_env("11.0.0")
	local old_window_get_size = window.GetSize
	local old_render_get_width = render.GetWidth
	local old_render_get_height = render.GetHeight
	local old_render_get_render_image_size = render.GetRenderImageSize
	window.GetSize = function()
		return Vec2(1280, 720)
	end
	render.GetWidth = function()
		return 800
	end
	render.GetHeight = function()
		return 600
	end
	render.GetRenderImageSize = function()
		return Vec2(800, 600)
	end
	local ok, err = pcall(function()
		T(({love.graphics.getDimensions()})[1])["=="](1280)
		T(({love.graphics.getDimensions()})[2])["=="](720)
		T(love.graphics.getWidth())["=="](1280)
		T(love.graphics.getHeight())["=="](720)
		local canvas = love.graphics.newCanvas()
		T(canvas:getWidth())["=="](1280)
		T(canvas:getHeight())["=="](720)
	end)
	window.GetSize = old_window_get_size
	render.GetWidth = old_render_get_width
	render.GetHeight = old_render_get_height
	render.GetRenderImageSize = old_render_get_render_image_size

	if not ok then error(err, 0) end
end)

T.Test2D("love graphics newFont preserves requested point size", function()
	local love = new_love_graphics_env("11.0.0")
	local font = love.graphics.newFont(12)
	local named_font = love.graphics.newFont("fonts/vera.ttf", 18)
	T(font.Size)["=="](12)
	T(named_font.Size)["=="](18)
	T(font.font:GetSize())["=="](12)
	T(named_font.font:GetSize())["=="](18)
end)

T.Test2D("love graphics ttf fonts apply wrapper compatibility scale", function()
	local love = new_love_graphics_env("11.0.0")
	local font = love.graphics.newFont("love_games/stonekingdoms/assets/fonts/Geologica-Regular.ttf", 12)
	local scale = font.font:GetScale()
	T(scale.x)["=="](0.78)
	T(scale.y)["=="](0.78)
end)

T.Test2D("love graphics font height uses line metrics not text bounds", function()
	local love = new_love_graphics_env("11.0.0")
	local font = love.graphics.newFont("love_games/stonekingdoms/assets/fonts/Geologica-Regular.ttf", 12)
	local expected = math.ceil(
		(
				font.font.GetLineHeight and
				font.font:GetLineHeight()
			) or
			(
				font.font:GetAscent() + font.font:GetDescent()
			)
	)
	T(font:getHeight())["=="](expected)
	T(font:getHeight("a"))["=="](expected)
	T(font:getHeight("Timber and Stone"))["=="](expected)
	T(font:getLineHeight())["=="](1)
	font:setLineHeight(1.5)
	T(font:getLineHeight())["=="](1.5)
end)

T.Test2D("love graphics intersectScissor clips against current scissor", function()
	local love = new_love_graphics_env("11.0.0")
	love.graphics.setScissor(10, 20, 100, 50)
	love.graphics.intersectScissor(50, 0, 80, 30)
	local x, y, w, h = love.graphics.getScissor()
	T(x)["=="](50)
	T(y)["=="](20)
	T(w)["=="](60)
	T(h)["=="](10)
	love.graphics.setScissor()
	love.graphics.intersectScissor(5, 6, 7, 8)
	local rx, ry, rw, rh = love.graphics.getScissor()
	T(rx)["=="](5)
	T(ry)["=="](6)
	T(rw)["=="](7)
	T(rh)["=="](8)
end)

T.Test2D("love graphics stencil write and greater-zero test clip drawing", function()
	local love = new_love_graphics_env("11.0.0")
	love.graphics.clear(0, 1, 0, 1)
	love.graphics.setBlendMode("replace")

	love.graphics.stencil(function()
		love.graphics.rectangle("fill", 0, 0, 32, 64)
	end)

	love.graphics.setStencilTest("greater", 0)
	love.graphics.setColor(1, 0, 0, 1)
	love.graphics.rectangle("fill", 0, 0, 64, 64)
	love.graphics.setStencilTest()
	love.graphics.setBlendMode("alpha")
	love.graphics.setColor(0, 0, 1, 1)
	love.graphics.rectangle("fill", 48, 0, 16, 64)
	return function()
		T.AssertScreenPixel{pos = {16, 32}, color = {1, 0, 0, 1}, tolerance = 0.08}
		T.AssertScreenPixel{pos = {40, 32}, color = {0, 1, 0, 1}, tolerance = 0.08}
		T.AssertScreenPixel{pos = {56, 32}, color = {0, 0, 1, 1}, tolerance = 0.08}
	end
end)

T.Test2D("love mouse wheel refreshes LoveFrames hover state before dispatch", function()
	local love = new_love_mouse_env("11.0.0")
	local hover_object = {type = "list"}
	local old_loveframes = package.loaded.loveframes
	local old_mouse_position = window.GetMousePosition
	local ok, err = pcall(function()
		package.loaded.loveframes = {
			GetCollisions = function()
				return {hover_object}
			end,
			downobject = false,
		}
		window.GetMousePosition = function()
			return Vec2(42, 24)
		end
		love.mousepressed = function() end
		event.Call("LoveNewIndex", love, "mousepressed", love.mousepressed)
		event.Call("MouseInput", "mwheel_down", true)
		T(#package.loaded.loveframes.collisions)["=="](1)
		T(package.loaded.loveframes.collisions[1])["=="](hover_object)
		T(package.loaded.loveframes.hoverobject)["=="](hover_object)
	end)
	window.GetMousePosition = old_mouse_position
	package.loaded.loveframes = old_loveframes

	if not ok then error(err, 0) end
end)

T.Test2DFrames(
	"love line draw resets leaked scissor and stencil state each frame",
	2,
	function(_, _, frame)
		local love = _G.__love_line_draw_reset_env

		if not love then
			love = new_love_draw_env("11.0.0")
			_G.__love_line_draw_reset_env = love
			love.draw = function()
				local current_frame = _G.__love_line_draw_reset_frame

				if current_frame == 1 then
					love.graphics.setScissor(0, 0, 32, 64)

					love.graphics.stencil(function()
						love.graphics.rectangle("fill", 0, 0, 32, 64)
					end)

					love.graphics.setStencilTest("greater", 0)
					love.graphics.setColor(1, 0, 0, 1)
					love.graphics.rectangle("fill", 0, 0, 32, 64)
				else
					love.graphics.setColor(0, 0, 1, 1)
					love.graphics.rectangle("fill", 0, 0, 64, 64)
				end
			end
		end

		_G.__love_line_draw_reset_frame = frame
		love.line_draw(0)
	end,
	function(_, _, frame)
		if frame == 2 then
			T.AssertScreenPixel{pos = {16, 32}, color = {0, 0, 1, 1}, tolerance = 0.08}
			T.AssertScreenPixel{pos = {48, 32}, color = {0, 0, 1, 1}, tolerance = 0.08}
			_G.__love_line_draw_reset_env = nil
			_G.__love_line_draw_reset_frame = nil
		end
	end
)

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

T.Test2D("love graphics canvas newImageData reads back canvas pixels", function()
	local love = new_love_graphics_env("11.0.0")
	local canvas = love.graphics.newCanvas(16, 16)
	local source = love.image.newImageData(1, 1)
	source:setPixel(0, 0, 1, 0, 0, 1)
	local image = love.graphics.newImage(source)
	image:setFilter("nearest", "nearest", 1)
	love.graphics.setCanvas(canvas)
	love.graphics.clear(0, 0, 0, 0)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.draw(image, 0, 0, 0, 4, 4)
	love.graphics.setCanvas()
	local data = canvas:newImageData()
	local crop = canvas:newImageData(0, 0, 4, 4)
	local r, g, b, a = data:getPixel(1, 1)
	local cr, cg, cb, ca = crop:getPixel(1, 1)
	T(data.__line_type)["=="]("ImageData")
	T(crop:getWidth())["=="](4)
	T(crop:getHeight())["=="](4)
	T(r)["=="](1)
	T(g)["=="](0)
	T(b)["=="](0)
	T(a)["=="](1)
	T(cr)["=="](1)
	T(cg)["=="](0)
	T(cb)["=="](0)
	T(ca)["=="](1)
	return function()
		T.TexturePixel(canvas.fb:GetColorTexture(), 1, 1, 1, 0, 0, 1, 0.08)
	end
end)

T.Test2D("love graphics clear forwards stencil and depth extras", function()
	local love = new_love_graphics_env("11.0.0")
	local cmd = render2d.cmd
	local old_clear_attachments = cmd.ClearAttachments
	local captured
	local ok, err = pcall(function()
		cmd.ClearAttachments = function(_, config)
			captured = config
		end
		love.graphics.clear(0, 0, 0, 255, false, 0)
	end)
	cmd.ClearAttachments = old_clear_attachments

	if not ok then error(err, 0) end

	T(captured ~= nil)["=="](true)
	T(captured.stencil)["=="](false)
	T(captured.depth)["=="](0)
end)

T.Test2D("love graphics setCanvas accepts table targets", function()
	local love = new_love_graphics_env("11.0.0")
	local canvas = love.graphics.newCanvas(16, 16)
	love.graphics.setCanvas({canvas, depth = true})
	love.graphics.clear(255, 32, 0, 255)
	love.graphics.setCanvas()
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(canvas, 32, 32, 0, 4, 4)
	return function()
		T(love.graphics.getCanvas())["=="](nil)
		T(canvas.fb:GetDepthTexture() ~= nil)["=="](true)
		T.TexturePixel(canvas.fb:GetColorTexture(), 4, 4, 1, 32 / 255, 0, 1, 0.08)
		T.AssertScreenPixel{pos = {40, 40}, color = {1, 32 / 255, 0, 1}, tolerance = 0.08}
	end
end)

T.Test2D("love graphics custom shader draws to canvas", function()
	local love = new_love_graphics_env("11.0.0")
	local canvas = love.graphics.newCanvas(64, 64)
	local data = love.image.newImageData(1, 1)
	data:setPixel(0, 0, 1, 1, 1, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		#ifdef VERTEX
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			return vec4(1.0, 0.0, 0.0, 1.0);
		}
		#endif
	]])
	love.graphics.setCanvas(canvas)
	love.graphics.clear(0, 0, 0, 0)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.draw(image, 8, 8, 0, 32, 32)
	love.graphics.setShader()
	love.graphics.setCanvas()
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(canvas, 0, 0)
	return function()
		T.TexturePixel(canvas.fb:GetColorTexture(), 16, 16, 1, 0, 0, 1, 0.08)
		T.AssertScreenPixel{pos = {16, 16}, color = {1, 0, 0, 1}, tolerance = 0.08}
	end
end)

T.Test2D("love graphics shader rewrites texelFetch for Image and VolumeImage on canvas", function()
	local love = new_love_graphics_env("11.0.0")
	local canvas = love.graphics.newCanvas(64, 64)
	local base_data = love.image.newImageData(1, 1)
	local layer = love.image.newImageData(1, 1)
	base_data:setPixel(0, 0, 1, 1, 1, 1)
	layer:setPixel(0, 0, 1, 0, 0, 1)
	local image = love.graphics.newImage(base_data)
	image:setFilter("nearest", "nearest", 1)
	local volume = love.graphics.newVolumeImage({layer})
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		extern VolumeImage colortables;
		#ifdef VERTEX
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			vec4 base = texelFetch(tex, ivec2(0, 0), 0);
			vec4 tint = texelFetch(colortables, ivec3(0, 0, 0), 0);
			return base * tint * color;
		}
		#endif
	]])
	shader:send("colortables", volume)
	love.graphics.setCanvas(canvas)
	love.graphics.clear(0, 0, 0, 0)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.draw(image, 8, 8, 0, 32, 32)
	love.graphics.setShader()
	love.graphics.setCanvas()
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(canvas, 0, 0)
	return function()
		T.TexturePixel(canvas.fb:GetColorTexture(), 16, 16, 1, 0, 0, 1, 0.08)
		T.AssertScreenPixel{pos = {16, 16}, color = {1, 0, 0, 1}, tolerance = 0.08}
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

T.Test2D("love graphics filled polygon renders solid color", function()
	local love = new_love_graphics_env("11.0.0")
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(1, 0, 0, 1)
	love.graphics.polygon("fill", 32, 32, 96, 32, 96, 96, 32, 96)
	return function()
		T.AssertScreenPixel{pos = {64, 64}, color = {1, 0, 0, 1}, tolerance = 0.08}
		T.AssertScreenPixel{pos = {16, 16}, color = {0, 0, 0, 1}, tolerance = 0.08}
	end
end)

T.Test2D("love graphics filled concave polygon renders solid color", function()
	local love = new_love_graphics_env("11.0.0")
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(0, 0, 1, 1)
	love.graphics.polygon("fill", 32, 32, 96, 32, 96, 48, 64, 48, 64, 96, 32, 96)
	return function()
		T.AssertScreenPixel{pos = {48, 80}, color = {0, 0, 1, 1}, tolerance = 0.08}
		T.AssertScreenPixel{pos = {80, 80}, color = {0, 0, 0, 1}, tolerance = 0.08}
	end
end)

T.Test2D("love graphics filled polygon ignores prior image texture state", function()
	local love = new_love_graphics_env("11.0.0")
	local image = make_quadrant_image(love)
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.draw(image, 0, 0, 0, 16, 16)
	love.graphics.setColor(0, 1, 0, 1)
	love.graphics.polygon("fill", 112, 32, 176, 32, 176, 96, 112, 96)
	return function()
		T.AssertScreenPixel{pos = {144, 64}, color = {0, 1, 0, 1}, tolerance = 0.08}
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

T.Test2D("love graphics image wrap defaults to clamp and supports clampzero", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(1, 1)
	local image = love.graphics.newImage(data)
	local tex = love._line_env.textures[image]
	local wrap_s, wrap_t = image:getWrap()
	T(wrap_s)["=="]("clamp")
	T(wrap_t)["=="]("clamp")
	T(tex.config.sampler.wrap_s)["=="]("clamp_to_edge")
	T(tex.config.sampler.wrap_t)["=="]("clamp_to_edge")
	image:setWrap("clampzero")
	wrap_s, wrap_t = image:getWrap()
	T(wrap_s)["=="]("clampzero")
	T(wrap_t)["=="]("clampzero")
	T(tex.config.sampler.wrap_s)["=="]("clamp_to_border")
	T(tex.config.sampler.wrap_t)["=="]("clamp_to_border")
	T(tex.config.sampler.border_color)["=="]("float_transparent_black")
end)

T.Test2D("love graphics linear drawq samples the requested texel", function()
	local love = new_love_graphics_env("11.0.0")
	local image = make_quadrant_image(love)
	local quad = love.graphics.newQuad(0, 0, 1, 1, 2, 2)
	image:setFilter("linear", "linear", 1)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.draw(image, quad, 32, 32, 0, 64, 64)
	return function()
		T.AssertScreenPixel{pos = {64, 64}, color = {1, 1, 0, 1}, tolerance = 0.12}
	end
end)

T.Test2D("love graphics adjacent linear quads do not leave a seam", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(4, 2)

	for y = 0, 1 do
		for x = 0, 3 do
			data:setPixel(x, y, 1, 0, 0, 1)
		end
	end

	local image = love.graphics.newImage(data)
	local left = love.graphics.newQuad(0, 0, 2, 2, image)
	local right = love.graphics.newQuad(2, 0, 2, 2, image)
	image:setFilter("linear", "linear", 1)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.draw(image, left, 32, 32, 0, 15.75, 16)
	love.graphics.draw(image, right, 63.5, 32, 0, 15.75, 16)
	return function()
		T.AssertScreenPixel{pos = {63, 48}, color = {1, 0, 0, 1}, tolerance = 0.15}
		T.AssertScreenPixel{pos = {64, 48}, color = {1, 0, 0, 1}, tolerance = 0.15}
		T.AssertScreenPixel{pos = {65, 48}, color = {1, 0, 0, 1}, tolerance = 0.15}
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

T.Test2D("love graphics spritebatch add returns inserted quad id", function()
	local love = new_love_graphics_env("11.0.0")
	local image = make_quadrant_image(love)
	local quad = love.graphics.newQuad(0, 0, 1, 1, image)
	local batch = love.graphics.newSpriteBatch(image, 2)
	local id1 = batch:add(quad)
	local id2 = batch:add(quad)
	batch:set(id1, quad, 32, 32, 0, 32, 32)
	batch:set(id2, quad, 80, 32, 0, 32, 32)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(batch, 0, 0)
	return function()
		T(id1)["=="](1)
		T(id2)["=="](2)
		T.AssertScreenPixel{pos = {40, 40}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {88, 40}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {4, 4}, color = {0, 0, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics spritebatch defaults size", function()
	local love = new_love_graphics_env()
	local image = make_quadrant_image(love)
	local batch = love.graphics.newSpriteBatch(image)
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

T.Test("love graphics spritebatch flush compatibility", function()
	local love = new_love_graphics_env("11.0.0")
	local image = make_quadrant_image(love)
	local batch = love.graphics.newSpriteBatch(image, 4)
	batch:clear()
	batch:add(16, 24)
	T(batch:flush())["=="](batch)
	T(batch.entries[1].x)["=="](16)
	T(batch.entries[1].y)["=="](24)
end)

T.Test("love graphics newVolumeImage packs layers into an atlas", function()
	local love = new_love_graphics_env("11.0.0")
	local layer_a = love.image.newImageData(1, 1)
	local layer_b = love.image.newImageData(1, 1)
	layer_a:setPixel(0, 0, 1, 0, 0, 1)
	layer_b:setPixel(0, 0, 0, 1, 0, 1)
	local volume = love.graphics.newVolumeImage({layer_a, layer_b})
	local atlas = volume:getData()
	local texture_types = love.graphics.getTextureTypes()
	local r1, g1, b1, a1 = atlas:getPixel(0, 0)
	local r2, g2, b2, a2 = atlas:getPixel(0, 1)
	T(texture_types.volume)["=="](true)
	T(volume:typeOf("VolumeImage"))["=="](true)
	T(({volume:getDimensions()})[1])["=="](1)
	T(({volume:getDimensions()})[2])["=="](1)
	T(({volume:getDimensions()})[3])["=="](2)
	T(atlas:getWidth())["=="](1)
	T(atlas:getHeight())["=="](2)
	T(r1)["=="](1)
	T(g1)["=="](0)
	T(b1)["=="](0)
	T(a1)["=="](1)
	T(r2)["=="](0)
	T(g2)["=="](1)
	T(b2)["=="](0)
	T(a2)["=="](1)
end)

T.Test2D("love graphics shader rewrites texelFetch for Image and VolumeImage", function()
	local love = new_love_graphics_env("11.0.0")
	local base_data = love.image.newImageData(1, 1)
	local layer = love.image.newImageData(1, 1)
	base_data:setPixel(0, 0, 1, 1, 1, 1)
	layer:setPixel(0, 0, 1, 0, 0, 1)
	local image = love.graphics.newImage(base_data)
	image:setFilter("nearest", "nearest", 1)
	local volume = love.graphics.newVolumeImage({layer})
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		extern VolumeImage colortables;
		#ifdef VERTEX
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			vec4 base = texelFetch(tex, ivec2(0, 0), 0);
			vec4 tint = texelFetch(colortables, ivec3(0, 0, 0), 0);
			return base * tint * color;
		}
		#endif
	]])
	shader:send("colortables", volume)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.draw(image, 32, 32, 0, 32, 32)
	love.graphics.setShader()
	return function()
		T.AssertScreenPixel{pos = {40, 40}, color = {1, 0, 0, 1}, tolerance = 0.1}
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

T.Test2D("love graphics depth mode round-trips and resets", function()
	local love = new_love_graphics_env("11.0.0")
	love.graphics.setDepthMode("greater", true)
	local mode, write = love.graphics.getDepthMode()
	T(mode)["=="]("greater")
	T(write)["=="](true)
	love.graphics.setDepthMode()
	local reset_mode, reset_write = love.graphics.getDepthMode()
	T(reset_mode)["=="](nil)
	T(reset_write)["=="](false)
end)

T.Test2D("love graphics greater depth mode honors higher instance z in Love shaders", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(2, 1)
	data:setPixel(0, 0, 1, 0, 0, 1)
	data:setPixel(1, 0, 0, 1, 0, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		2,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	mesh:attachAttribute("Pallete", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0.100000, 0.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	instances:setVertex(2, 32, 32, 0.100004, 1.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			ivec2 textr = ivec2(int(uvoff.x), int(uvoff.y));
			return texelFetch(tex, textr, 0) * color * vec4(vec3(imgshd), 1.0);
		}
		#endif
	]])
	love.graphics.clear(0, 0, 0, 255, false, 0)
	love.graphics.setDepthMode("greater", true)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.drawInstanced(mesh, 2)
	love.graphics.setShader()
	love.graphics.setDepthMode()
	return function()
		T.AssertScreenPixel{pos = {40, 40}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics greater depth mode initializes screen depth without explicit clear", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(2, 1)
	data:setPixel(0, 0, 1, 0, 0, 1)
	data:setPixel(1, 0, 0, 1, 0, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		2,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	mesh:attachAttribute("Pallete", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0.100000, 0.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	instances:setVertex(2, 32, 32, 0.100004, 1.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			ivec2 textr = ivec2(int(uvoff.x), int(uvoff.y));
			return texelFetch(tex, textr, 0) * color * vec4(vec3(imgshd), 1.0);
		}
		#endif
	]])
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setDepthMode("greater", true)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.drawInstanced(mesh, 2, 48, 24, 0, 1.5, 1.5)
	love.graphics.setShader()
	love.graphics.setDepthMode()
	return function()
		T.AssertScreenPixel{pos = {108, 84}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics depth persists across separate instanced draws", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(2, 1)
	data:setPixel(0, 0, 1, 0, 0, 1)
	data:setPixel(1, 0, 0, 1, 0, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances_a = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		1,
		nil,
		"dynamic"
	)
	local instances_b = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		1,
		nil,
		"dynamic"
	)
	instances_a:setVertex(1, 32, 32, 0.100000, 0.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	instances_b:setVertex(1, 32, 32, 0.100004, 1.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			return texelFetch(tex, ivec2(int(uvoff.x), 0), 0) * color * vec4(vec3(imgshd), 1.0);
		}
		#endif
	]])
	love.graphics.clear(0, 0, 0, 255, false, 0)
	love.graphics.setDepthMode("greater", true)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	mesh:attachAttribute("InstancePosition", instances_a, "perinstance")
	mesh:attachAttribute("UVOffset", instances_a, "perinstance")
	mesh:attachAttribute("ImageDim", instances_a, "perinstance")
	mesh:attachAttribute("ImageShade", instances_a, "perinstance")
	mesh:attachAttribute("Scale", instances_a, "perinstance")
	mesh:attachAttribute("Pallete", instances_a, "perinstance")
	love.graphics.drawInstanced(mesh, 1)
	mesh:attachAttribute("InstancePosition", instances_b, "perinstance")
	mesh:attachAttribute("UVOffset", instances_b, "perinstance")
	mesh:attachAttribute("ImageDim", instances_b, "perinstance")
	mesh:attachAttribute("ImageShade", instances_b, "perinstance")
	mesh:attachAttribute("Scale", instances_b, "perinstance")
	mesh:attachAttribute("Pallete", instances_b, "perinstance")
	love.graphics.drawInstanced(mesh, 1)
	love.graphics.setShader()
	love.graphics.setDepthMode()
	return function()
		T.AssertScreenPixel{pos = {40, 40}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics depth mode survives instanced parent transforms", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(2, 1)
	data:setPixel(0, 0, 1, 0, 0, 1)
	data:setPixel(1, 0, 0, 1, 0, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		2,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	mesh:attachAttribute("Pallete", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0.100000, 0.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	instances:setVertex(2, 32, 32, 0.100004, 1.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			ivec2 textr = ivec2(int(uvoff.x), int(uvoff.y));
			return texelFetch(tex, textr, 0) * color * vec4(vec3(imgshd), 1.0);
		}
		#endif
	]])
	love.graphics.clear(0, 0, 0, 255, false, 0)
	love.graphics.setDepthMode("greater", true)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.drawInstanced(mesh, 2, 48, 24, 0, 1.5, 1.5)
	love.graphics.setShader()
	love.graphics.setDepthMode()
	return function()
		T.AssertScreenPixel{pos = {140, 104}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics depth mode survives nested camera transforms", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(2, 1)
	data:setPixel(0, 0, 1, 0, 0, 1)
	data:setPixel(1, 0, 0, 1, 0, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		2,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	mesh:attachAttribute("Pallete", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0.100000, 0.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	instances:setVertex(2, 32, 32, 0.100004, 1.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			ivec2 textr = ivec2(int(uvoff.x), int(uvoff.y));
			return texelFetch(tex, textr, 0) * color * vec4(vec3(imgshd), 1.0);
		}
		#endif
	]])
	love.graphics.clear(0, 0, 0, 255, false, 0)
	love.graphics.setDepthMode("greater", true)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.push()
	love.graphics.translate(32, 20)
	love.graphics.drawInstanced(mesh, 2, 48, 24, 0, 1.5, 1.5)
	love.graphics.pop()
	love.graphics.setShader()
	love.graphics.setDepthMode()
	return function()
		T.AssertScreenPixel{pos = {140, 104}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics nested camera transforms keep vec3 instance positioning without depth", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(2, 1)
	data:setPixel(0, 0, 1, 0, 0, 1)
	data:setPixel(1, 0, 0, 1, 0, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		2,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	mesh:attachAttribute("Pallete", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0.100000, 0.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	instances:setVertex(2, 32, 32, 0.100004, 1.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			ivec2 textr = ivec2(int(uvoff.x), int(uvoff.y));
			return texelFetch(tex, textr, 0) * color * vec4(vec3(imgshd), 1.0);
		}
		#endif
	]])
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.push()
	love.graphics.translate(32, 20)
	love.graphics.drawInstanced(mesh, 2, 48, 24, 0, 1.5, 1.5)
	love.graphics.pop()
	love.graphics.setShader()
	return function()
		T.AssertScreenPixel{pos = {140, 104}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics stone kingdoms main shader draws unpaletted instanced tiles", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(64, 32)

	for x = 0, 31 do
		for y = 0, 31 do
			data:setPixel(x, y, 0, 1, 0, 1)
		end
	end

	for x = 32, 63 do
		for y = 0, 31 do
			data:setPixel(x, y, 8 / 255, 8 / 255, 0, 1)
		end
	end

	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local layer = love.image.newImageData(20, 20)
	layer:setPixel(10, 10, 1, 1, 0, 1)
	local colortables = love.graphics.newVolumeImage({layer})
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		1,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	mesh:attachAttribute("Pallete", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0.1, 0, 0, 32, 32, 1, 1, 1, 0)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		varying float pallete;
		extern VolumeImage colortables;
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		varying vec2 imgscale;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			pallete = Pallete;
			imgscale = Scale;
			if (abs(imgscale.x) < 0.0001) imgscale.x = 1.0;
			if (abs(imgscale.y) < 0.0001) imgscale.y = 1.0;
			vertex_position.xy *= ImageDim;
			vertex_position.xy *= imgscale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		ivec2 redGreenToPosition(float redValue, float greenValue) {
			int redIndex = int(floor(redValue * 255.0));
			int x = (redIndex / 8) * 10;
			int greenIndex = int(floor(greenValue * 255.0));
			int y = (greenIndex / 8) * 10;
			return ivec2(x, y);
		}
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			color.xyz *= imgshd;
			ivec2 textr = ivec2(int(ceil(uvoff.x + imgdim.x * texture_coords.x)), int(ceil(uvoff.y + imgdim.y * texture_coords.y)));
			vec4 texcolor = texelFetch(tex, textr, 0);
			if (texcolor.a < 1.0) discard;
			if (pallete > 0.0) {
				vec2 ct = redGreenToPosition(texcolor.x, texcolor.y);
				if (ct.x == 0 && ct.y == 0) return vec4(0, 0, 0, 0);
				return texelFetch(colortables, ivec3(int(ct.x), int(ct.y), int(floor(pallete - 1.0))), 0) * color;
			}
			return texcolor * color;
		}
		#endif
	]])
	shader:send("colortables", colortables)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.push()
	love.graphics.translate(32, 20)
	love.graphics.drawInstanced(mesh, 1, 48, 24, 0, 1, 1)
	love.graphics.pop()
	love.graphics.setShader()
	return function()
		T.AssertScreenPixel{pos = {128, 92}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics stone kingdoms main shader draws paletted instanced tiles", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(64, 32)

	for x = 0, 31 do
		for y = 0, 31 do
			data:setPixel(x, y, 0, 1, 0, 1)
		end
	end

	for x = 32, 63 do
		for y = 0, 31 do
			data:setPixel(x, y, 8 / 255, 8 / 255, 0, 1)
		end
	end

	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local layer = love.image.newImageData(20, 20)
	layer:setPixel(10, 10, 1, 1, 0, 1)
	local colortables = love.graphics.newVolumeImage({layer})
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		1,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	mesh:attachAttribute("Pallete", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0.1, 32, 0, 32, 32, 1, 1, 1, 1)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		varying float pallete;
		extern VolumeImage colortables;
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		varying vec2 imgscale;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			pallete = Pallete;
			imgscale = Scale;
			if (abs(imgscale.x) < 0.0001) imgscale.x = 1.0;
			if (abs(imgscale.y) < 0.0001) imgscale.y = 1.0;
			vertex_position.xy *= ImageDim;
			vertex_position.xy *= imgscale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		ivec2 redGreenToPosition(float redValue, float greenValue) {
			int redIndex = int(floor(redValue * 255.0));
			int x = (redIndex / 8) * 10;
			int greenIndex = int(floor(greenValue * 255.0));
			int y = (greenIndex / 8) * 10;
			return ivec2(x, y);
		}
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			color.xyz *= imgshd;
			ivec2 textr = ivec2(int(ceil(uvoff.x + imgdim.x * texture_coords.x)), int(ceil(uvoff.y + imgdim.y * texture_coords.y)));
			vec4 texcolor = texelFetch(tex, textr, 0);
			if (texcolor.a < 1.0) discard;
			if (pallete > 0.0) {
				vec2 ct = redGreenToPosition(texcolor.x, texcolor.y);
				if (ct.x == 0 && ct.y == 0) return vec4(0, 0, 0, 0);
				return texelFetch(colortables, ivec3(int(ct.x), int(ct.y), int(floor(pallete - 1.0))), 0) * color;
			}
			return texcolor * color;
		}
		#endif
	]])
	shader:send("colortables", colortables)
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.push()
	love.graphics.translate(32, 20)
	love.graphics.drawInstanced(mesh, 1, 48, 24, 0, 1, 1)
	love.graphics.pop()
	love.graphics.setShader()
	return function()
		T.AssertScreenPixel{pos = {128, 92}, color = {1, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics canvas keeps instanced parent transforms", function()
	local love = new_love_graphics_env("11.0.0")
	local canvas = love.graphics.newCanvas(160, 160)
	local data = love.image.newImageData(2, 1)
	data:setPixel(0, 0, 1, 0, 0, 1)
	data:setPixel(1, 0, 0, 1, 0, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 2},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
		},
		2,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0.0, 0.0, 1.0, 1.0, 1.0, 32, 32)
	instances:setVertex(2, 32, 32, 1.0, 0.0, 1.0, 1.0, 1.0, 32, 32)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec2 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			ivec2 textr = ivec2(int(uvoff.x), int(uvoff.y));
			return texelFetch(tex, textr, 0) * color * vec4(vec3(imgshd), 1.0);
		}
		#endif
	]])
	love.graphics.setCanvas(canvas)
	love.graphics.clear(0, 0, 0, 0)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.drawInstanced(mesh, 2, 48, 24, 0, 1.5, 1.5)
	love.graphics.setShader()
	love.graphics.setCanvas()
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(canvas, 0, 0)
	return function()
		T.TexturePixel(canvas.fb:GetColorTexture(), 108, 84, 0, 1, 0, 1, 0.1)
		T.AssertScreenPixel{pos = {108, 84}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics canvas keeps instanced depth with parent transforms", function()
	local love = new_love_graphics_env("11.0.0")
	local canvas = love.graphics.newCanvas(160, 160)
	local data = love.image.newImageData(2, 1)
	data:setPixel(0, 0, 1, 0, 0, 1)
	data:setPixel(1, 0, 0, 1, 0, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		2,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	mesh:attachAttribute("Pallete", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0.100000, 0.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	instances:setVertex(2, 32, 32, 0.100004, 1.0, 0.0, 1.0, 1.0, 1.0, 32, 32, 0)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			ivec2 textr = ivec2(int(uvoff.x), int(uvoff.y));
			return texelFetch(tex, textr, 0) * color * vec4(vec3(imgshd), 1.0);
		}
		#endif
	]])
	love.graphics.setCanvas({canvas, depth = true})
	love.graphics.clear(0, 0, 0, 0, false, 0)
	love.graphics.setDepthMode("greater", true)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.push()
	love.graphics.translate(32, 20)
	love.graphics.drawInstanced(mesh, 2, 48, 24, 0, 1.5, 1.5)
	love.graphics.pop()
	love.graphics.setShader()
	love.graphics.setDepthMode()
	love.graphics.setCanvas()
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.draw(canvas, 0, 0)
	return function()
		T(canvas.fb:GetDepthTexture() ~= nil)["=="](true)
		T.TexturePixel(canvas.fb:GetColorTexture(), 140, 104, 0, 1, 0, 1, 0.1)
		T.AssertScreenPixel{pos = {140, 104}, color = {0, 1, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics fully transparent shader output does not block later depth-tested draws", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(1, 1)
	data:setPixel(0, 0, 1, 1, 1, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local front_instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		1,
		nil,
		"dynamic"
	)
	local back_instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		1,
		nil,
		"dynamic"
	)
	front_instances:setVertex(1, 32, 32, 0.100004, 0, 0, 1, 1, 1, 64, 64, 0)
	back_instances:setVertex(1, 32, 32, 0.100000, 0, 0, 1, 1, 1, 64, 64, 0)
	local front_shader = love.graphics.newShader([[
		#pragma language glsl3
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			if (screen_coords.y < 64.0) {
				return vec4(0.0, 0.0, 0.0, 0.0);
			}
			return vec4(1.0, 0.0, 0.0, 1.0);
		}
		#endif
	]])
	local back_shader = love.graphics.newShader([[
		#pragma language glsl3
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			return vec4(0.0, 1.0, 0.0, 1.0);
		}
		#endif
	]])
	love.graphics.clear(0, 0, 0, 255, false, 0)
	love.graphics.setDepthMode("greater", true)
	love.graphics.setColor(1, 1, 1, 1)
	mesh:attachAttribute("InstancePosition", front_instances, "perinstance")
	mesh:attachAttribute("UVOffset", front_instances, "perinstance")
	mesh:attachAttribute("ImageDim", front_instances, "perinstance")
	mesh:attachAttribute("ImageShade", front_instances, "perinstance")
	mesh:attachAttribute("Scale", front_instances, "perinstance")
	mesh:attachAttribute("Pallete", front_instances, "perinstance")
	love.graphics.setShader(front_shader)
	love.graphics.drawInstanced(mesh, 1)
	mesh:attachAttribute("InstancePosition", back_instances, "perinstance")
	mesh:attachAttribute("UVOffset", back_instances, "perinstance")
	mesh:attachAttribute("ImageDim", back_instances, "perinstance")
	mesh:attachAttribute("ImageShade", back_instances, "perinstance")
	mesh:attachAttribute("Scale", back_instances, "perinstance")
	mesh:attachAttribute("Pallete", back_instances, "perinstance")
	love.graphics.setShader(back_shader)
	love.graphics.drawInstanced(mesh, 1)
	love.graphics.setShader()
	love.graphics.setDepthMode()
	return function()
		T.AssertScreenPixel{pos = {40, 40}, color = {0, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {40, 72}, color = {1, 0, 0, 1}, tolerance = 0.1}
	end
end)

T.Test2D("love graphics terrain and tall sprite depth order matches pixel overlap", function()
	local love = new_love_graphics_env("11.0.0")
	local data = love.image.newImageData(2, 1)
	data:setPixel(0, 0, 0.75, 0.7, 0.45, 1)
	data:setPixel(1, 0, 0.55, 0.8, 0.5, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local terrain_instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		1,
		nil,
		"dynamic"
	)
	local tree_instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 3},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
			{"Pallete", "float", 1},
		},
		1,
		nil,
		"dynamic"
	)
	terrain_instances:setVertex(1, 32, 88, 0.100000, 0, 0, 1, 1, 1, 96, 40, 0)
	tree_instances:setVertex(1, 32, 24, 0.100004, 1, 0, 1, 1, 1, 96, 120, 0)
	local shader = love.graphics.newShader([[
		#pragma language glsl3
		varying vec2 uvoff;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec3 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		attribute float Pallete;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition.xy;
			vertex_position.z = 1.0 - InstancePosition.z;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			return texelFetch(tex, ivec2(int(uvoff.x), 0), 0) * color * vec4(vec3(imgshd), 1.0);
		}
		#endif
	]])
	love.graphics.clear(0, 0, 0, 255, false, 0)
	love.graphics.setDepthMode("greater", true)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	mesh:attachAttribute("InstancePosition", terrain_instances, "perinstance")
	mesh:attachAttribute("UVOffset", terrain_instances, "perinstance")
	mesh:attachAttribute("ImageDim", terrain_instances, "perinstance")
	mesh:attachAttribute("ImageShade", terrain_instances, "perinstance")
	mesh:attachAttribute("Scale", terrain_instances, "perinstance")
	mesh:attachAttribute("Pallete", terrain_instances, "perinstance")
	love.graphics.drawInstanced(mesh, 1)
	mesh:attachAttribute("InstancePosition", tree_instances, "perinstance")
	mesh:attachAttribute("UVOffset", tree_instances, "perinstance")
	mesh:attachAttribute("ImageDim", tree_instances, "perinstance")
	mesh:attachAttribute("ImageShade", tree_instances, "perinstance")
	mesh:attachAttribute("Scale", tree_instances, "perinstance")
	mesh:attachAttribute("Pallete", tree_instances, "perinstance")
	love.graphics.drawInstanced(mesh, 1)
	love.graphics.setShader()
	love.graphics.setDepthMode()
	return function()
		T.AssertScreenPixel{pos = {48, 104}, color = {0.55, 0.8, 0.5, 1}, tolerance = 0.12}
		T.AssertScreenPixel{pos = {48, 72}, color = {0.55, 0.8, 0.5, 1}, tolerance = 0.12}
		T.AssertScreenPixel{pos = {140, 120}, color = {0, 0, 0, 1}, tolerance = 0.12}
	end
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

T.Test2D("love graphics Love11 normalized color API stays normalized", function()
	local love = new_love_graphics_env("11.0.0")
	love.graphics.setBackgroundColor(0.2, 0.1, 0.05, 1)
	local br, bg, bb, ba = love.graphics.getBackgroundColor()
	T(br)["=="](0.2)
	T(bg)["=="](0.1)
	T(bb)["=="](0.05)
	T(ba)["=="](1)
	love.graphics.clear()
	love.graphics.setColor(1, 1, 1, 1)
	local r, g, b, a = love.graphics.getColor()
	T(r)["=="](1)
	T(g)["=="](1)
	T(b)["=="](1)
	T(a)["=="](1)
	love.graphics.rectangle("fill", 32, 32, 32, 32)
	return function()
		T.AssertScreenPixel{pos = {8, 8}, color = {0.2, 0.1, 0.05, 1}, tolerance = 0.08}
		T.AssertScreenPixel{pos = {40, 40}, color = {1, 1, 1, 1}, tolerance = 0.08}
	end
end)

T.Test("love graphics legacy byte color API stays byte-based", function()
	local love = new_love_graphics_env("0.10.1")
	love.graphics.setBackgroundColor(32, 16, 8, 255)
	love.graphics.setColor(255, 64, 32, 255)
	local br, bg, bb, ba = love.graphics.getBackgroundColor()
	local r, g, b, a = love.graphics.getColor()
	T(br)["=="](32)
	T(bg)["=="](16)
	T(bb)["=="](8)
	T(ba)["=="](255)
	T(r)["=="](255)
	T(g)["=="](64)
	T(b)["=="](32)
	T(a)["=="](255)
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

T.Test2D("love graphics drawInstanced supports Love vertex shader instance attributes", function()
	local love = new_love_graphics_env("11.0.0")
	local image = make_quadrant_image(love)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 2},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
		},
		2,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0, 0, 0.5, 0.5, 1, 32, 32)
	instances:setVertex(2, 96, 32, 0.5, 0.5, 0.5, 0.5, 1, 32, 32)
	local shader = love.graphics.newShader([[
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec2 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			texture_coords = uvoff + imgdim * texture_coords;
			return Texel(tex, texture_coords) * vec4(vec3(imgshd), 1.0) * color;
		}
		#endif
	]])
	love.graphics.clear(0, 0, 0, 255)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.drawInstanced(mesh, 2)
	love.graphics.setShader()
	return function()
		T.AssertScreenPixel{pos = {40, 40}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {56, 56}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {104, 40}, color = {0, 128 / 255, 1, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {120, 56}, color = {0, 128 / 255, 1, 1}, tolerance = 0.1}
	end
end)

T.Test("love graphics custom mesh setVertex handles nil clears", function()
	local love = new_love_graphics_env("11.0.0")
	local mesh = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 2},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
		},
		4,
		nil,
		"dynamic"
	)
	mesh:setVertex(1, 10, 20, 30, 40, 50, 60, 0.75, 1.25)
	T(({mesh:getVertexAttribute(1, 1)})[1])["=="](10)
	T(({mesh:getVertexAttribute(1, 1)})[2])["=="](20)
	T(({mesh:getVertexAttribute(1, 4)})[1])["=="](0.75)
	T(({mesh:getVertexAttribute(1, 5)})[1])["=="](1.25)
	T(({mesh:getVertexAttribute(1, 5)})[2])["=="](1.25)
	mesh:setVertex(1)
	T(({mesh:getVertexAttribute(1, 1)})[1])["=="](0)
	T(({mesh:getVertexAttribute(1, 1)})[2])["=="](0)
	T(({mesh:getVertexAttribute(1, 4)})[1])["=="](0)
	T(({mesh:getVertexAttribute(1, 5)})[1])["=="](0)
	T(({mesh:getVertexAttribute(1, 5)})[2])["=="](0)
end)
