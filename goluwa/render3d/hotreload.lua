HOTRELOAD = false
local render = import("goluwa/render/render.lua")
local timer = import("goluwa/timer.lua")
local render3d = import.loaded["goluwa/render3d/render3d.lua"]
local callback_id = "render3d_hotreload"

for k in pairs(import.loaded) do
	if k:find("goluwa/render3d") then import.loaded[k] = nil end
end

render.RegisterFlushCallback(callback_id, function(reason)
	if reason ~= "begin_frame" then return end

	render.UnregisterFlushCallback(callback_id)

	if render3d then
		render3d.initializing = true
		render3d.pipelines = nil
		render3d.pipelines_i = nil

		if render3d.ResetState then render3d:ResetState() end
	end

	local module = import("goluwa/render3d/render3d.lua")
	module:Initialize()

	timer.Delay(0, function()
		collectgarbage("collect")
	end, callback_id .. "_gc")
end)
