local event = import("goluwa/event.lua")
local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local commands = import("goluwa/cli/commands.lua")
local system = import("goluwa/system.lua")
local gine = import("addons/gmod/lua/gine.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local render
local render3d
local render2d
local test_render = {}
local width = 512
local height = 512

function test_render.Init()
	if not test_render.init then
		render = import("goluwa/render/render.lua")
		render.Initialize{headless = true, width = width, height = height}
		test_render.init = true
	end
end

function test_render.Init2D()
	test_render.Init()

	if not test_render.render2d_init then
		render2d = import("goluwa/render2d/render2d.lua")
		render2d.Initialize()
		test_render.render2d_init = true
	end
end

function test_render.Init3D()
	test_render.Init()

	if not render3d then render3d = import("goluwa/render3d/render3d.lua") end

	if not test_render.render3d_init then
		render3d.Initialize{
			passes = {
				import("goluwa/render3d/passes/gbuffer.lua"),
				import("goluwa/render3d/passes/blit.lua"),
			},
		}
		test_render.render3d_init = true
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
		render2d.MarkPipelineStateDirty()
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
			render2d.MarkPipelineStateDirty()
			render2d.BindPipeline()
			render2d.ResetState()
			cb(width, height, frame)
			render.EndFrame()

			if after_frame then after_frame(width, height, frame) end
		end
	end
end

local function draw_3d_func()
	system.SetFrameNumber(system.GetFrameNumber() + 1)
	render.Draw(1)
end

function test_render.Draw3D(cb)
	test_render.Init3D()
	render3d.ResetState()
	cb(draw_3d_func)
	objects.CheckRemovedObjects()
	local found = false
	local children = Entity.World:GetChildrenList()

	for _, ent in ipairs(children) do
		if ent:IsValid() then
			ent:Remove()
			print("Entity not removed: " .. tostring(ent))
			found = true
		end
	end

	if found then
		print("World children count after callback: " .. #Entity.World:GetChildrenList())
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
