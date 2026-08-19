local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local renderdoc = import("goluwa/bindings/renderdoc.lua")

event.AddListener("KeyInput", "renderdoc_debug", function(key, press)
	if not press then return end

	if renderdoc.IsInitialized() then
		if key == "f8" then
			renderdoc.CaptureFrame(render.GetRenderDocDevicePointer(), system.GetWindow())
			print("RenderDoc capture queued")
		end

		if key == "f9" then
			local renderdoc_device = render.GetRenderDocDevicePointer()
			local renderdoc_window = system.GetWindow()

			if renderdoc.IsCapturing() then
				local stopped = renderdoc.StopCapture(renderdoc_device, renderdoc_window)
				print(stopped and "RenderDoc capture stopped" or "RenderDoc capture stop failed")
			else
				renderdoc.StartCapture(renderdoc_device, renderdoc_window)
				print("RenderDoc capture started")
			end
		end

		if key == "f11" then
			local last_capture = renderdoc.GetLastCapture()

			if last_capture and last_capture.filename then
				renderdoc.OpenUI(last_capture.filename)
			else
				renderdoc.OpenUI()
			end
		end

		return
	end
end)
