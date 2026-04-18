local T = import("test/environment.lua")
local line = import("goluwa/love/line.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

local function with_fake_window(window, cb)
	window.GetSize = window.GetSize or function()
		return Vec2(0, 0)
	end
	window.GetTitle = window.GetTitle or function()
		return nil
	end
	local old_get_window = system.GetWindow
	system.GetWindow = function()
		return window
	end
	local ok, err = pcall(cb)
	system.GetWindow = old_get_window

	if not ok then error(err, 0) end
end

T.Test2D("love window syncs cached game globals on mode and resize", function()
	local love = line.CreateLoveEnv("11.0.0")
	love._line_env.globals = {}

	with_fake_window({
		SetSize = function() end,
	}, function()
		love.window.setMode(1280, 720)
		T(love._line_env.globals.ScreenWidth)["=="](1280)
		T(love._line_env.globals.ScreenHeight)["=="](720)
		T(love._line_env.globals.windowWidth)["=="](1280)
		T(love._line_env.globals.windowHeight)["=="](720)
		event.Call("WindowFramebufferResized", nil, Vec2(1366, 768))
		T(love._line_env.globals.ScreenWidth)["=="](1366)
		T(love._line_env.globals.ScreenHeight)["=="](768)
		T(love._line_env.globals.windowWidth)["=="](1366)
		T(love._line_env.globals.windowHeight)["=="](768)
		render2d.UpdateScreenSize(1366, 768)
		local render_width, render_height = render2d.GetSize()
		T(render_width)["=="](1366)
		T(render_height)["=="](768)
	end)
end)

T.Test("input release all clears stuck button state", function()
	local mouse_trigger = input.SetupInputEvent("Mouse")
	local released = {}
	mouse_trigger("button_1", true)
	mouse_trigger("button_2", true)
	T(input.IsMouseDown("button_1") ~= nil)["=="](true)
	T(input.IsMouseDown("button_2") ~= nil)["=="](true)

	input.ReleaseAll("Mouse", function(key, press)
		released[#released + 1] = {key = key, press = press}
	end)

	T(input.IsMouseDown("button_1") == nil)["=="](true)
	T(input.IsMouseDown("button_2") == nil)["=="](true)
	T(#released)["=="](2)
	T(released[1].press)["=="](false)
	T(released[2].press)["=="](false)
end)

T.Test2D("love window pixel scale follows framebuffer ratio", function()
	local love = line.CreateLoveEnv("11.0.0")
	local fake_window = {
		GetSize = function()
			return Vec2(1280, 720)
		end,
		GetFramebufferSize = function()
			return Vec2(1280, 720)
		end,
	}

	with_fake_window(fake_window, function()
		T(love.window.getPixelScale())["=="](1)
		T(love.window.getDPIScale())["=="](1)
		fake_window.GetFramebufferSize = function()
			return Vec2(2560, 1440)
		end
		T(love.window.getPixelScale())["=="](2)
		T(love.window.getDPIScale())["=="](2)
	end)
end)

T.Test2D("love window desktop fullscreen defaults to a sane fullscreen mode", function()
	local love = line.CreateLoveEnv("11.0.0")
	local modes = love.window.getFullscreenModes()
	local requested

	with_fake_window({
		SetSize = function(_, size)
			requested = size
		end,
	}, function()
		T(modes[1].width)["=="](1280)
		T(modes[1].height)["=="](720)
		love.window.setMode(0, 0, {fullscreen = true, fullscreentype = "desktop"})
		T(requested.x)["=="](1280)
		T(requested.y)["=="](720)
	end)
end)
