local love = ... or _G.love
local ENV = love._line_env
local threads = import("goluwa/bindings/threads.lua")
love.system = love.system or {}

function love.system.getClipboardText()
	return system.GetClipboard()
end

function love.system.setClipboardText(str)
	system.SetClipboard(str)
end

function love.system.openURL(url)
	system.OpenURL(url)
end

function love.system.getOS()
	return jit.os
end

function love.system.getProcessorCount()
	return threads.get_thread_count()
end

function love.system.quit()
	logn("quit!")
end
