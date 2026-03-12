local event = import("goluwa/event.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Panel = import("goluwa/ecs/panel.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local test_render = {}
local width = 512
local height = 512

function test_render.Draw2D(cb)
	if not test_render.init then
		render.Initialize{headless = true, width = width, height = height}
	end

	if not test_render.render2d_init then
		render2d.Initialize()
		test_render.render2d_init = true
	end

	if render.BeginFrame() then
		render2d.BindPipeline()
		render2d.ResetState()
		local finish = cb(width, height)
		render.EndFrame()

		if finish then finish() end
	end
end

local function draw_3d_func()
	render.Draw(1)
end

function test_render.Draw3D(cb)
	if not test_render.init then
		render.Initialize{headless = true, width = width, height = height}
	end

	if not test_render.render3d_init then
		render3d.Initialize()
		test_render.render3d_init = true
	end

	local T = import("goluwa/helpers/test.lua")
	render3d.ResetState()
	cb(draw_3d_func)
	local found = false

	for _, ent in ipairs(Entity.World:GetChildrenList()) do
		if ent:IsValid() then
			ent:Remove()
			print("Entity not removed: " .. tostring(ent))
			found = true
		end
	end

	for _, ent in ipairs(Panel.World:GetChildrenList()) do
		if ent:IsValid() then
			ent:Remove()
			print("Entity not removed: " .. tostring(ent))
			found = true
		end
	end

	if found then error("Not all entities were removed after test!") end
end

return test_render