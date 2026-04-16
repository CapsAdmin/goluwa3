local event = import("goluwa/event.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Panel = import("goluwa/ecs/panel.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local commands = import("goluwa/commands.lua")
local gine = import("goluwa/gmod/gine.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local test_render = {}
local width = 512
local height = 512

function test_render.Init2D()
	if not test_render.init then
		render.Initialize{headless = true, width = width, height = height}
		test_render.init = true
	end

	if not test_render.render2d_init then
		render2d.Initialize()
		test_render.render2d_init = true
	end
end

function test_render.InitGMod2D(gamemode, skip_addons)
	test_render.Init2D()

	if gine.env and gine.env.gamemode and gine.env.vgui then return end

	local command = "ginit " .. tostring(gamemode or "sandbox") .. "," .. tostring(skip_addons == nil and 1 or skip_addons)
	local ok, err = commands.ExecuteCommandString(command)

	if not ok then error(err, 0) end

	test_render.Draw2D(function(w, h)
		render2d.SetColor(0, 0, 0, 1)
		render2d.DrawRect(0, 0, w, h)
	end)

	return gine.env
end

function test_render.Draw2D(cb)
	test_render.Init2D()

	if render.BeginFrame() then
		render2d.BindPipeline()
		render2d.ResetState()
		local finish = cb(width, height)
		render.EndFrame()

		if finish then finish() end
	end
end

function test_render.Draw2DFrames(frame_count, cb, after_frame)
	test_render.Init2D()

	for frame = 1, frame_count do
		if render.BeginFrame() then
			render2d.BindPipeline()
			render2d.ResetState()
			cb(width, height, frame)
			render.EndFrame()

			if after_frame then after_frame(width, height, frame) end
		end
	end
end

local function draw_3d_func()
	render.Draw(1)
end

function test_render.Draw3D(cb)
	if not test_render.init then
		render.Initialize{headless = true, width = width, height = height}
		test_render.init = true
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

	if physics and physics.ResetState then physics.ResetState() end

	if found then error("Not all entities were removed after test!") end
end

return test_render
