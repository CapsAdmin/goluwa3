local love = ... or _G.love
local ENV = love._line_env
love.event = love.event or {}
ENV.event_queue = ENV.event_queue or {}

function love.event.clear()
	list.clear(ENV.event_queue)
end

function love.event.push(e, a, b, c, d)
	list.insert(ENV.event_queue, {e, a, b, c, d})
end

function love.event.poll()
	return function()
		return love.event.wait()
	end
end

function love.event.pump() end

function love.event.quit()
	logn("love.event.quit")
end

function love.event.wait()
	local val = list.remove(ENV.event_queue, 1)

	if val then return unpack(val) end
end

love.handlers = {
	keypressed = function(...)
		if love.keypressed then return love.keypressed(...) end
	end,
	keyreleased = function(...)
		if love.keyreleased then return love.keyreleased(...) end
	end,
	textinput = function(...)
		if love.textinput then return love.textinput(...) end
	end,
	mousemoved = function(...)
		if love.mousemoved then return love.mousemoved(...) end
	end,
	mousepressed = function(...)
		if love.mousepressed then return love.mousepressed(...) end
	end,
	mousereleased = function(...)
		if love.mousereleased then return love.mousereleased(...) end
	end,
	wheelmoved = function(...)
		if love.wheelmoved then return love.wheelmoved(...) end
	end,
	resize = function(...)
		if love.resize then return love.resize(...) end
	end,
	focus = function(...)
		if love.focus then return love.focus(...) end
	end,
	visible = function(...)
		if love.visible then return love.visible(...) end
	end,
	quit = function(...)
		if love.quit then return love.quit(...) end
	end,
}