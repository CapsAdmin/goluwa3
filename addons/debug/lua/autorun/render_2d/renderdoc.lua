local input = import("goluwa/input.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local renderdoc = import("goluwa/bindings/renderdoc.lua")

input.Bind("f8", "renderdoc_capture_frame", function()
	if not renderdoc.IsInitialized() then return end

	renderdoc.CaptureFrame(render.GetRenderDocDevicePointer(), system.GetWindow())
	print("RenderDoc capture queued")
end)

input.Bind("f9", "renderdoc_toggle_capture", function()
	if not renderdoc.IsInitialized() then return end

	local renderdoc_device = render.GetRenderDocDevicePointer()
	local renderdoc_window = system.GetWindow()

	if renderdoc.IsCapturing() then
		local stopped = renderdoc.StopCapture(renderdoc_device, renderdoc_window)
		print(stopped and "RenderDoc capture stopped" or "RenderDoc capture stop failed")
	else
		renderdoc.StartCapture(renderdoc_device, renderdoc_window)
		print("RenderDoc capture started")
	end
end)

input.Bind("f11", "renderdoc_open_ui", function()
	if not renderdoc.IsInitialized() then return end

	local last_capture = renderdoc.GetLastCapture()

	if last_capture and last_capture.filename then
		renderdoc.OpenUI(last_capture.filename)
	else
		renderdoc.OpenUI()
	end
end)
