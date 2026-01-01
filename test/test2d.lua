local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping render2d comprehensive tests.")
	return false
end

local render = require("render.render")
local render2d = require("render2d.render2d")
local test2d = {}
local width = 512
local height = 512

function test2d.initialize()
	render.Initialize({headless = true, width = width, height = height})
	render2d.Initialize()
end

function test2d.draw(cb)
	test2d.initialize()
	render.BeginFrame()
	render2d.BindPipeline()
	render2d.ResetState()
	local finish = cb(width, height)
	render.EndFrame()

	if finish then finish() end
end

return test2d
