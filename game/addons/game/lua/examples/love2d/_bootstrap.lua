local line = import("goluwa/love/line.lua")
local event = import("goluwa/event.lua")
return function(name)
	local love = assert(line.CreateLoveEnv(), "failed to create Love environment")
	local loaded = false

	local function ensure_loaded()
		if loaded then return end

		loaded = true

		if love.load then love.load() end
	end

	event.AddListener("Update", name .. "_update", function(dt)
		ensure_loaded()

		if love.update then love.update(dt) end
	end)

	event.AddListener("Draw2D", name .. "_draw", function()
		ensure_loaded()

		if love.draw then love.draw() end
	end)

	return love
end
