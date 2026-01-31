local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping render2d comprehensive tests.")
	return false
end

local event = require("event")
local ecs = require("ecs.ecs")
local render = require("render.render")
local render3d = require("render3d.render3d")
local render2d = require("render2d.render2d")
local Rect = require("structs.rect")
local Quat = require("structs.quat")
local Vec3 = require("structs.vec3")
local test_render = {}
local width = 512
local height = 512

function test_render.Draw2D(cb)
	if not test_render.init then
		render.Initialize({headless = true, width = width, height = height})
	end

	if not test_render.render2d_init then
		render2d.Initialize()
		test_render.render2d_init = true
	end

	render.BeginFrame()
	render2d.BindPipeline()
	render2d.ResetState()
	local finish = cb(width, height)
	render.EndFrame()

	if finish then finish() end
end

local function draw_3d_func()
	render.Draw(1)
end

function test_render.Draw3D(cb)
	if not test_render.init then
		render.Initialize({headless = true, width = width, height = height})
	end

	if not test_render.render3d_init then
		render3d.Initialize()
		test_render.render3d_init = true
	end

	local T = require("helpers.test")
	render3d.ResetState()
	cb(draw_3d_func)

	for _, ent in ipairs(ecs.Get3DWorld():GetChildrenList()) do
		if ent:IsValid() then
			ecs.Clear3DWorld()
			error("Entity not removed: " .. tostring(ent), 2)
		end
	end

	for _, ent in ipairs(ecs.Get2DWorld():GetChildrenList()) do
		if ent:IsValid() then
			ecs.Clear2DWorld()
			error("Entity not removed: " .. tostring(ent), 2)
		end
	end
end

return test_render
