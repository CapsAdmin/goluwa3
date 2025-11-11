local Renderer = require("graphics.render.instance")
local window = require("graphics.window")
local event = require("event")
local ffi = require("ffi")
local system = require("system")
local renderer = Renderer.New(
	{
		surface_handle = assert(window:GetSurfaceHandle()),
		present_mode = "fifo",
		image_count = nil, -- Use default (minImageCount + 1)
		surface_format_index = 1,
		composite_alpha = "opaque",
	}
)
local window_target = renderer:CreateWindowRenderTarget()
renderer.window_target = window_target

event.AddListener("FramebufferResized", "window_resized", function(size)
	window_target:RecreateSwapchain()
end)

event.AddListener("Update", "window_update", function(dt)
	if not window_target:BeginFrame() then return end

	local cmd = window_target:GetCommandBuffer()
	cmd:BeginRenderPass(
		window_target:GetRenderPass(),
		window_target:GetFramebuffer(),
		window_target:GetExtent(),
		ffi.new("float[4]", 0.2, 0.2, 0.2, 1.0)
	)
	local extent = window_target:GetExtent()
	local aspect = extent.width / extent.height
	cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
	cmd:SetScissor(0, 0, extent.width, extent.height)
	event.Call("Draw", cmd, dt)
	cmd:EndRenderPass()
	window_target:EndFrame()
end)

event.AddListener("Shutdown", "window_shutdown", function()
	renderer:WaitForIdle()
	system.ShutDown()
end)

return renderer
