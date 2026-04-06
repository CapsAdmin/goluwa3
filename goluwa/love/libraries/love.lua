local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local love = ... or _G.love
local line = import("goluwa/love/line.lua") -- line_update and line_draw
function love.load() end

function love.conf(t) end

function love.getVersion()
	return love._version_major or 0,
	love._version_minor or 0,
	love._version_revision or 0,
	"goluwa"
end

function love.line_update(dt)
	if love._line_env.love_game_update_draw_hack == false then
		love._line_env.love_game_update_draw_hack = true -- this is stupid but it's because some games rely on update being called before draw
	end

	if love.update then line.pcall(love, love.update, dt) end

	for _, module in ipairs(love._line_env.update_modules or {}) do
		local update = type(module) == "table" and rawget(module, "update") or nil

		if type(update) == "function" then
			local request = rawget(module, "request")

			if type(request) == "table" and next(request) ~= nil then system.Sleep(0.001) end

			line.pcall(love, update, 0.001)
		end
	end
end

function love.line_draw(dt)
	if not love.draw then return end

	if love._line_env.love_game_update_draw_hack == false then return end

	render2d.PushMatrix()
	render2d.SetTexture()
	love.graphics.setShader()
	love.graphics.setScissor()
	love.graphics.setStencilTest()
	love.graphics.clear()
	love.graphics.setColor(love.graphics.getColor())
	love.graphics.setFont(love.graphics.getFont())
	line.pcall(love, love.draw, dt)
	render2d.PopMatrix()

	if love._line_env.error_message and not love._line_env.no_error then
		love.errhand(love._line_env.error_message)
	end
end

function love.errhand(msg)
	love.graphics.setFont()
	msg = tostring(msg)
	love.graphics.setBackgroundColor(89, 157, 220)
	love.graphics.setColor(255, 255, 255, 255)
	local trace = debug.traceback()
	local err = {}
	list.insert(err, "Error\n")
	list.insert(err, msg .. "\n\n")

	for l in string.gmatch(trace, "(.-)\n") do
		if not string.match(l, "boot.lua") then
			l = string.gsub(l, "stack traceback:", "Traceback\n")
			list.insert(err, l)
		end
	end

	local p = list.concat(err, "\n")
	p = string.gsub(p, "\t", "")
	p = string.gsub(p, "%[string \"(.-)\"%]", "%1")
	love.graphics.printf(p, 70, 70, love.graphics.getWidth() - 70)
end

event.AddListener("LoveNewIndex", "line_love", function(love, key, val)
	if key == "update" then
		if val then
			event.AddListener("Update", "line", function()
				for i = 1, line.speed do
					line.CallEvent("line_update", system.GetFrameTime())
				end
			end)
		else
			event.RemoveListener("Update", "line")
		end
	elseif key == "draw" then
		if val then
			event.AddListener("Draw2D", "line", function(dt)
				if menu and menu.IsVisible() then render2d.PushHSV(1, 0, 1) end

				line.CallEvent("line_draw", dt)

				if menu and menu.IsVisible() then render2d.PopHSV() end
			end)
		else
			event.RemoveListener("Draw2D", "line")
		end
	elseif key == "resize" then
		if val then
			event.AddListener("WindowFramebufferResized", "line", function(_, size)
				line.CallEvent("resize", size.x, size.y)
			end)
		else
			event.RemoveListener("WindowFramebufferResized", "line")
		end
	end
end)
