local system = import("goluwa/system.lua")
local tasks = import("goluwa/tasks.lua")
local native_threads = import("goluwa/bindings/threads.lua")
local love = ... or _G.love
local ENV = love._line_env
love.timer = love.timer or {}

function love.timer.step() end

function love.timer.getDelta()
	return system.GetFrameTime()
end

function love.timer.getFPS()
	return system.current_fps or 0
end

function love.timer.getMicroTime()
	return system.GetTime()
end

function love.timer.getTime()
	if love._version_minor == 8 then
		return math.ceil(system.GetElapsedTime())
	else
		return system.GetTime()
	end
end

function love.timer.getAverageDelta()
	return love.timer.getDelta()
end

function love.timer.sleep(ms)
	ms = tonumber(ms) or 0

	if ms <= 0 then return end

	local thread = love.thread.getThread()

	if thread then
		if thread.thread and tasks.coroutine_lookup[thread.thread] then
			thread.thread:Wait(ms)
			return
		end
	end

	native_threads.sleep(ms * 1000)
end
