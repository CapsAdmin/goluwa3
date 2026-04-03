local T = import("test/environment.lua")
local line = import("goluwa/love/line.lua")
local window = import("goluwa/window.lua")
local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

T.Test2D("love window syncs cached game globals on mode and resize", function()
	local love = line.CreateLoveEnv("11.0.0")
	love._line_env.globals = {}
	local old_set_size = window.SetSize
	window.SetSize = function() end
	local ok, err = pcall(function()
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
	end)
	window.SetSize = old_set_size
	if not ok then error(err, 0) end
end)